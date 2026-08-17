#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/helpers.sh"

DOMAINS_ROOT="/home/domains"
APP_FILTER="${FIX_APP_TYPE:-}"

ok(){ echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

get_env_value(){
    grep "^$1=" "$2" | cut -d'=' -f2- | tr -d '[:space:]'
}

chmod_app_tree(){
    local root="$1"

    [ -d "$root" ] || return 0

    chown -R "$SYSUSER:$SYSUSER" "$root"
    find "$root" -path "$root/node_modules" -prune -o -path "$root/vendor" -prune -o -type d -exec chmod 755 {} \;
    find "$root" -path "$root/node_modules" -prune -o -path "$root/vendor" -prune -o -type f -exec chmod 644 {} \;
}

fix_wordpress_permissions(){
    chmod_app_tree "$ROOT"

    [ -f "$ROOT/wp-config.php" ] && chmod 600 "$ROOT/wp-config.php" && ok "wp-config.php -> 600"
    [ -d "$ROOT/wp-content" ] && chmod -R 755 "$ROOT/wp-content" && ok "wp-content -> 755"
}

fix_laravel_permissions(){
    local app_root="$DOMAIN_PATH/public_html"

    chmod_app_tree "$app_root"

    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env" && ok ".env -> 600"
    [ -f "$app_root/artisan" ] && chmod 755 "$app_root/artisan" && ok "artisan -> 755"

    if [ -d "$app_root/storage" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/storage"
        find "$app_root/storage" -type d -exec chmod 775 {} \;
        find "$app_root/storage" -type f -exec chmod 664 {} \;
        ok "storage -> writable"
    fi

    if [ -d "$app_root/bootstrap/cache" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/bootstrap/cache"
        find "$app_root/bootstrap/cache" -type d -exec chmod 775 {} \;
        find "$app_root/bootstrap/cache" -type f -exec chmod 664 {} \;
        ok "bootstrap/cache -> writable"
    fi

    [ -d "$app_root/vendor/bin" ] && find -L "$app_root/vendor/bin" -type f -exec chmod 755 {} \;

    [ -d "$app_root/public" ] && find "$app_root/public" -type d -exec chmod 755 {} \;
    [ -d "$app_root/public" ] && find "$app_root/public" -type f -exec chmod 644 {} \;
}

fix_nodejs_permissions(){
    local app_root="$DOMAIN_PATH/public_html"
    local service_file="/etc/systemd/system/${SYSUSER}-node.service"

    chmod_app_tree "$app_root"

    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env" && ok ".env -> 600"
    [ -f "$app_root/package.json" ] && chmod 644 "$app_root/package.json"
    [ -f "$app_root/package-lock.json" ] && chmod 644 "$app_root/package-lock.json"
    [ -f "$app_root/npm-shrinkwrap.json" ] && chmod 644 "$app_root/npm-shrinkwrap.json"

    if [ -d "$app_root/node_modules" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/node_modules"
        find "$app_root/node_modules" -type d -exec chmod 755 {} \;
        [ -d "$app_root/node_modules/.bin" ] && find -L "$app_root/node_modules/.bin" -type f -exec chmod 755 {} \;
        ok "node_modules ownership fixed"
    fi

    if [ -f "$service_file" ]; then
        chown root:root "$service_file"
        chmod 644 "$service_file"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ok "systemd service -> 644"
    fi
}

fix_selected_domain_permissions(){
    [ -n "$SYSUSER" ] || SYSUSER="$FOLDER"
    [ -n "$ROOT" ] || ROOT="$DOMAIN_PATH/public_html"
    [ -n "$APP_TYPE" ] || APP_TYPE="wordpress"

    echo ""
    echo "Fixing permissions for $DOMAIN ($SYSUSER / $APP_TYPE)..."

    chown root:root "$DOMAIN_PATH"
    chmod 755 "$DOMAIN_PATH"

    if [ -d "$DOMAIN_PATH/config" ]; then
        chown root:root "$DOMAIN_PATH/config"
        chmod 700 "$DOMAIN_PATH/config"
        [ -f "$DOMAIN_PATH/config/domain.env" ] && chown root:root "$DOMAIN_PATH/config/domain.env" && chmod 600 "$DOMAIN_PATH/config/domain.env"
    fi

    case "$APP_TYPE" in
        laravel) fix_laravel_permissions ;;
        nodejs) fix_nodejs_permissions ;;
        *) fix_wordpress_permissions ;;
    esac

    [ -d "$DOMAIN_PATH/backup" ] && chown -R "$SYSUSER:$SYSUSER" "$DOMAIN_PATH/backup" && chmod 750 "$DOMAIN_PATH/backup"
    [ -d "$DOMAIN_PATH/tmp" ] && chown -R "$SYSUSER:$SYSUSER" "$DOMAIN_PATH/tmp"
    [ -d "$DOMAIN_PATH/tmp" ] && chmod 755 "$DOMAIN_PATH/tmp"
    [ -d "$DOMAIN_PATH/tmp/sessions" ] && chmod 700 "$DOMAIN_PATH/tmp/sessions"
}

echo ""
echo "========================================"
echo "        FIX DOMAIN PERMISSIONS"
echo "========================================"

declare -a FOLDERS=()
i=1
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    DN=$(get_env_value DOMAIN "$d/config/domain.env")
    AT=$(get_env_value APP_TYPE "$d/config/domain.env")
    AT="${AT:-wordpress}"
    [ -n "$APP_FILTER" ] && [ "$AT" != "$APP_FILTER" ] && continue
    [ -z "$DN" ] && continue
    echo "$i) $DN ($AT)"
    FOLDERS[$i]=$(basename "$d")
    ((i++))
done

[ $i -eq 1 ] && { warn "No domains found"; read -p "Press Enter..."; exit 0; }

echo "--------------------------------"
read -p "Select domain: " CHOICE
FOLDER="${FOLDERS[$CHOICE]}"

[ -z "$FOLDER" ] && { echo "Invalid selection"; exit 1; }

DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
DOMAIN=$(get_env_value DOMAIN "$ENV_FILE")
SYSUSER=$(get_env_value SYSTEM_USER "$ENV_FILE")
APP_TYPE=$(get_env_value APP_TYPE "$ENV_FILE")
ROOT=$(get_env_value ROOT "$ENV_FILE")

fix_selected_domain_permissions

# Clear cache for WordPress domains
PHP_VERSION=$(get_env_value PHP_VERSION "$ENV_FILE")
if [[ "$APP_TYPE" != "laravel" && "$APP_TYPE" != "nodejs" ]] && [[ -f "$ROOT/wp-config.php" ]]; then
    SYSTEM_USER="$SYSUSER" purge_wp_cache
fi

echo ""
echo "========================================"
echo "[OK] Permissions fixed!"
echo "Domain : $DOMAIN"
echo "User   : $SYSUSER"
echo "App    : $APP_TYPE"
echo "Root   : $ROOT"
echo "========================================"
read -p "Press Enter..."
