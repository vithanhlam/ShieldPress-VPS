#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAINS_ROOT="/home/domains"

source /opt/shieldpress/modules/helpers/domain-utils.sh
source "$BASE_DIR/core/domain-security.sh"

select_domain() {
declare -F sp_pick_domain >/dev/null || source "${BASE_DIR:-/opt/shieldpress}/core/ui.sh"
sp_pick_domain "Select WordPress site" || return 1
SELECTED_DOMAIN="$SP_PICK_DOMAIN"

read -r -p "You selected '$SELECTED_DOMAIN'. Confirm? [Y/n]: " confirm
confirm="${confirm:-y}"
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 1; }

# convert domain → folder
CLEAN_DOMAIN=$(domain_to_clean "$SELECTED_DOMAIN")

DOMAIN_PATH="$DOMAINS_ROOT/$CLEAN_DOMAIN"
ROOT="$DOMAIN_PATH/public_html"
sp_domain_control check "$CLEAN_DOMAIN" || return 1

if [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    echo "Domain config not found!"
    return 1
fi

# Load literal, validated data from the protected control directory.
sp_load_domain_env "$DOMAIN_PATH" || return 1
ROOT="$DOMAIN_PATH/public_html"

return 0
}


fix_permissions() {

echo "Fixing permissions for $DOMAIN"

sp_secure_domain_control "$DOMAIN_PATH" || return 1
chown -R "$SYSTEM_USER:$SYSTEM_USER" "$ROOT" "$DOMAIN_PATH/tmp"

find "$ROOT" -type d \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 755 {} \;
find "$ROOT" -type f \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 644 {} \;

chmod 640 "$ROOT/wp-config.php" 2>/dev/null

echo "Permissions fixed"

}
