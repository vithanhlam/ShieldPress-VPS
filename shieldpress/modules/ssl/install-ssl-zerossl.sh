#!/bin/bash
# ============================================================
#  Install Free SSL (ZeroSSL via ACME)
#  Alternative to Let's Encrypt with less strict rate limits
#  Fully automatic — no manual registration needed
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/ssl"
DOMAINS_ROOT="/home/domains"
ZEROSSL_ACME="https://acme.zerossl.com/v2/DV90"
EAB_FILE="$BASE_DIR/config/zerossl-eab.env"

source "$MODULE_DIR/ssl-utils.sh"

DOMAIN_PATH=$1

# ================================================
# SELECT DOMAIN
# ================================================

if [ -z "$DOMAIN_PATH" ] || [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
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

        CLEAN_D=$(echo "$DNAME" | sed 's/[^a-zA-Z0-9]/_/g')
        SSL_ST=$(grep "^SSL_TYPE=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        SSL_EN=$(grep "^SSL=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        if [ "$SSL_EN" = "enabled" ] && [ -n "$SSL_ST" ]; then
            SSL_TAG="\e[32m[${SSL_ST}]\e[0m"
        else
            SSL_TAG="\e[31m[No SSL]\e[0m"
        fi
        printf "  %d) %-30s %b\n" "$i" "$DNAME" "$SSL_TAG"
        DOMAIN_FOLDERS[$i]=$(basename "$d")
        ((i++))
    done
    echo "--------------------------------"

    if [ "$i" -eq 1 ]; then
        fail "No domains found"
        read -p "Press Enter..."
        exit 1
    fi

    read -p "Select domain: " CHOICE
    FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; exit 1; }
    DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
fi

DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CONF="/etc/nginx/conf.d/${CLEAN}.conf"
ADMIN_EMAIL=$(grep "^ADMIN_EMAIL=" "$BASE_DIR/config.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
[ -z "$ADMIN_EMAIL" ] && ADMIN_EMAIL="admin@${DOMAIN}"

ensure_ssl_dependencies

echo ""
echo "===================================================="
echo "  FREE SSL (ZeroSSL) - $DOMAIN"
echo "===================================================="
echo ""

# ================================================
# AUTO EAB CREDENTIALS
# ================================================

EAB_KID=""
EAB_HMAC=""

# Load saved credentials
if [ -f "$EAB_FILE" ]; then
    EAB_KID=$(grep "^EAB_KID=" "$EAB_FILE" | cut -d'=' -f2-)
    EAB_HMAC=$(grep "^EAB_HMAC=" "$EAB_FILE" | cut -d'=' -f2-)
fi

# Auto-generate via ZeroSSL API if not saved
if [ -z "$EAB_KID" ] || [ -z "$EAB_HMAC" ]; then
    echo "Generating EAB credentials..."

    EAB_RESPONSE=$(curl -s -X POST "https://api.zerossl.com/acme/eab-credentials-email" \
        --data-urlencode "email=$ADMIN_EMAIL" \
        2>/dev/null)

    if [ -n "$EAB_RESPONSE" ]; then
        EAB_KID=$(echo "$EAB_RESPONSE" | grep -o '"eab_kid":"[^"]*"' | cut -d'"' -f4)
        EAB_HMAC=$(echo "$EAB_RESPONSE" | grep -o '"eab_hmac_key":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -z "$EAB_KID" ] || [ -z "$EAB_HMAC" ]; then
        fail "Failed to generate EAB credentials automatically"
        echo ""
        echo "Manual setup:"
        echo "  1. Go to https://app.zerossl.com/signup"
        echo "  2. Go to Developer > EAB Credentials > Generate"
        echo ""
        read -p "EAB KID: " EAB_KID
        read -p "EAB HMAC Key: " EAB_HMAC

        if [ -z "$EAB_KID" ] || [ -z "$EAB_HMAC" ]; then
            fail "EAB credentials are required"
            exit 1
        fi
    else
        ok "EAB credentials generated"
    fi

    # Save for future use
    mkdir -p "$(dirname "$EAB_FILE")"
    cat > "$EAB_FILE" <<EOF
EAB_KID=$EAB_KID
EAB_HMAC=$EAB_HMAC
EOF
    chmod 600 "$EAB_FILE"
fi

# ================================================
# DNS CHECK
# ================================================

get_server_ips
A_RECORD=$(dig +short A "$DOMAIN" 2>/dev/null | tail -1)

echo "  Server IP : $SERVER_IPV4"
echo "  DNS A     : ${A_RECORD:-not found}"

if [ -n "$A_RECORD" ] && [ "$A_RECORD" != "$SERVER_IPV4" ]; then
    echo ""
    warn "DNS A record ($A_RECORD) does not point to this server ($SERVER_IPV4)"
    warn "SSL issuance will likely fail!"
    echo ""
    read -p "Continue anyway? (y/n): " DNS_CONFIRM
    [[ ! "$DNS_CONFIRM" =~ ^[Yy]$ ]] && exit 0
fi

if detect_cloudflare "$DOMAIN"; then
    echo ""
    warn "Cloudflare proxy detected!"
    warn "Switch to DNS Only (grey cloud) before issuing ZeroSSL,"
    warn "or use Cloudflare Origin SSL instead."
    echo ""
    read -p "Continue anyway? (y/n): " CF_CONFIRM
    [[ ! "$CF_CONFIRM" =~ ^[Yy]$ ]] && exit 0
fi

if [ ! -f "$CONF" ]; then
    fail "Nginx config not found: $CONF"
    exit 1
fi

# ================================================
# WWW OPTION
# ================================================

echo ""
echo "  Include www.$DOMAIN?"
echo "  1) Yes - SSL for $DOMAIN + www.$DOMAIN"
echo "  2) No  - SSL for $DOMAIN only"
echo ""
read -p "Select [1]: " WWW_OPT
WWW_OPT="${WWW_OPT:-1}"

# ================================================
# CLEANUP OLD SSL + ISSUE
# ================================================

cleanup_old_ssl "$DOMAIN" "$CLEAN" "$CONF"
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null

echo ""
echo "Installing ZeroSSL certificate..."
echo "(This may take 1-2 minutes while verifying domain ownership)"
echo ""

# Register ACME account (idempotent)
certbot register \
    --non-interactive \
    --agree-tos \
    -m "$ADMIN_EMAIL" \
    --server "$ZEROSSL_ACME" \
    --eab-kid "$EAB_KID" \
    --eab-hmac-key "$EAB_HMAC" \
    2>/dev/null || true

# Issue certificate
if [ "$WWW_OPT" = "2" ]; then
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        -m "$ADMIN_EMAIL" \
        --server "$ZEROSSL_ACME" \
        -d "$DOMAIN" \
        --redirect
else
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        -m "$ADMIN_EMAIL" \
        --server "$ZEROSSL_ACME" \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        --redirect
fi

if [ $? -ne 0 ]; then
    fail "ZeroSSL issuance failed!"
    echo ""
    echo "Common causes:"
    echo "  - DNS not pointing to this server"
    echo "  - Port 80 blocked by firewall"
    echo "  - Cloudflare proxy enabled (use DNS Only)"
    echo ""
    echo "Try: Let's Encrypt (option 1) or Cloudflare Origin SSL (option 4)"
    exit 1
fi

ok "ZeroSSL certificate issued"

# ================================================
# TLS HARDENING
# ================================================

NGINX_BACKUP="$CONF.bak_ssl_$(date +%s)"
cp "$CONF" "$NGINX_BACKUP"

SSL_HARDENING="/etc/nginx/snippets/ssl-hardening.conf"

if [ ! -f "$SSL_HARDENING" ]; then
    mkdir -p /etc/nginx/snippets
    cat > "$SSL_HARDENING" <<'EOF'
# ShieldPress TLS Hardening
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
EOF
    if [ -f /etc/nginx/ssl/dhparam.pem ]; then
        echo "ssl_dhparam /etc/nginx/ssl/dhparam.pem;" >> "$SSL_HARDENING"
    fi
fi

if ! grep -q "ssl-hardening.conf" "$CONF"; then
    sed -i "0,/listen 443 ssl/{/listen 443 ssl/a\\    include /etc/nginx/snippets/ssl-hardening.conf;
}" "$CONF"
fi

# HSTS
enable_hsts "$CONF"

# HTTP/2
if ! grep -q "http2 on;" "$CONF"; then
    sed -i "0,/listen 443 ssl/{/listen 443 ssl/a\\    http2 on;
}" "$CONF"
fi

# HTTP/3
if nginx -V 2>&1 | grep -q http_v3_module; then
    if ! grep -q "listen 443 quic" "$CONF"; then
        sed -i "0,/listen 443 ssl/{/listen 443 ssl/a\\    listen 443 quic reuseport;
}" "$CONF"
    fi
    grep -q "Alt-Svc" "$CONF" || \
        sed -i "/server_name/a\    add_header Alt-Svc 'h3=\":443\"; ma=86400' always;" "$CONF"
