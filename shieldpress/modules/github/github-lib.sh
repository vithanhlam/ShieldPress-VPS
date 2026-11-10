#!/bin/bash
# Git commands always run under the domain account, with a private transport.
gh_die() { echo "[ERROR] $*" >&2; exit 1; }
gh_confirm() { local answer; read -r -p "$1 Type YES: " answer; [[ $answer == YES ]] || gh_die 'Cancelled.'; }

gh_remote() {
    local url=${1%/}
    url=${url%.git}
    if [[ $url =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ||
          $url =~ ^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
        [[ ${BASH_REMATCH[1]} != . && ${BASH_REMATCH[1]} != .. && ${BASH_REMATCH[2]} != . && ${BASH_REMATCH[2]} != .. ]] || return 1
        printf 'git@github.com:%s/%s.git\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        return 1
    fi
}

gh_owner() {
    runuser -u "$owner" -- env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$DOMAIN_PATH" USER="$owner" LOGNAME="$owner" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 "$@"
}
gh_git() {
    gh_owner git -c core.hooksPath=/dev/null -c "core.sshCommand=$ssh_cmd" \
        -c protocol.file.allow=never -c protocol.ext.allow=never -C "$web" "$@"
}

gh_check_repo() {
    [[ -d $web/.git && ! -L $web/.git ]] || gh_die 'Expected a regular .git directory; linked worktrees and submodules are unsupported.'
    [[ $(gh_git rev-parse --show-toplevel) == "$web" ]] || gh_die 'Target is not the repository root.'
    local current status
    current=$(gh_git remote get-url origin) || gh_die 'Missing origin.'
    [[ $(gh_remote "$current") == "$remote" ]] || gh_die 'Origin belongs to another repository or uses an unsupported SSH alias.'
    status=$(gh_git status --porcelain=v1 --untracked-files=all) || gh_die 'Cannot inspect repository status.'
    [[ -z $status ]] || gh_die 'Local changes/untracked files found. Back up and resolve them manually first.'
    local marker
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        [[ ! -e $web/.git/$marker ]] || gh_die 'Repository has an unfinished operation.'
    done
}

gh_pull() {
    gh_check_repo
    local branch merge_ref incoming added parent changes additions
    branch=$(gh_git symbolic-ref --quiet --short HEAD) || gh_die 'Detached HEAD is unsupported.'
    [[ $(gh_git config --get "branch.$branch.remote") == origin ]] || gh_die 'Branch must track origin.'
    merge_ref=$(gh_git config --get "branch.$branch.merge") || gh_die 'Missing upstream branch.'
    [[ $merge_ref == refs/heads/* ]] || gh_die 'Upstream must be a branch.'
    gh_confirm "Update $DOMAIN ($branch) in $web?"
    run_with_loading 'Fetch GitHub branch' "$base/$hash.fetch-time" 30 gh_git fetch --no-tags --no-recurse-submodules "$remote" "$merge_ref"
    incoming=$(gh_git rev-parse --verify 'FETCH_HEAD^{commit}')
    gh_git merge-base --is-ancestor HEAD "$incoming" || gh_die 'Cannot fast-forward. No merge, rebase or reset was performed.'
    changes=$(gh_git diff --name-only --diff-filter=DT --no-renames HEAD "$incoming") || gh_die 'Cannot inspect incoming changes.'
    [[ -z $changes ]] || gh_die 'Update deletes, renames or changes file types. Review manually.'
    additions=$(mktemp)
    gh_git diff --name-only -z --diff-filter=A --no-renames HEAD "$incoming" > "$additions" || gh_die 'Cannot inspect incoming additions.'
    while IFS= read -r -d '' added; do
        [[ ! -e $web/$added && ! -L $web/$added ]] || gh_die "Incoming file collides with local data: $added"
        parent=$(dirname -- "$added")
        while [[ $parent != . ]]; do
            [[ ! -L $web/$parent ]] || gh_die "Incoming path traverses a symlink: $parent"
            parent=$(dirname -- "$parent")
        done
    done < "$additions"
    rm -f -- "$additions"
    run_with_loading 'Apply fast-forward update' "$base/$hash.merge-time" 10 gh_git -c submodule.recurse=false merge --ff-only --no-edit "$incoming"
}

gh_persist() {
    gh_git config --local core.sshCommand "$ssh_cmd"
    gh_git config --local core.hooksPath /dev/null
    gh_git config --local pull.ff only
    gh_git config --local submodule.recurse false
    gh_git config --local push.default nothing
    gh_git config --local --replace-all remote.origin.pushurl /dev/null
    gh_git config --local remote.origin.url "$remote"
}
