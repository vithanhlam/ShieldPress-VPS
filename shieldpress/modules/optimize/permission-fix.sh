#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/helpers.sh"

DOMAINS_ROOT="/home/domains"

ok()  { echo "[OK] $1"; }
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

fix_wordpress(){
    chmod_app_tree "$ROOT"
    [ -f "$ROOT/wp-config.php" ] && chmod 600 "$ROOT/wp-config.php"
    [ -d "$ROOT/wp-content" ] && chmod -R 755 "$ROOT/wp-content"
}

fix_laravel(){
    local app_root="$DOMAIN_PATH/public_html"

    chmod_app_tree "$app_root"
    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env"
    [ -f "$app_root/artisan" ] && chmod 755 "$app_root/artisan"

    if [ -d "$app_root/storage" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/storage"
        find "$app_root/storage" -type d -exec chmod 775 {} \;
        find "$app_root/storage" -type f -exec chmod 664 {} \;
    fi

    if [ -d "$app_root/bootstrap/cache" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/bootstrap/cache"
        find "$app_root/bootstrap/cache" -type d -exec chmod 775 {} \;
        find "$app_root/bootstrap/cache" -type f -exec chmod 664 {} \;
    fi

    [ -d "$app_root/vendor/bin" ] && find -L "$app_root/vendor/bin" -type f -exec chmod 755 {} \;
}

fix_nodejs(){
    local app_root="$DOMAIN_PATH/public_html"
    local service_file="/etc/systemd/system/${SYSUSER}-node.service"

    chmod_app_tree "$app_root"
    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env"
    [ -f "$app_root/package.json" ] && chmod 644 "$app_root/package.json"
    [ -f "$app_root/package-lock.json" ] && chmod 644 "$app_root/package-lock.json"

    if [ -d "$app_root/node_modules" ]; then
        chown -R "$SYSUSER:$SYSUSER" "$app_root/node_modules"
        find "$app_root/node_modules" -type d -exec chmod 755 {} \;
        [ -d "$app_root/node_modules/.bin" ] && find -L "$app_root/node_modules/.bin" -type f -exec chmod 755 {} \;
    fi

    if [ -f "$service_file" ]; then
        chown root:root "$service_file"
        chmod 644 "$service_file"
    fi
}

echo "===================================================="
echo "           FIX ALL DOMAIN PERMISSIONS"
echo "===================================================="

COUNT=0

for d in "$DOMAINS_ROOT"/*; do
    [ -d "$d" ] || continue
    ENV_FILE="$d/config/domain.env"
    [ -f "$ENV_FILE" ] || continue

    DOMAIN_PATH="$d"
    DOMAIN=$(get_env_value DOMAIN "$ENV_FILE")
    SYSUSER=$(get_env_value SYSTEM_USER "$ENV_FILE")
    APP_TYPE=$(get_env_value APP_TYPE "$ENV_FILE")
    ROOT=$(get_env_value ROOT "$ENV_FILE")
    PHP_VERSION=$(get_env_value PHP_VERSION "$ENV_FILE")

    [ -z "$SYSUSER" ] && SYSUSER=$(basename "$d")
    [ -z "$APP_TYPE" ] && APP_TYPE="wordpress"
    [ -z "$ROOT" ] && ROOT="$d/public_html"

    echo "Fixing: $DOMAIN ($APP_TYPE / $SYSUSER)..."

    chown root:root "$d"
    chmod 755 "$d"

    [ -d "$d/config" ] && chown root:root "$d/config" && chmod 700 "$d/config"
    [ -f "$ENV_FILE" ] && chown root:root "$ENV_FILE" && chmod 600 "$ENV_FILE"

    case "$APP_TYPE" in
        laravel) fix_laravel ;;
        nodejs) fix_nodejs ;;
        *) fix_wordpress ;;
    esac

    [ -d "$d/backup" ] && chown -R "$SYSUSER:$SYSUSER" "$d/backup" && chmod 750 "$d/backup"
    [ -d "$d/tmp" ] && chown -R "$SYSUSER:$SYSUSER" "$d/tmp"
    [ -d "$d/tmp" ] && chmod 755 "$d/tmp"
    [ -d "$d/tmp/sessions" ] && chmod 700 "$d/tmp/sessions"

    # Clear cache for WordPress domains
    if [[ "$APP_TYPE" != "laravel" && "$APP_TYPE" != "nodejs" ]] && [[ -f "$ROOT/wp-config.php" ]]; then
        SYSTEM_USER="$SYSUSER" purge_wp_cache
    fi

    ok "$DOMAIN"
    COUNT=$((COUNT + 1))
done

systemctl daemon-reload >/dev/null 2>&1 || true

echo ""
echo "Fixed $COUNT domains."
read -p "Press Enter..."
