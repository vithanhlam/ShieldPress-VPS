#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/ssl"
DOMAINS_ROOT="/home/domains"

source "$MODULE_DIR/ssl-utils.sh"

DOMAIN_PATH=$1

if [ -z "$DOMAIN_PATH" ] || [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    fail "domain.env not found"
    exit 1
fi

DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CONF="/etc/nginx/conf.d/${CLEAN}.conf"
SSL_TYPE=$(grep "^SSL_TYPE=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

echo ""
echo "======================================"
echo "  REMOVE SSL - $DOMAIN"
echo "======================================"
echo ""
echo "  Current SSL type: ${SSL_TYPE:-none}"
echo ""
echo -e "\e[31mWARNING: This will remove the SSL certificate for $DOMAIN!\e[0m"
read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }

# Backup nginx config
[ -f "$CONF" ] && cp "$CONF" "$CONF.bak_remove_$(date +%s)"

# Clean up all SSL (cert files + nginx config)
cleanup_old_ssl "$DOMAIN" "$CLEAN" "$CONF"

# Update domain.env
sed -i 's/^SSL=.*/SSL=disabled/' "$DOMAIN_PATH/config/domain.env"
sed -i '/^SSL_TYPE=/d' "$DOMAIN_PATH/config/domain.env"

# Test and reload nginx
NGINX_ERR=$(nginx -t 2>&1)
if [ $? -eq 0 ]; then
    systemctl reload nginx
    ok "Nginx reloaded"
else
    fail "Nginx config error after removal"
    echo "$NGINX_ERR"
fi

echo ""
echo "======================================"
echo "[OK] SSL removed for $DOMAIN"
echo "======================================"
