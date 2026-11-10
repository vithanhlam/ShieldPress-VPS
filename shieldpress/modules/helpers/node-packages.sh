#!/bin/bash
# Detect and prepare the package manager before touching dependencies or builds.
node_project_preflight(){
    local metadata
    metadata=$(node "$BASE_DIR/modules/helpers/node-project.js" "$1" "$(command -v npm)") || return 1
    NODE_PACKAGE_MANAGER=${metadata%%$'\n'*}
    NODE_PACKAGE_VERSION=""
    [[ $metadata != *$'\n'* ]] || NODE_PACKAGE_VERSION=${metadata#*$'\n'}
    echo "Project package manager: $NODE_PACKAGE_MANAGER${NODE_PACKAGE_VERSION:+@$NODE_PACKAGE_VERSION}"
}

ensure_node_package_manager(){
    local user="$1" current prefix="/home/domains/$1/.shieldpress-tools"
    [[ ${NODE_PACKAGE_MANAGER:-npm} == pnpm ]] || return 0
    current=$(run_pm2 "$user" pnpm --version 2>/dev/null) || current=""
    if [[ -n $current && ( -z ${NODE_PACKAGE_VERSION:-} || $current == "$NODE_PACKAGE_VERSION" ) ]]; then
        return 0
    fi
    if [[ -z ${NODE_PACKAGE_VERSION:-} ]]; then
        fail 'pnpm is missing. Pin an exact packageManager version (pnpm@x.y.z) in package.json, then retry.'
        return 1
    fi
    [[ ! -L $prefix ]] || { fail 'Package-manager directory must not be a symlink.'; return 1; }
    install -d -m 755 -o "$user" -g "$user" "$prefix" || return 1
    mkdir -p "/home/domains/$user/.npm" || return 1
    chown -R "$user:$user" "/home/domains/$user/.npm" || return 1
    # Install the pinned CLI as the domain account; do not change global tools.
    run_with_loading "Prepare pnpm@$NODE_PACKAGE_VERSION" "$DOMAIN_PATH/tmp/.pnpm-prepare-time" 30 \
        run_pm2 "$user" npm install --global --prefix "$prefix" --ignore-scripts --no-audit --no-fund "pnpm@$NODE_PACKAGE_VERSION" || return 1
    current=$(run_pm2 "$user" pnpm --version) || return 1
    [[ $current == "$NODE_PACKAGE_VERSION" ]] || { fail 'Prepared pnpm version does not match packageManager.'; return 1; }
}

install_node_project_dependencies(){
    local user="$1"
    if [[ ${NODE_PACKAGE_MANAGER:-npm} == pnpm ]]; then
        local -a args=(install --prod=false)
        [[ ! -f pnpm-lock.yaml ]] || args+=(--frozen-lockfile)
        run_with_progress 'Install dependencies (pnpm)' "$DOMAIN_PATH/tmp/.node-pnpm-time" run_pm2 "$user" pnpm "${args[@]}"
    elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
        run_with_progress 'Install dependencies (npm ci)' "$DOMAIN_PATH/tmp/.node-ci-time" run_pm2 "$user" npm ci --include=dev
    else
        run_with_progress 'Install dependencies (npm install)' "$DOMAIN_PATH/tmp/.node-install-time" run_pm2 "$user" npm install --include=dev
    fi
}
