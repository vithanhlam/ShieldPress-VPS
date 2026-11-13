#!/bin/bash

shieldpress_ok(){
    if declare -F ok >/dev/null 2>&1; then
        ok "$1"
    else
        echo "[OK] $1"
    fi
}

shieldpress_warn(){
    if declare -F warn >/dev/null 2>&1; then
        warn "$1"
    else
        echo "[WARN] $1"
    fi
}

shieldpress_fail(){
    if declare -F fail >/dev/null 2>&1; then
        fail "$1"
    else
        echo "[FAIL] $1"
    fi
}

# Return success only when the first semantic version is newer.
shieldpress_nodejs_newer(){
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [ "$1" != "$2" ] && [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

check_shieldpress_nodejs(){
    SHIELDPRESS_NODE_CURRENT=$(node -p 'process.versions.node' 2>/dev/null || true)
    SHIELDPRESS_NODE_AVAILABLE=""
    echo "Current Node.js: ${SHIELDPRESS_NODE_CURRENT:-Not installed}"
    echo "Default installer: Node.js 26 LTS (latest). Supported branches: 24 / 26 LTS."
    local available
    if ! available=$(dnf -q --refresh --disableplugin=versionlock --disableexcludes=all repoquery \
        --available --latest-limit 1 --qf '%{version}' nodejs 2>/dev/null); then
        shieldpress_warn "Could not check repository updates. Check network access and NodeSource configuration."
        return 1
    fi
    SHIELDPRESS_NODE_AVAILABLE=$(printf '%s\n' "$available" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    if [ -z "$SHIELDPRESS_NODE_AVAILABLE" ]; then
        shieldpress_warn "No Node.js candidate found in the configured repositories."
        return 1
    fi
    echo "Repository candidate: $SHIELDPRESS_NODE_AVAILABLE"
    if [ -n "$SHIELDPRESS_NODE_CURRENT" ]; then
        if shieldpress_nodejs_newer "$SHIELDPRESS_NODE_CURRENT" "$SHIELDPRESS_NODE_AVAILABLE"; then
            shieldpress_warn "The repository candidate is older. Automatic downgrade is blocked."
        elif [ "$SHIELDPRESS_NODE_CURRENT" = "$SHIELDPRESS_NODE_AVAILABLE" ]; then
            shieldpress_ok "Already running the latest version in the configured repositories"
        else
            echo "A newer repository version is available."
        fi
    fi
}

nodejs_runtime_manager(){
    # A broken/old repository must not hide the explicit major-upgrade action.
    check_shieldpress_nodejs || true
    echo ""
    echo "  1) Update Node.js (stays on the installed major, e.g. 24.x; installs Node.js 26 if missing)"
    echo "  2) Upgrade major version (24 / 26 LTS)"
    echo "  3) Check for updates again"
    echo "  0) Back"
    local choice
    read -r -p "Select [0]: " choice
    case "$choice" in
        1)
            if command -v node >/dev/null 2>&1; then
                update_shieldpress_nodejs_current_branch
            else
                install_shieldpress_nodejs
            fi
            ;;
        2) shieldpress_nodejs_major_menu ;;
        3) check_shieldpress_nodejs ;;
        *) return 0 ;;
    esac
}

shieldpress_nodejs_major_menu(){
    local choice major
    echo ""
    echo "Upgrade the shared Node.js runtime:"
    echo "  1) Node.js 24 LTS"
    echo "  2) Node.js 26 LTS (newest supported LTS branch)"
    echo "  0) Back"
    read -r -p "Select [0]: " choice || return 0
    case "$choice" in
        1) major=24 ;;
        2) major=26 ;;
        0|"") return 0 ;;
        *) shieldpress_fail 'Invalid Node.js branch'; return 1 ;;
    esac
    upgrade_shieldpress_nodejs_major "$major"
}

# Match the official NodeSource RPM repository settings. Query with a temporary
# repo so inspecting/cancelling an upgrade never changes the server's sources.
shieldpress_nodejs_target_options(){
    NODE_TARGET_OPTIONS=(
        "--repofrompath=shieldpress-nodejs-target,https://rpm.nodesource.com/pub_$1.x/nodistro/nodejs/$2"
        --setopt=shieldpress-nodejs-target.gpgcheck=1
        --setopt=shieldpress-nodejs-target.gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
        --setopt=shieldpress-nodejs-target.sslverify=1
        --setopt=shieldpress-nodejs-target.module_hotfixes=1
        --setopt=shieldpress-nodejs-target.skip_if_unavailable=0
        --enablerepo=shieldpress-nodejs-target
    )
}

