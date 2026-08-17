#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/modules/ssl/ssl-utils.sh"

DOMAIN_PATH=$1

if [ -z "$DOMAIN_PATH" ] || [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    fail "domain.env not found"
    exit 1
fi

DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

echo ""
echo "======================================"
echo "  RENEW SSL - $DOMAIN"
echo "======================================"
echo ""

# Hiển thị số ngày còn lại
DAYS=$(check_ssl_expiry "$DOMAIN" | tail -1)
echo ""

# Nếu còn nhiều ngày thì hỏi xác nhận
if [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 30 ]; then
    warn "Certificate still valid for $DAYS days"
    read -p "Force renew anyway? (y/n): " FORCE
    [ "$FORCE" != "y" ] && exit 0
fi

echo "Renewing certificate..."
certbot renew --cert-name "$DOMAIN" --force-renewal

if [ $? -eq 0 ]; then
    systemctl reload nginx
    ok "SSL renewed for $DOMAIN"
else
    fail "SSL renewal failed for $DOMAIN"
    exit 1
fi
