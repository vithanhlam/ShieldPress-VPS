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
            echo "Review application compatibility and plan a separate runtime migration."
        fi
    fi
    if [[ "$SHIELDPRESS_NODE_AVAILABLE" != 22.* ]]; then
        shieldpress_warn "This candidate is outside the runtime installer's supported 22 LTS branch."
    fi
}

nodejs_runtime_manager(){
    check_shieldpress_nodejs || return 1
    echo ""
    echo "  1) Check for updates again"
    echo "  2) Install / update Node.js 22 LTS"
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
        *) return 0 ;;
    esac
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
