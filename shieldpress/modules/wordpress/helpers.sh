#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAINS_ROOT="/home/domains"

source /opt/shieldpress/modules/helpers/domain-utils.sh
source "$BASE_DIR/core/domain-security.sh"

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
