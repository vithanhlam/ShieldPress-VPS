#!/bin/bash
# ============================================================
#  Install Cloudflare Origin SSL Certificate
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/ssl"
DOMAINS_ROOT="/home/domains"

source "$MODULE_DIR/ssl-utils.sh"

DOMAIN_PATH=$1

if [ -z "$DOMAIN_PATH" ] || [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    fail "domain.env not found: $DOMAIN_PATH"
    exit 1
fi

DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CONF="/etc/nginx/conf.d/${CLEAN}.conf"

SSL_DIR="/etc/nginx/ssl/${CLEAN}"
mkdir -p "$SSL_DIR"

CERT_FILE="$SSL_DIR/cloudflare-origin.pem"
KEY_FILE="$SSL_DIR/cloudflare-origin.key"

# ================================================
# READ PEM BLOCK (auto-detect END marker)
# Usage: read_pem_block "CERTIFICATE" > output.pem
# ================================================
read_pem_block(){
    local type="$1"
    local started=0
    local content=""

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ "$started" -eq 0 ] && [ -z "$line" ] && continue

        if echo "$line" | grep -q "BEGIN $type"; then
            started=1
        fi

        if [ "$started" -eq 1 ]; then
            content+="$line"$'\n'
        fi

        if echo "$line" | grep -q "END $type"; then
            break
        fi
    done

    echo -n "$content"
}

# ================================================
# INSTRUCTIONS
# ================================================

clear
echo "===================================================="
echo "  CLOUDFLARE ORIGIN SSL - $DOMAIN"
echo "===================================================="
echo ""
echo "  How to create an Origin Certificate on Cloudflare:"
echo ""
echo "  Step 1: Log in to https://dash.cloudflare.com"
echo "  Step 2: Select your domain: $DOMAIN"
echo "  Step 3: Left menu > SSL/TLS > Origin Server"
echo "  Step 4: Click [Create Certificate]"
echo "  Step 5: Keep defaults (RSA), click [Create]"
echo "          Cloudflare will auto-add $DOMAIN and *.$DOMAIN"
echo "  Step 6: Select validity: 15 years (recommended)"
echo "  Step 7: Click [Create] > two boxes will appear:"
echo "          - Origin Certificate (top box)"
echo "          - Private Key (bottom box)"
echo "  Step 8: Copy both, then paste them here"
echo ""
echo "  NOTE: After closing the page, you CANNOT view the"
echo "  Private Key again. Paste it here immediately."
echo ""
echo "  Set Cloudflare SSL mode to: Full (Strict)"
echo ""

read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ================================================
# INPUT METHOD
# ================================================

echo ""
echo "  Input method:"
echo "  1) Paste directly (copy from Cloudflare and paste here)"
echo "  2) Provide file paths (if cert/key are saved on server)"
echo ""
read -p "  Select [1]: " INPUT_METHOD
INPUT_METHOD="${INPUT_METHOD:-1}"

case "$INPUT_METHOD" in
2)
    echo ""
    read -p "  Certificate file path (.pem/.crt): " INPUT_CERT
    read -p "  Private Key file path (.key/.pem): " INPUT_KEY

    if [ ! -f "$INPUT_CERT" ]; then
        fail "File not found: $INPUT_CERT"
        exit 1
    fi
    if [ ! -f "$INPUT_KEY" ]; then
        fail "File not found: $INPUT_KEY"
        exit 1
    fi

    cp "$INPUT_CERT" "$CERT_FILE"
    cp "$INPUT_KEY" "$KEY_FILE"
    ;;

*)
    echo ""
    echo "────────────────────────────────────────"
    echo "  Paste your Origin Certificate below"
    echo "  (starts with -----BEGIN CERTIFICATE-----)"
    echo "  It will be detected automatically."
    echo "────────────────────────────────────────"
    echo ""

    read_pem_block "CERTIFICATE" > "$CERT_FILE"

    if [ ! -s "$CERT_FILE" ]; then
        fail "No certificate received!"
        rm -f "$CERT_FILE"
        exit 1
    fi
    ok "Certificate received"

    echo ""
    echo "────────────────────────────────────────"
    echo "  Paste your Private Key below"
    echo "  (starts with -----BEGIN PRIVATE KEY-----)"
    echo "────────────────────────────────────────"
    echo ""

    # Read key - supports both PRIVATE KEY and RSA PRIVATE KEY formats
    key_content=""
    started=0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ "$started" -eq 0 ] && [ -z "$line" ] && continue

        if echo "$line" | grep -q "BEGIN.*PRIVATE KEY"; then
            started=1
        fi

        if [ "$started" -eq 1 ]; then
            key_content+="$line"$'\n'
        fi

        if echo "$line" | grep -q "END.*PRIVATE KEY"; then
            break
        fi
    done

    echo -n "$key_content" > "$KEY_FILE"

    if [ ! -s "$KEY_FILE" ]; then
        fail "No private key received!"
        rm -f "$KEY_FILE" "$CERT_FILE"
        exit 1
    fi
    ok "Private Key received"
    ;;
esac

# Secure permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# ================================================
# VALIDATE
# ================================================

echo ""
echo "Validating..."

if ! openssl x509 -noout -in "$CERT_FILE" 2>/dev/null; then
    fail "Invalid certificate!"
    rm -f "$CERT_FILE" "$KEY_FILE"
    exit 1
fi

# Check cert matches key
CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_FILE" 2>/dev/null | md5sum)
KEY_MOD=$(openssl rsa -noout -modulus -in "$KEY_FILE" 2>/dev/null | md5sum)

if [ "$CERT_MOD" != "$KEY_MOD" ]; then
    fail "Certificate and Private Key do NOT match!"
    rm -f "$CERT_FILE" "$KEY_FILE"
    exit 1
