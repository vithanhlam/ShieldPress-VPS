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
    local setup_url="${SHIELDPRESS_NODEJS_SETUP_URL:-https://rpm.nodesource.com/setup_current.x}"

    echo "Installing / updating latest Node.js from NodeSource..."

    dnf install -y curl dnf-plugins-core >/dev/null 2>&1 || true

    dnf module reset -y nodejs >/dev/null 2>&1 || true
    dnf module disable -y nodejs >/dev/null 2>&1 || true

    if ! curl -fsSL "$setup_url" | bash -; then
        shieldpress_fail "NodeSource setup failed"
        return 1
    fi

    if ! dnf install -y nodejs --allowerasing; then
        shieldpress_warn "Node.js install hit package conflicts. Removing AppStream Node.js packages and retrying..."
        dnf remove -y nodejs npm nodejs-docs nodejs-full-i18n libnode-devel >/dev/null 2>&1 || true
        dnf clean all >/dev/null 2>&1 || true
        dnf makecache --refresh --setopt=skip_if_unavailable=true -y >/dev/null 2>&1 || true

        if ! dnf install -y nodejs --allowerasing; then
            shieldpress_fail "Node.js install failed"
            return 1
        fi
    fi

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        shieldpress_ok "Node.js $(node -v) / npm $(npm -v) installed"
        return 0
    fi

    shieldpress_fail "Node.js/npm install failed"
    return 1
}
