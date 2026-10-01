#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
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

if [ "${SHIELDPRESS_REUSE_ACME:-0}" = "1" ]; then
    SSL_TYPE=letsencrypt
fi

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

# Existing certificates retain their provider and SANs. Certbot decides when
# renewal is due; selecting Install SSL never forces an unnecessary issuance.
if ! ssl_has_lineage "$DOMAIN"; then
    fail "Certbot certificate/renewal configuration not found for $DOMAIN"
    exit 1
fi
ensure_ssl_dependencies || { fail "SSL dependencies could not be installed"; exit 1; }
CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CONF="$SSL_NGINX_DIR/${CLEAN}.conf"
[ -f "$CONF" ] || { fail "Nginx config not found: $CONF"; exit 1; }
FORCE_OPT=()
# Explicit CLI forcing remains available, but the default is renewal when due.
[ "${2:-}" = "--force-renewal" ] && FORCE_OPT+=(--force-renewal)
if ssl_renew_nginx "$DOMAIN" "$CONF" "${FORCE_OPT[@]}"; then
    ensure_ssl_auto_renew || { fail "Auto-renew setup failed"; exit 1; }
    # Recover stale/missing metadata only after installation succeeded.
    SSL_TYPE=letsencrypt
    grep -q 'acme.zerossl.com' "$SSL_LE_DIR/renewal/$DOMAIN.conf" && SSL_TYPE=zerossl
    sed -i '/^SSL=/d; /^SSL_TYPE=/d' "$DOMAIN_PATH/config/domain.env"
    printf 'SSL=enabled\nSSL_TYPE=%s\n' "$SSL_TYPE" >> "$DOMAIN_PATH/config/domain.env"
    ok "SSL installed; renewed if due. Auto-renew enabled for $DOMAIN"
else
    fail "SSL renewal failed for $DOMAIN"
    exit 1
fi