shieldpress_nodejs_query_major(){
    local output="$1"; shift
    dnf -q --refresh --disableplugin=versionlock --disableexcludes=all \
        --disablerepo='*' "$@" repoquery --available --qf '%{version}' nodejs > "$output"
}

shieldpress_nodejs_save_major_repo(){
    local major="$1" arch="$2" file="${3:-/etc/yum.repos.d/nodesource-nodejs.repo}" temp backup
    [[ ! -L $file ]] || return 1
    temp=$(mktemp "${file}.XXXXXX") || return 1
    if [[ -e $file ]]; then
        backup=$(mktemp "${file}.shieldpress-backup.XXXXXX") || { rm -f "$temp"; return 1; }
        cp -p -- "$file" "$backup" || { rm -f "$temp"; return 1; }
        echo "Previous NodeSource repository saved to $backup"
    fi
    cat > "$temp" <<EOF
[nodesource-nodejs]
name=Node.js $major LTS - $arch
baseurl=https://rpm.nodesource.com/pub_$major.x/nodistro/nodejs/$arch
enabled=1
priority=9
gpgcheck=1
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
sslverify=1
module_hotfixes=1
EOF
    chmod 644 "$temp" && chown root:root "$temp" && mv -fT -- "$temp" "$file" || { rm -f "$temp"; return 1; }
}

shieldpress_nodejs_runtime_lock(){
    exec {NODE_RUNTIME_LOCK_FD}>/run/lock/shieldpress-nodejs-runtime.lock || return 1
    flock -n "$NODE_RUNTIME_LOCK_FD"
}

