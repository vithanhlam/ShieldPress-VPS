#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAINS_ROOT="/home/domains"

source /opt/shieldpress/modules/helpers/domain-utils.sh

select_domain() {

echo ""
echo "Available Domains:"
echo "--------------------------------"

i=1
declare -A DOMAIN_MAP

for d in "$DOMAINS_ROOT"/*; do
    [ -d "$d" ] || continue

    if [ -f "$d/config/domain.env" ]; then
        local _DN
        _DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$_DN" ] && continue

        echo "$i) $_DN"
        DOMAIN_MAP[$i]="$_DN"

        ((i++))
    fi
done

echo "--------------------------------"

read -p "Select domain number: " choice

SELECTED_DOMAIN="${DOMAIN_MAP[$choice]}"

if [ -z "$SELECTED_DOMAIN" ]; then
    echo "Invalid selection!"
    return 1
fi

read -p "You selected '$SELECTED_DOMAIN'. Confirm? [Y/n]: " confirm
confirm="${confirm:-y}"
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 1; }


# convert domain → folder
CLEAN_DOMAIN=$(domain_to_clean "$SELECTED_DOMAIN")

DOMAIN_PATH="$DOMAINS_ROOT/$CLEAN_DOMAIN"
ROOT="$DOMAIN_PATH/public_html"


if [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    echo "Domain config not found!"
    return 1
fi

# load domain config (safe grep, no source)
local _ENV="$DOMAIN_PATH/config/domain.env"
DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_NAME=$(grep "^DB_NAME=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_USER=$(grep "^DB_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_PASS=$(grep "^DB_PASS=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_VERSION=$(grep "^PHP_VERSION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
APP_TYPE=$(grep "^APP_TYPE=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_CONNECTION=$(grep "^DB_CONNECTION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
_CLEAN=$(grep "^CLEAN_DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
[ -n "$_CLEAN" ] && CLEAN_DOMAIN="$_CLEAN"

return 0
}


fix_permissions() {

echo "Fixing permissions for $DOMAIN"

chown -R "$SYSTEM_USER:$SYSTEM_USER" "$DOMAIN_PATH"

find "$ROOT" -type d \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 755 {} \;
find "$ROOT" -type f \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 644 {} \;

chmod 640 "$ROOT/wp-config.php" 2>/dev/null

echo "Permissions fixed"

}