fi

# Test & reload
NGINX_ERR=$(nginx -t 2>&1)
if [ $? -eq 0 ]; then
    systemctl reload nginx
    rm -f "$NGINX_BACKUP"
else
    warn "Nginx config issue after hardening, rolling back..."
    echo "$NGINX_ERR"
    cp "$NGINX_BACKUP" "$CONF"
    rm -f "$NGINX_BACKUP"
    nginx -t 2>/dev/null && systemctl reload nginx
fi

# Update domain.env
sed -i 's/^SSL=.*/SSL=enabled/' "$DOMAIN_PATH/config/domain.env"
grep -q "^SSL=" "$DOMAIN_PATH/config/domain.env" || echo "SSL=enabled" >> "$DOMAIN_PATH/config/domain.env"
sed -i '/^SSL_TYPE=/d' "$DOMAIN_PATH/config/domain.env"
echo "SSL_TYPE=zerossl" >> "$DOMAIN_PATH/config/domain.env"

# Auto-renew
systemctl enable certbot.timer 2>/dev/null
systemctl start certbot.timer 2>/dev/null

echo ""
echo "======================================"
echo " ZEROSSL INSTALLED SUCCESSFULLY"
echo "======================================"
echo " Domain  : https://$DOMAIN"
echo " Issuer  : ZeroSSL"
echo " TLS     : 1.2 + 1.3"
echo " HSTS    : Enabled"
echo " Renew   : Auto (certbot timer)"
nginx -V 2>&1 | grep -q http_v3_module && echo " HTTP/3  : Enabled"
echo "======================================"