fi

CERT_EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
CERT_ISSUER=$(openssl x509 -noout -issuer -in "$CERT_FILE" 2>/dev/null | sed 's/.*O *= *//' | cut -d'/' -f1)
CERT_DOMAINS=$(openssl x509 -noout -ext subjectAltName -in "$CERT_FILE" 2>/dev/null | grep -oP 'DNS:[^ ,]+' | sed 's/DNS://g' | tr '\n' ', ' | sed 's/,$//')

ok "Certificate is valid"
echo "  Issuer  : $CERT_ISSUER"
echo "  Domains : ${CERT_DOMAINS:-$DOMAIN}"
echo "  Expires : $CERT_EXPIRY"

# ================================================
# DOWNLOAD CLOUDFLARE ORIGIN CA ROOT
# ================================================

CF_CA_FILE="/etc/nginx/ssl/cloudflare-origin-ca.pem"
if [ ! -f "$CF_CA_FILE" ]; then
    echo ""
    echo "Downloading Cloudflare Origin CA..."
    curl -sS -o "$CF_CA_FILE" "https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem" 2>/dev/null
    if [ -s "$CF_CA_FILE" ]; then
        ok "Cloudflare Origin CA downloaded"
    else
        warn "Could not download CA root (non-critical)"
        rm -f "$CF_CA_FILE"
    fi
fi

# ================================================
# UPDATE NGINX CONFIG
# ================================================

if [ ! -f "$CONF" ]; then
    fail "Nginx config not found: $CONF"
    exit 1
fi

NGINX_BACKUP="$CONF.bak_ssl_$(date +%s)"
cp "$CONF" "$NGINX_BACKUP"

# Clean up old SSL if switching type
cleanup_old_ssl "$DOMAIN" "$CLEAN" "$CONF"

# Add SSL directives
if grep -q "ssl_certificate " "$CONF"; then
    sed -i "s|ssl_certificate .*|ssl_certificate $CERT_FILE;|" "$CONF"
    sed -i "s|ssl_certificate_key .*|ssl_certificate_key $KEY_FILE;|" "$CONF"
else
    if grep -q "listen 443" "$CONF"; then
        sed -i "0,/listen 443/{/listen 443/a\\    ssl_certificate $CERT_FILE;\n    ssl_certificate_key $KEY_FILE;
}" "$CONF"
    else
        sed -i "0,/listen 80/{/listen 80/a\\    listen 443 ssl;\n    listen [::]:443 ssl;\n    ssl_certificate $CERT_FILE;\n    ssl_certificate_key $KEY_FILE;
}" "$CONF"
    fi
fi

# Cloudflare Origin CA for client verification
if [ -f "$CF_CA_FILE" ]; then
    if ! grep -q "ssl_client_certificate" "$CONF"; then
        sed -i "0,/ssl_certificate_key/{/ssl_certificate_key/a\\    ssl_client_certificate $CF_CA_FILE;
}" "$CONF"
    fi
fi

# TLS hardening
SSL_HARDENING="/etc/nginx/snippets/ssl-hardening.conf"
if [ -f "$SSL_HARDENING" ] && ! grep -q "ssl-hardening.conf" "$CONF"; then
    sed -i "0,/ssl_certificate_key/{/ssl_certificate_key/a\\    include /etc/nginx/snippets/ssl-hardening.conf;
}" "$CONF"
fi

# HSTS
enable_hsts "$CONF"

# HTTP/2
if ! grep -q "http2 on;" "$CONF"; then
    sed -i "0,/listen 443 ssl/{/listen 443 ssl/a\\    http2 on;
}" "$CONF"
fi

# Cloudflare Real IP
if ! grep -q "real_ip_header" "$CONF"; then
    CF_REALIP="/etc/nginx/snippets/cloudflare-realip.conf"
    if [ ! -f "$CF_REALIP" ]; then
        mkdir -p /etc/nginx/snippets
        cat > "$CF_REALIP" <<'EOF'
# Cloudflare Real IP
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;
EOF
    fi
    sed -i "/server_name/a\\    include /etc/nginx/snippets/cloudflare-realip.conf;" "$CONF"
    ok "Cloudflare Real IP configured"
fi

# Test and reload
NGINX_ERR=$(nginx -t 2>&1)
if [ $? -eq 0 ]; then
    systemctl reload nginx
    ok "Nginx reloaded"
    rm -f "$NGINX_BACKUP"
else
    fail "Nginx config error, rolling back..."
    echo ""
    echo "$NGINX_ERR"
    echo ""
    cp "$NGINX_BACKUP" "$CONF"
    rm -f "$NGINX_BACKUP"
    nginx -t 2>/dev/null && systemctl reload nginx
    exit 1
fi

# Update domain.env
sed -i 's/^SSL=.*/SSL=enabled/' "$DOMAIN_PATH/config/domain.env"
grep -q "^SSL=" "$DOMAIN_PATH/config/domain.env" || echo "SSL=enabled" >> "$DOMAIN_PATH/config/domain.env"
sed -i '/^SSL_TYPE=/d' "$DOMAIN_PATH/config/domain.env"
echo "SSL_TYPE=cloudflare" >> "$DOMAIN_PATH/config/domain.env"

echo ""
echo "======================================"
echo " CLOUDFLARE ORIGIN SSL INSTALLED"
echo "======================================"
echo " Domain  : https://$DOMAIN"
echo " Cert    : $CERT_FILE"
echo " Expires : $CERT_EXPIRY"
echo " Renew   : Not needed (15-year cert)"
echo ""
echo " Remember to set Cloudflare SSL mode"
echo " to 'Full (Strict)' in your dashboard!"
echo "======================================"
