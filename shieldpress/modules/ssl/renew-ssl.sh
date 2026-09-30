#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/modules/ssl/ssl-utils.sh"

DOMAIN_PATH=$1

if [ -z "$DOMAIN_PATH" ] || [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    fail "domain.env not found"
    exit 1
fi

DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
SSL_TYPE=$(grep "^SSL_TYPE=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
SSL_TYPE="${SSL_TYPE:-letsencrypt}"

echo ""
echo "======================================"
echo "  RENEW SSL - $DOMAIN"
echo "======================================"
echo ""

case "$SSL_TYPE" in
    cloudflare)
        CERT_PATH="/etc/nginx/ssl/$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')/cloudflare-origin.pem"
        if [ ! -f "$CERT_PATH" ]; then
            fail "Cloudflare Origin certificate not found: $CERT_PATH"
            exit 1
        fi
        EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
        echo "Cloudflare Origin SSL expires: ${EXPIRY:-unknown}"
        echo "This certificate is issued by Cloudflare and is not renewed by Certbot."
        echo "Create a replacement Origin Certificate in Cloudflare, then install it from the SSL menu."
        exit 0
        ;;
    custom)
        fail "Custom SSL certificates must be renewed with their certificate provider, then reinstalled from the SSL menu."
        exit 1
        ;;
    letsencrypt|zerossl) ;;
    *)
        warn "Unknown SSL type '$SSL_TYPE'; trying the Certbot certificate for $DOMAIN."
        ;;
esac

# Check expiry for either ACME certificate path.
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    fail "Certbot certificate not found for $DOMAIN. Check the SSL type and certificate status first."
    exit 1
fi
DAYS=$(check_ssl_expiry "$DOMAIN" | tail -1)
echo ""
FORCE_OPT=()

# Nếu còn nhiều ngày thì hỏi xác nhận
if [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 30 ]; then
    warn "Certificate still valid for $DAYS days"
    read -p "Force renew anyway? [y/N]: " FORCE
    [[ "$FORCE" =~ ^[Yy]$ ]] || exit 0
    FORCE_OPT+=(--force-renewal)
fi

echo "Renewing certificate..."
run_certbot renew --cert-name "$DOMAIN" "${FORCE_OPT[@]}"

if [ $? -eq 0 ]; then
    systemctl reload nginx
    ok "Certbot renewal check completed for $DOMAIN"
else
    fail "SSL renewal failed for $DOMAIN"
    exit 1
fi
