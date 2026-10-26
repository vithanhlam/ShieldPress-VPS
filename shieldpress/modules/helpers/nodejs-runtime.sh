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
    echo "ShieldPress recommended runtime: Node.js 22 LTS (configured policy)"
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
        if [[ "$SHIELDPRESS_NODE_CURRENT" != 22.* ]]; then
            shieldpress_warn "The installed runtime differs from the recommended 22 LTS branch."
            echo "Use the same-branch update option to retain the installed major version."
        fi
    fi
    if [[ "$SHIELDPRESS_NODE_AVAILABLE" != 22.* ]]; then
        shieldpress_warn "This candidate is outside the 22 LTS installer; same-branch updates are checked separately."
    fi
}

nodejs_runtime_manager(){
    check_shieldpress_nodejs || return 1
    echo ""
    echo "  1) Check for updates again"
    echo "  2) Install / update Node.js 22 LTS"
    echo "  3) Update installed Node.js (keep current major version)"
    echo "  0) Back"
    local choice confirmation
    read -r -p "Select [0]: " choice
    case "$choice" in
        1) check_shieldpress_nodejs ;;
        2)
            read -r -p "Install / update the supported runtime? [y/N]: " confirmation
            [[ "$confirmation" =~ ^[Yy]$ ]] || return 0
            install_shieldpress_nodejs
            ;;
        3) update_shieldpress_nodejs_current_branch ;;
        *) return 0 ;;
    esac
}

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
    if [[ "$installed_major" =~ ^[0-9]+$ ]] && [ "$installed_major" -gt 22 ]; then
        shieldpress_warn "Node.js $installed_version is newer than the recommended 22 LTS branch."
        shieldpress_warn "Automatic downgrade blocked; review app compatibility before a separate migration."
        return 1
    fi
    local setup_url="${SHIELDPRESS_NODEJS_SETUP_URL:-https://rpm.nodesource.com/setup_22.x}"
    echo "Installing / updating Node.js 22 LTS from NodeSource..."

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
        if [[ "$installed_version" != 22.* ]]; then
            [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
            shieldpress_fail "Unsupported Node.js version after update: ${installed_version:-unknown}; expected 22.x"
            return 1
        fi
        if [ -f "$package_lock" ] && ! bash "$package_lock" lock nodejs >/dev/null 2>&1; then
            shieldpress_warn "Node.js 22 installed, but the package lock could not be restored"
        fi
        shieldpress_ok "Node.js $(node -v) / npm $(npm -v) installed"
        return 0
    fi

    [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
    shieldpress_fail "Node.js/npm install failed"
    return 1
}
