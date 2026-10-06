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

install_shieldpress_nodejs(){
    # Keep the runtime installer aligned with upgrade-policy.conf, which
    # allows Node.js 20 and 22 LTS. The Current channel installed v26 and then
    # the controlled upgrader correctly rejected it as outside policy.
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

    local installed_major
    installed_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)
    if [[ "$installed_major" =~ ^[0-9]+$ ]] && [ "$installed_major" -gt 22 ]; then
        # DNF install will keep a newer Current-channel build in place. Sync
        # against the selected LTS repo so existing installs can downgrade to
        # the policy-approved major.
        if ! dnf distro-sync -y nodejs npm --allowerasing; then
            [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
            shieldpress_fail "Could not move Node.js to the supported 22 LTS runtime"
            return 1
        fi
    elif ! dnf install -y nodejs --allowerasing; then
        shieldpress_warn "Node.js install hit package conflicts. Removing AppStream Node.js packages and retrying..."
        dnf remove -y nodejs npm nodejs-docs nodejs-full-i18n libnode-devel >/dev/null 2>&1 || true
        dnf clean all >/dev/null 2>&1 || true
        dnf makecache --refresh --setopt=skip_if_unavailable=true -y >/dev/null 2>&1 || true

        if ! dnf install -y nodejs --allowerasing; then
            [ -f "$package_lock" ] && bash "$package_lock" lock nodejs >/dev/null 2>&1 || true
            shieldpress_fail "Node.js install failed"
            return 1
        fi
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
