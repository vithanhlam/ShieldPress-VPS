#!/bin/bash
# ============================================================
#  Install Free SSL (Let's Encrypt) - Simplified
#  Just select domain → install → done
# ============================================================

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
MODULE_DIR="$BASE_DIR/modules/ssl"
DOMAINS_ROOT="/home/domains"

source "$MODULE_DIR/ssl-utils.sh"

DOMAIN_PATH=$1

# If no domain path passed, select from menu
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

        # Show current SSL status
        CERT_PATH="/etc/letsencrypt/live/$DNAME/fullchain.pem"
        if [ -f "$CERT_PATH" ]; then
            SSL_TAG="\e[32m[SSL]\e[0m"
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
ADMIN_EMAIL=$(grep "^ADMIN_EMAIL=" "$BASE_DIR/config.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
[ -z "$ADMIN_EMAIL" ] && ADMIN_EMAIL="admin@${DOMAIN}"

CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CONF="$SSL_NGINX_DIR/${CLEAN}.conf"

ensure_ssl_dependencies || { fail "SSL dependencies could not be installed"; exit 1; }

# Existing lineages use the renewal flow, preserving their SANs and provider.
if ssl_has_lineage "$DOMAIN"; then
    echo "Existing certificate found; keeping its provider and names, renewing when due."
    SHIELDPRESS_REUSE_ACME=1 bash "$MODULE_DIR/renew-ssl.sh" "$DOMAIN_PATH"
    exit $?
fi

echo ""
echo "===================================================="
echo "  FREE SSL (Let's Encrypt) - $DOMAIN"
echo "===================================================="
echo ""

# Quick DNS check
get_server_ips
A_RECORD=$(dig +short A "$DOMAIN" 2>/dev/null | tail -1)
CF_PROXY=0
detect_cloudflare "$DOMAIN" && CF_PROXY=1

echo "  Server IP : $SERVER_IPV4"
echo "  DNS A     : ${A_RECORD:-not found}"

if [ "$CF_PROXY" -eq 1 ]; then
    echo "  Cloudflare : proxied (orange cloud)"
    echo "  HTTP-01    : Cloudflare proxy can stay enabled if port 80 reaches this origin"
elif [ -n "$A_RECORD" ] && [ "$A_RECORD" != "$SERVER_IPV4" ]; then
    echo ""
    warn "DNS A record ($A_RECORD) does not point to this server ($SERVER_IPV4)"
    warn "SSL issuance will likely fail!"
    echo ""
    read -p "Continue anyway? [y/N]: " DNS_CONFIRM
    [[ ! "$DNS_CONFIRM" =~ ^[Yy]$ ]] && exit 0
fi

# Cloudflare proxy check
if [ "$CF_PROXY" -eq 1 ]; then
    echo ""
    warn "Cloudflare proxy detected; it can remain enabled for HTTP-01 validation. Ensure port 80 is open and Cloudflare reaches this origin."
fi

# Check nginx config
if [ ! -f "$CONF" ]; then
    fail "Nginx config not found: $CONF"
    exit 1
fi

echo ""
echo "  Include www.$DOMAIN?"
echo "  1) Yes - SSL for $DOMAIN + www.$DOMAIN"
echo "  2) No  - SSL for $DOMAIN only"
echo ""
read -p "Select [1]: " WWW_OPT
WWW_OPT="${WWW_OPT:-1}"
SSL_HOSTS=("$DOMAIN")
if [ "$WWW_OPT" = "1" ]; then
    SSL_HOSTS+=("www.$DOMAIN")
fi
check_ssl_dns_targets "${SSL_HOSTS[@]}" || exit 1

# Validate the current configuration without deleting certificates or HTTPS
nginx -t || { fail "Fix Nginx configuration before installing SSL"; exit 1; }

echo ""
echo "Installing SSL certificate..."
echo "(This may take 1-2 minutes while verifying domain ownership)"
echo ""

if [ "$WWW_OPT" = "2" ]; then
    ssl_install_nginx "$DOMAIN" "$CONF" \
        --non-interactive \
        --agree-tos \
        -m "$ADMIN_EMAIL" \
        -d "$DOMAIN" \
        --redirect
else
    ssl_install_nginx "$DOMAIN" "$CONF" \
        --non-interactive \
        --agree-tos \
        -m "$ADMIN_EMAIL" \
        -d "$DOMAIN" \
        -d "www.$DOMAIN" \
        --redirect
fi

if [ $? -ne 0 ]; then
    fail "SSL issuance failed!"
    echo ""
    echo "Common causes:"
    echo "  - DNS not pointing to this server"
    echo "  - Port 80 blocked by firewall"
    echo "  - Proxy is not forwarding HTTP-01 challenges to this server"
    echo "  - Rate limit reached (50 certs/domain/week, 5 duplicates/week)"
    exit 1
fi

ok "SSL certificate issued"

# ================================================
# TLS HARDENING (silent)
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

# Test both syntax and reload before reporting success. Keep the working
# Certbot configuration if optional hardening is unsupported by this Nginx.
if nginx -t && systemctl reload nginx; then
    rm -f "$NGINX_BACKUP"
else
    warn "Nginx hardening/reload failed; restoring working SSL configuration"
    cp "$NGINX_BACKUP" "$CONF" || exit 1
    if ! nginx -t || ! systemctl reload nginx; then
        fail "Nginx could not load SSL; backup retained at $NGINX_BACKUP"
        exit 1
    fi
    rm -f "$NGINX_BACKUP"
fi

# Update domain.env
sed -i 's/^SSL=.*/SSL=enabled/' "$DOMAIN_PATH/config/domain.env"
grep -q "^SSL=" "$DOMAIN_PATH/config/domain.env" || echo "SSL=enabled" >> "$DOMAIN_PATH/config/domain.env"
sed -i '/^SSL_TYPE=/d' "$DOMAIN_PATH/config/domain.env"
echo "SSL_TYPE=letsencrypt" >> "$DOMAIN_PATH/config/domain.env"

# Enable auto-renew
ensure_ssl_auto_renew || { fail "SSL installed, but auto-renew setup failed"; exit 1; }

echo ""
echo "======================================"
echo " SSL INSTALLED SUCCESSFULLY"
echo "======================================"
echo " Domain  : https://$DOMAIN"
echo " TLS     : 1.2 + 1.3"
echo " HSTS    : Enabled"
echo " Renew   : Auto (certbot timer)"
nginx -V 2>&1 | grep -q http_v3_module && echo " HTTP/3  : Enabled"
echo "======================================"
