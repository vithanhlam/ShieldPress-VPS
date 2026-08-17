#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/ssl.log"
mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"; }
ok(){   echo "[OK] $1";   log "[OK] $1"; }
warn(){ echo "[WARN] $1"; log "[WARN] $1"; }
fail(){ echo "[FAIL] $1"; log "[FAIL] $1"; }

ensure_ssl_dependencies(){
    if ! command -v dig &>/dev/null; then
        log "Installing bind-utils..."
        dnf install -y bind-utils >/dev/null 2>&1
    fi
    if ! command -v certbot &>/dev/null; then
        log "Installing certbot..."
        dnf install -y certbot python3-certbot-nginx >/dev/null 2>&1
    fi
}

get_server_ips(){
    SERVER_IPV4=$(curl -s --connect-timeout 3 https://ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    SERVER_IPV6=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -1)
}

check_dns_records(){
    local DOMAIN=$1
    A_RECORD=$(dig +short A "$DOMAIN" 2>/dev/null | tail -1)
    AAAA_RECORD=$(dig +short AAAA "$DOMAIN" 2>/dev/null | tail -1)
    echo "A Record    : ${A_RECORD:-not found}"
    echo "AAAA Record : ${AAAA_RECORD:-not found}"
}

check_propagation(){
    local DOMAIN=$1
    echo "Checking DNS propagation..."
    for resolver in 8.8.8.8 1.1.1.1 9.9.9.9; do
        IP=$(dig @"$resolver" +short "$DOMAIN" 2>/dev/null | tail -1)
        echo "  Resolver $resolver → ${IP:-no answer}"
    done
}

detect_cloudflare(){
    local DOMAIN=$1
    local CF
    CF=$(dig +short "$DOMAIN" 2>/dev/null | grep -E "^(104\.|172\.(6[4-9]|7[0-9]|8[0-1])\.|188\.114\.|190\.93\.|197\.234\.|198\.41\.|2606:4700)")
    [ -n "$CF" ]
}

check_ssl_expiry(){
    local DOMAIN=$1
    local CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

    if [ ! -f "$CERT_PATH" ]; then
        echo "SSL not installed for $DOMAIN"
        return 1
    fi

    local EXPIRY_DATE EXPIRY_TS NOW_TS DAYS_LEFT
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
    EXPIRY_TS=$(date -d "$EXPIRY_DATE" +%s)
    NOW_TS=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

    echo "$DOMAIN SSL expires in $DAYS_LEFT days ($EXPIRY_DATE)"
    echo "$DAYS_LEFT"
}

enable_hsts(){
    local CONF=$1
    [ -f "$CONF" ] || { fail "Nginx config not found: $CONF"; return 1; }
    grep -q "Strict-Transport-Security" "$CONF" && { ok "HSTS already enabled"; return 0; }

    cp "$CONF" "$CONF.bak_hsts_$(date +%s)"
    sed -i '/server_name/a\    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;' "$CONF"
    ok "HSTS enabled (1 year)"
}

# Clean up old SSL before installing new type.
# Removes certbot certs, custom/cloudflare cert files, and SSL lines from nginx config.
# Usage: cleanup_old_ssl "$DOMAIN" "$CLEAN" "$CONF"
cleanup_old_ssl(){
    local DOMAIN="$1"
    local CLEAN="$2"
    local CONF="$3"
    local SSL_DIR="/etc/nginx/ssl/${CLEAN}"
    local OLD_TYPE=""

    # Detect current SSL type from domain.env
    local ENV_FILE
    ENV_FILE=$(find "$DOMAINS_ROOT" -path "*/${CLEAN}/config/domain.env" 2>/dev/null | head -1)
    [ -f "$ENV_FILE" ] && OLD_TYPE=$(grep "^SSL_TYPE=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    [ -z "$OLD_TYPE" ] && return 0

    echo ""
    echo "Removing old SSL ($OLD_TYPE)..."

    # 1. Remove certbot cert (letsencrypt / zerossl)
    if [[ "$OLD_TYPE" == "letsencrypt" || "$OLD_TYPE" == "zerossl" ]]; then
        certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
        certbot delete --cert-name "www.$DOMAIN" --non-interactive 2>/dev/null
        ok "Old certbot certificate removed"
    fi

    # 2. Remove custom/cloudflare cert files
    if [[ "$OLD_TYPE" == "cloudflare" || "$OLD_TYPE" == "custom" ]]; then
        rm -f "$SSL_DIR/cloudflare-origin.pem" "$SSL_DIR/cloudflare-origin.key"
        rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem"
        ok "Old certificate files removed"
    fi

    # 3. Clean SSL directives from nginx config
    if [ -f "$CONF" ]; then
        # Remove certbot-managed lines
        sed -i '/managed by Certbot/d' "$CONF"
        # Remove SSL cert/key/client lines
        sed -i '/ssl_certificate /d' "$CONF"
        sed -i '/ssl_certificate_key /d' "$CONF"
        sed -i '/ssl_client_certificate /d' "$CONF"
        # Remove listen 443 / http2 / http3 (will be re-added by new installer)
        sed -i '/listen 443/d' "$CONF"
        sed -i '/listen \[::\]:443/d' "$CONF"
        sed -i '/http2 on;/d' "$CONF"
        sed -i '/listen 443 quic/d' "$CONF"
        sed -i '/Alt-Svc/d' "$CONF"
        # Remove ssl-hardening include
        sed -i '/ssl-hardening\.conf/d' "$CONF"
        # Remove HSTS header
        sed -i '/Strict-Transport-Security/d' "$CONF"
        # Remove cloudflare realip include
        sed -i '/cloudflare-realip\.conf/d' "$CONF"
        ok "Nginx SSL config cleaned"
    fi
}
