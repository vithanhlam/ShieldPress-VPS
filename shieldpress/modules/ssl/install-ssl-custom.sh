#!/bin/bash
# ============================================================
#  Install Custom / Paid SSL Certificate
#  Supports: paste cert+key, or provide file paths
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

echo ""
echo "===================================================="
echo "  INSTALL CUSTOM SSL - $DOMAIN"
echo "===================================================="
echo ""
echo "  Input method:"
echo "  1) Provide file paths (cert + key files on server)"
echo "  2) Paste certificate and key content"
echo ""
read -p "Select [1]: " METHOD
METHOD="${METHOD:-1}"

CERT_FILE="$SSL_DIR/fullchain.pem"
KEY_FILE="$SSL_DIR/privkey.pem"

case "$METHOD" in
1)
    echo ""
    read -p "Full path to certificate file (.crt/.pem): " INPUT_CERT
    read -p "Full path to private key file (.key/.pem): " INPUT_KEY

    if [ ! -f "$INPUT_CERT" ]; then
        fail "Certificate file not found: $INPUT_CERT"
        exit 1
    fi
    if [ ! -f "$INPUT_KEY" ]; then
        fail "Key file not found: $INPUT_KEY"
        exit 1
    fi

    # Optional CA bundle
    read -p "CA bundle file path (optional, Enter to skip): " INPUT_CA

    if [ -n "$INPUT_CA" ] && [ -f "$INPUT_CA" ]; then
        # Combine cert + CA bundle into fullchain
        cat "$INPUT_CERT" "$INPUT_CA" > "$CERT_FILE"
        ok "Certificate + CA bundle combined"
    else
        cp "$INPUT_CERT" "$CERT_FILE"
    fi
    cp "$INPUT_KEY" "$KEY_FILE"
    ;;

2)
    echo ""
    echo "Paste your SSL certificate (including BEGIN/END lines)."
    echo "Press Ctrl+D when done:"
    echo ""
    cat > "$CERT_FILE"
    echo ""

    echo "Paste your private key (including BEGIN/END lines)."
    echo "Press Ctrl+D when done:"
    echo ""
    cat > "$KEY_FILE"
    echo ""

    read -p "Do you have a CA bundle to add? (y/n): " HAS_CA
    if [[ "$HAS_CA" =~ ^[Yy]$ ]]; then
        echo "Paste CA bundle (including BEGIN/END lines)."
        echo "Press Ctrl+D when done:"
        echo ""
        CA_TMP="/tmp/ca_bundle_$$.pem"
        cat > "$CA_TMP"
        cat "$CA_TMP" >> "$CERT_FILE"
        rm -f "$CA_TMP"
        ok "CA bundle appended"
    fi
    ;;

*)
    fail "Invalid option"
    exit 1
    ;;
esac

# Secure permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Validate certificate
echo ""
echo "Validating certificate..."

if ! openssl x509 -noout -in "$CERT_FILE" 2>/dev/null; then
    fail "Invalid certificate file!"
    exit 1
fi

# Check cert matches key
CERT_MOD=$(openssl x509 -noout -modulus -in "$CERT_FILE" 2>/dev/null | md5sum)
KEY_MOD=$(openssl rsa -noout -modulus -in "$KEY_FILE" 2>/dev/null | md5sum)

if [ "$CERT_MOD" != "$KEY_MOD" ]; then
    fail "Certificate and private key do NOT match!"
    exit 1
fi

ok "Certificate and key are valid and match"

# Show cert info
CERT_CN=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null | sed 's/.*CN *= *//')
CERT_ISSUER=$(openssl x509 -noout -issuer -in "$CERT_FILE" 2>/dev/null | sed 's/.*O *= *//' | cut -d'/' -f1)
CERT_EXPIRY=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)

echo ""
echo "  CN      : $CERT_CN"
echo "  Issuer  : $CERT_ISSUER"
echo "  Expires : $CERT_EXPIRY"
echo ""

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

# Check if already has ssl_certificate directives
if grep -q "ssl_certificate " "$CONF"; then
    # Update existing
    sed -i "s|ssl_certificate .*|ssl_certificate $CERT_FILE;|" "$CONF"
    sed -i "s|ssl_certificate_key .*|ssl_certificate_key $KEY_FILE;|" "$CONF"
else
    # Add SSL config to server block
    if grep -q "listen 443" "$CONF"; then
        sed -i "0,/listen 443/{/listen 443/a\\    ssl_certificate $CERT_FILE;\n    ssl_certificate_key $KEY_FILE;
}" "$CONF"
    else
        sed -i "0,/listen 80/{/listen 80/a\\    listen 443 ssl;\n    listen [::]:443 ssl;\n    ssl_certificate $CERT_FILE;\n    ssl_certificate_key $KEY_FILE;
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
echo "SSL_TYPE=custom" >> "$DOMAIN_PATH/config/domain.env"

echo ""
echo "======================================"
echo " CUSTOM SSL INSTALLED SUCCESSFULLY"
echo "======================================"
echo " Domain  : https://$DOMAIN"
echo " Cert    : $CERT_FILE"
echo " Key     : $KEY_FILE"
echo " Issuer  : $CERT_ISSUER"
echo " Expires : $CERT_EXPIRY"
echo "======================================"
