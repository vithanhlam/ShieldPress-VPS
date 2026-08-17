#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/modules/ssl/ssl-utils.sh"

# Select domain
DOMAINS_ROOT="/home/domains"
DOMAIN_FOLDERS=()

echo ""
echo "Available Domains:"
echo "--------------------------------"
i=1
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    DNAME=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    [ -z "$DNAME" ] && continue
    echo "$i) $DNAME"
    DOMAIN_FOLDERS[$i]=$(basename "$d")
    ((i++))
done
echo "--------------------------------"
read -p "Select domain: " CHOICE
FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
[ -z "$FOLDER" ] && { fail "Invalid selection"; exit 1; }

DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

# Lấy email từ config.env
ADMIN_EMAIL=$(grep "^ADMIN_EMAIL=" "$BASE_DIR/config.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
[ -z "$ADMIN_EMAIL" ] && ADMIN_EMAIL="admin@${DOMAIN}"

ensure_ssl_dependencies

echo ""
echo "Domain : $DOMAIN"
echo "Email  : $ADMIN_EMAIL"
echo ""
echo "1) Standard SSL (www + non-www)"
echo "2) Wildcard SSL (*.domain + domain) - requires DNS challenge"
echo "0) Cancel"
read -p "Choose: " TYPE

case $TYPE in
1)
    certbot --nginx \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        --email "$ADMIN_EMAIL" \
        --agree-tos \
        --non-interactive \
        --redirect && \
        sed -i 's/^SSL=.*/SSL=enabled/' "$DOMAIN_PATH/config/domain.env" && \
        ok "Standard SSL installed for $DOMAIN" || \
        fail "SSL installation failed"
    ;;
2)
    warn "Wildcard SSL requires manual DNS TXT record verification"
    echo ""
    certbot certonly \
        --manual \
        --preferred-challenges dns \
        -d "$DOMAIN" \
        -d "*.$DOMAIN" \
        --email "$ADMIN_EMAIL" \
        --agree-tos && \
        sed -i 's/^SSL=.*/SSL=enabled/' "$DOMAIN_PATH/config/domain.env" && \
        ok "Wildcard SSL installed for $DOMAIN" || \
        fail "Wildcard SSL installation failed"
    ;;
0) exit 0 ;;
*) fail "Invalid option"; exit 1 ;;
esac

read -p "Press Enter..."