# Hold a process-scoped lock through query, confirmation and installation so two
# major upgrades cannot race and turn the second explicit target into a downgrade.
upgrade_shieldpress_nodejs_major() (
    local major="$1" current arch available candidate confirmation actual query_file status=0 lock_status=0
    [[ $major == 24 || $major == 26 ]] || { shieldpress_fail 'Only Node.js 24 and 26 LTS are supported.'; return 1; }
    shieldpress_nodejs_runtime_lock || { shieldpress_fail 'Another Node.js major upgrade is running, or its lock cannot be acquired.'; return 1; }
    command -v dnf >/dev/null 2>&1 || { shieldpress_fail 'Major upgrades currently require a DNF/RPM server.'; return 1; }
    current=$(node -p 'process.versions.node' 2>/dev/null || true)
    [[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { shieldpress_fail 'Install Node.js first; its current version could not be verified.'; return 1; }
    if (( major <= ${current%%.*} )); then
        shieldpress_fail "Select a branch newer than ${current%%.*}.x. Use option 1 for updates within the current branch. Downgrades are blocked."
        return 1
    fi
    [[ $(rpm -q --qf '%{VERSION}' nodejs 2>/dev/null) == "$current" ]] || {
        shieldpress_fail 'The active node executable does not match the RPM-managed runtime. Review PATH/nvm before upgrading.'; return 1;
    }
    arch=$(uname -m)
    [[ $arch == x86_64 || $arch == aarch64 ]] || { shieldpress_fail "Unsupported NodeSource architecture: $arch"; return 1; }
    local package_lock="${BASE_DIR:-/opt/shieldpress}/modules/upgrade/package-lock.sh"
    local progress="${BASE_DIR:-/opt/shieldpress}/modules/helpers/task-progress.sh"
    [[ -f $package_lock ]] || { shieldpress_fail 'Package lock manager is missing.'; return 1; }
    [[ ! -f $progress ]] || source "$progress"
    local -a NODE_TARGET_OPTIONS
    shieldpress_nodejs_target_options "$major" "$arch"
    echo "Checking the latest NodeSource package for Node.js $major LTS..."
    query_file=$(mktemp) || return 1
    if declare -F run_with_loading >/dev/null 2>&1; then
        run_with_loading "Check Node.js $major LTS packages" "${DATA_DIR:-/var/shieldpress/data}/nodejs-major-query.seconds" 30 \
            shieldpress_nodejs_query_major "$query_file" "${NODE_TARGET_OPTIONS[@]}" || status=$?
    else
        echo 'Querying NodeSource (approximate duration: 30 seconds)...'
        shieldpress_nodejs_query_major "$query_file" "${NODE_TARGET_OPTIONS[@]}" || status=$?
    fi
    available=$(cat "$query_file")
    rm -f -- "$query_file"
    if (( status != 0 )); then
        shieldpress_fail 'Could not query the target branch. Runtime and repository configuration were not changed.'; return 1;
    fi
    candidate=$(printf '%s\n' "$available" | grep -E "^$major\.[0-9]+\.[0-9]+$" | sort -V | tail -1)
    [[ -n $candidate ]] || { shieldpress_fail 'No valid package found for the selected branch.'; return 1; }
    echo "Major upgrade: Node.js $current -> $candidate"
    shieldpress_warn 'All Node.js applications share this runtime. Native dependencies may need reinstalling before a reviewed application restart.'
    echo 'PHP, Nginx and database services will not be restarted. Node.js apps and PM2 will not be restarted automatically.'
    read -r -p "Upgrade Node.js to $candidate? Type YES: " confirmation || return 0
    [[ $confirmation == YES ]] || return 0
    actual=$(node -p 'process.versions.node' 2>/dev/null || true)
    [[ $actual == "$current" ]] || { shieldpress_fail 'Node.js changed during confirmation; retry the version check.'; return 1; }
    local -a transaction=(dnf --disableplugin=versionlock --disableexcludes=all
        --disablerepo='nodesource*' "${NODE_TARGET_OPTIONS[@]}" install -y "nodejs-$candidate-*")
    # Keep persistent locks during the transaction; never permit package erasure.
    if declare -F run_with_loading >/dev/null 2>&1; then
        run_with_loading "Upgrading Node.js to $candidate" "${DATA_DIR:-/var/shieldpress/data}/nodejs-major-upgrade.seconds" 120 "${transaction[@]}" || status=$?
    else
        echo 'Upgrading Node.js (approximate duration: 2 minutes)...'
        "${transaction[@]}" || status=$?
    fi
    bash "$package_lock" unlock nodejs || lock_status=1
    bash "$package_lock" lock nodejs || lock_status=1
    if (( status != 0 || lock_status != 0 )); then
        shieldpress_fail 'Upgrade or package-lock restoration failed. Inspect the errors above; no automatic downgrade was attempted.'
        (( status != 0 )) && return "$status"
        return 1
    fi
    actual=$(node -p 'process.versions.node' 2>/dev/null || true)
    [[ $actual == "$candidate" ]] && npm --version >/dev/null 2>&1 || {
        shieldpress_fail "Runtime verification failed: expected $candidate, found ${actual:-unknown}."; return 1;
    }
    if ! shieldpress_nodejs_save_major_repo "$major" "$arch"; then
        shieldpress_fail "Node.js $actual is installed, but its persistent NodeSource repository needs repair. No automatic downgrade was attempted."
        return 1
    fi
    shieldpress_ok "Node.js $actual / npm $(npm --version) installed; package locks restored."
    echo 'Next: deploy each Node.js application with dependency installation and review its build before restarting it.'
)

# Query every available version: the repository's newest major may differ
# from the installed branch. Never reuse the unfiltered menu candidate.
shieldpress_nodejs_branch_candidate(){
    local current="$1" available
    [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    available=$(dnf -q --refresh --disableplugin=versionlock --disableexcludes=all repoquery \
        --available --qf '%{version}' nodejs) || return 1
    printf '%s\n' "$available" | grep -E "^${current%%.*}\.[0-9]+\.[0-9]+$" | sort -V | tail -1
}

update_shieldpress_nodejs_current_branch(){
    local current candidate confirmation actual status=0
    current=$(node -p 'process.versions.node' 2>/dev/null || true)
    if ! [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        shieldpress_fail "A valid installed Node.js runtime is required for a same-branch update"
        return 1
    fi
    echo "Checking repository updates for Node.js ${current%%.*}.x..."
    if ! candidate=$(shieldpress_nodejs_branch_candidate "$current") || [ -z "$candidate" ]; then
        shieldpress_fail "No candidate found for Node.js ${current%%.*}.x; repositories were not changed"
        return 1
    fi
    if ! shieldpress_nodejs_newer "$candidate" "$current"; then
        shieldpress_ok "No newer Node.js ${current%%.*}.x version is available; keeping $current"
        return 0
    fi
    echo "Same-branch update: Node.js $current -> $candidate"
    shieldpress_warn "Running applications keep their existing runtime until restarted. Review and restart each affected application after updating."
    read -r -p "Update Node.js to $candidate? [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || return 0
    # Recheck after confirmation so a concurrent runtime migration cannot turn
    # this operation into a cross-major change.
    actual=$(node -p 'process.versions.node' 2>/dev/null || true)
    if [ "$actual" != "$current" ]; then
        shieldpress_fail "Node.js changed during confirmation; check updates again"
        return 1
    fi
    local package_lock="${BASE_DIR:-/opt/shieldpress}/modules/upgrade/package-lock.sh"
    local progress="${BASE_DIR:-/opt/shieldpress}/modules/helpers/task-progress.sh"
    [ ! -f "$progress" ] || source "$progress"
    if [ ! -f "$package_lock" ]; then
        shieldpress_fail "Package lock manager is missing; update cancelled"
        return 1
    fi
    # Keep persistent locks in place during the transaction. Bypass only for
    # this explicit version; unrelated service locks remain effective later.
    # No --allowerasing, repository setup, npm@latest or global PM2 restart.
    if declare -F run_with_loading >/dev/null 2>&1; then
        run_with_loading "Updating Node.js to $candidate" \
            "${DATA_DIR:-/var/shieldpress/data}/nodejs-update.seconds" 120 \
            dnf --disableplugin=versionlock --disableexcludes=all upgrade -y "nodejs-$candidate-*" || status=$?
    else
        echo "Updating Node.js packages (approximate duration: 2 minutes)..."
        dnf --disableplugin=versionlock --disableexcludes=all upgrade -y "nodejs-$candidate-*" || status=$?
    fi
    # Refresh old version locks even after a partially failed transaction.
    if ! bash "$package_lock" unlock nodejs || ! bash "$package_lock" lock nodejs; then
        shieldpress_fail "Node.js package protection needs repair; retry from Package Lock Manager"
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        shieldpress_fail "Node.js update failed; inspect the package errors above"
        return "$status"
    fi
    actual=$(node -p 'process.versions.node' 2>/dev/null || true)
    if [ "$actual" != "$candidate" ] || ! command -v npm >/dev/null 2>&1; then
        shieldpress_fail "Runtime verification failed: expected $candidate, found ${actual:-unknown}"
        return 1
    fi
    shieldpress_ok "Node.js $actual installed; package protection restored"
}

install_shieldpress_nodejs(){
    local installed_version installed_major
    installed_version=$(node -p 'process.versions.node' 2>/dev/null || true)
    installed_major=${installed_version%%.*}
    # Guard every caller, including automatic app and stack installers, before
    # changing repositories, package locks, or packages on existing servers.
    if [ -n "$installed_version" ] && ! [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        shieldpress_fail "Cannot determine the installed Node.js version safely"
        return 1
    fi
    if [ -n "$installed_version" ]; then
        # Never change the major branch implicitly on an existing server.
        shieldpress_warn "Node.js $installed_version is already installed; updating within the ${installed_major}.x branch only."
        update_shieldpress_nodejs_current_branch
        return $?
    fi
    local setup_url="${SHIELDPRESS_NODEJS_SETUP_URL:-https://rpm.nodesource.com/setup_26.x}"
    echo "Installing Node.js 26 LTS from NodeSource..."

    dnf install -y curl dnf-plugins-core >/dev/null 2>&1 || true

    dnf module reset -y nodejs >/dev/null 2>&1 || true
    dnf module disable -y nodejs >/dev/null 2>&1 || true

    # Materialize the installer so it can be audited and removed after use.
    local setup_script
    setup_script=$(mktemp /tmp/shieldpress-nodejs-setup.XXXXXX)
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "$setup_url" -o "$setup_script"; then
        rm -f "$setup_script"
        shieldpress_fail "NodeSource setup download failed"
        return 1
    fi
    if ! bash "$setup_script"; then
        rm -f "$setup_script"
        shieldpress_fail "NodeSource setup failed"
        return 1
    fi
    rm -f "$setup_script"

    local package_lock="${BASE_DIR:-/opt/shieldpress}/modules/upgrade/package-lock.sh"
    if [ -f "$package_lock" ]; then
        bash "$package_lock" unlock nodejs || {
            shieldpress_fail "Could not unlock Node.js for the controlled runtime update"
            return 1
        }
    fi

    # Install/upgrade only: never distro-sync or remove an existing runtime.
    if ! dnf install -y nodejs --allowerasing; then
        [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
        shieldpress_fail "Node.js install/update failed; resolve package conflicts before retrying"
        return 1
    fi

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        local installed_version
        installed_version=$(node -p 'process.versions.node' 2>/dev/null || true)
        if [[ "$installed_version" != 26.* ]]; then
            [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
            shieldpress_fail "Unsupported Node.js version after update: ${installed_version:-unknown}; expected 26.x"
            return 1
        fi
        if [ -f "$package_lock" ] && ! bash "$package_lock" lock nodejs >/dev/null 2>&1; then
            shieldpress_warn "Node.js 26 installed, but the package lock could not be restored"
        fi
        shieldpress_ok "Node.js $(node -v) / npm $(npm -v) installed"
        return 0
    fi

    [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
    shieldpress_fail "Node.js/npm install failed"
    return 1
}
