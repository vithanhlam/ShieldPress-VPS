#!/bin/bash
set -Eeuo pipefail
umask 077
trap 'echo "[ERROR] Stopped at line $LINENO. No automatic reset, clean or recovery deletion." >&2' ERR
BASE_DIR=/opt/shieldpress
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/domain-security.sh"
source "$BASE_DIR/modules/helpers/task-progress.sh"
source "$BASE_DIR/modules/github/github-lib.sh"
[[ $EUID == 0 && -t 0 ]] || gh_die 'Run from an interactive root terminal.'
for tool in git ssh ssh-keygen runuser realpath sha256sum flock stat find; do
    command -v "$tool" >/dev/null || gh_die "Missing dependency: $tool"
done
for variable in ${!GIT_@}; do unset "$variable"; done
action=${1:-setup}
[[ $action == setup || $action == pull || $action == key ]] || gh_die 'Invalid action.'
domains=()
for directory in "$DOMAINS_ROOT"/*; do
    [[ -d $directory && ! -L $directory && -f $directory/config/domain.env ]] || continue
    domains+=("$directory")
    printf '%s) %s\n' "${#domains[@]}" "${directory##*/}"
done
[[ ${#domains[@]} -gt 0 ]] || gh_die 'No configured domains found.'
read -r -p 'Select domain number: ' selection
[[ $selection =~ ^[1-9][0-9]{0,4}$ ]] && (( selection <= ${#domains[@]} )) || gh_die 'Invalid selection.'
DOMAIN_PATH=${domains[selection-1]}
sp_load_domain_env "$DOMAIN_PATH" || gh_die 'Cannot load secure domain configuration.'
owner=${SYSTEM_USER:-${CLEAN_DOMAIN:-}}
[[ $owner =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || gh_die 'Invalid domain user.'
[[ $(id -u "$owner") != 0 ]] || gh_die 'Refusing root as domain user.'
web="$DOMAIN_PATH/public_html"
[[ $(realpath -e -- "$web") == "$web" ]] || gh_die 'Application directory must exist and must not traverse symlinks.'
[[ $(stat -c %u "$web") == "$(id -u "$owner")" ]] || gh_die 'Application directory must belong to the domain user; review permissions first.'
base=/var/lib/shieldpress-github
[[ ! -L $base ]] || gh_die 'Key storage is a symlink.'
if [[ ! -e $base ]]; then mkdir -m 755 "$base"; fi
[[ -d $base && $(stat -c %u:%a "$base") == 0:755 ]] || gh_die 'Key storage must belong to root with mode 755.'
hash=$(printf '%s' "$web" | sha256sum); hash=${hash%% *}
exec 9>"$base/$hash.lock"
flock -n 9 || gh_die 'Another deployment is running for this domain.'
state="$base/$hash"
if [[ ! -e $state && ! -L $state ]]; then
    mkdir -m 700 "$state"
    chown "$owner:$(id -gn "$owner")" "$state"
fi
[[ -d $state && ! -L $state && $(stat -c %u:%a "$state") == "$(id -u "$owner"):700" ]] || gh_die 'Unsafe key directory ownership/mode.'
key="$state/key"
for file in "$key" "$key.pub" "$state/known_hosts"; do
    [[ ! -L $file ]] || gh_die 'Symlink found in SSH storage.'
done
config="$base/$hash.remote"
if [[ -f $config && ! -L $config ]]; then
    read -r saved_remote < "$config"
    remote=$(gh_remote "$saved_remote") || gh_die 'Invalid saved repository.'
else
    [[ $action == setup && ! -e $config && ! -L $config ]] || gh_die 'Configure the GitHub connection first.'
    read -r -p 'GitHub repository URL (HTTPS or git@github.com:OWNER/REPO.git): ' url
    remote=$(gh_remote "$url") || gh_die 'Only github.com repository URLs without tokens or queries are supported.'
fi
printf -v ssh_cmd '%q ' ssh -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o "UserKnownHostsFile=$state/known_hosts" -o GlobalKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15
if [[ $action == setup ]]; then
    if [[ -e $web/.git || -L $web/.git ]]; then
        gh_check_repo
    else
        [[ -z $(find "$web" -mindepth 1 -maxdepth 1 -print -quit) ]] || gh_die 'Directory contains data but is not a repository. Back it up and prepare an empty directory manually; nothing was overwritten.'
    fi
    gh_confirm "Configure read-only GitHub deployment of $remote to $web as $owner?"
    if [[ ! -e $key ]]; then
        [[ ! -e $key.pub ]] || gh_die 'Public key exists without private key.'
        gh_owner ssh-keygen -q -t ed25519 -N '' -C "shieldpress:$DOMAIN" -f "$key"
    fi
    # Save root-controlled connection data even if SSH verification is cancelled.
    printf '%s\n' "$remote" > "$config"
fi
[[ -f $key && -f $key.pub && $(stat -c %u:%a "$key") == "$(id -u "$owner"):600" ]] || gh_die 'Missing or unsafe SSH key; expected domain ownership and mode 600.'
if [[ $action == setup || $action == key ]]; then
    slug=${remote#git@github.com:}; slug=${slug%.git}
    printf '\nOpen https://github.com/%s/settings/keys\n' "$slug"
    echo 'Settings > Deploy keys > Add deploy key. Paste the PUBLIC key below.'
    echo 'Leave Allow write access UNCHECKED. Never upload the private key.'
    cat -- "$key.pub"
    [[ $action != key ]] || exit 0
    gh_confirm 'Have you added this deploy key with write access disabled?'
    echo 'Compare the SSH host fingerprint before accepting it:'
    echo 'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints'
    # ssh -T returns 1 even on success; repository access below is authoritative.
    gh_owner ssh -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
        -o "UserKnownHostsFile=$state/known_hosts" -o GlobalKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=ask -o ConnectTimeout=15 -T git@github.com || ssh_status=$?
    [[ ${ssh_status:-0} -le 1 ]] || gh_die 'SSH host/authentication verification failed.'
fi
run_with_loading 'Verify repository read access' "$base/$hash.verify-time" 15 gh_git ls-remote --exit-code "$remote" HEAD
if [[ ! -e $web/.git && ! -L $web/.git ]]; then
    [[ $action == setup && -z $(find "$web" -mindepth 1 -maxdepth 1 -print -quit) ]] || gh_die 'Expected an empty application directory.'
    run_with_loading 'Clone GitHub repository' "$base/$hash.clone-time" 60 gh_owner git \
        -c core.hooksPath=/dev/null -c "core.sshCommand=$ssh_cmd" -c protocol.ext.allow=never \
        clone --no-recurse-submodules -- "$remote" "$web"
else
    gh_pull
fi
gh_persist
printf '\n[OK] Current commit: '; gh_git rev-parse --short HEAD
printf 'Next time: shieldpress github > Pull > select this domain.\nOr: sudo -u %q git -C %q pull --ff-only\n' "$owner" "$web"
echo 'Direct pull protects fast-forward only; use the menu for collision/deletion checks.'
echo 'Push is disabled locally. Keep the GitHub deploy key read-only as the server-side restriction.'
echo 'No build, dependency installation, database migration or service restart is performed.'
