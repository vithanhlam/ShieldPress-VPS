#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }

echo "===================================================="
echo "              NGINX STATUS & INFO"
echo "===================================================="
echo ""

# ================================================
# Service Status
# ================================================

echo -e "${BOLD}Service Status${RESET}"
echo "----------------------------------------------------"
STATE=$(systemctl is-active nginx 2>/dev/null)
if [ "$STATE" = "active" ]; then
    echo -e "  Status   : ${GREEN}● Running${RESET}"
else
    echo -e "  Status   : ${RED}● $STATE${RESET}"
fi

ENABLED=$(systemctl is-enabled nginx 2>/dev/null)
echo "  Boot     : $ENABLED"

PID=$(pgrep -o nginx 2>/dev/null)
[ -n "$PID" ] && echo "  PID      : $PID" || echo "  PID      : N/A"

UPTIME=$(systemctl show nginx --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
[ -n "$UPTIME" ] && echo "  Since    : $UPTIME"

echo ""

# ================================================
# Version & Build Info
# ================================================

echo -e "${BOLD}Version & Build${RESET}"
echo "----------------------------------------------------"
nginx -v 2>&1 | sed 's/^/  /'
echo ""

echo "  Compiled modules:"
nginx -V 2>&1 | tr ' ' '\n' | grep -- '--with-' | sed 's/^/    /' | head -30

echo ""

# ================================================
# Key Modules Detection
# ================================================

echo -e "${BOLD}Key Modules${RESET}"
echo "----------------------------------------------------"

NGINX_V=$(nginx -V 2>&1)

check_module(){
    local NAME="$1"
    local MODULE="$2"
    if echo "$NGINX_V" | grep -q "$MODULE"; then
        echo -e "  ${GREEN}✓${RESET} $NAME"
    else
        echo -e "  ${RED}✗${RESET} $NAME"
    fi
}

check_module "HTTP/2"              "http_v2_module"
check_module "HTTP/3 (QUIC)"       "http_v3_module"
check_module "SSL/TLS"             "http_ssl_module"
check_module "Gzip"                "http_gzip"
check_module "Brotli"              "ngx_brotli"
check_module "GeoIP2"              "geoip2"
check_module "Headers More"        "headers_more"
check_module "Real IP"             "http_realip_module"
check_module "Stub Status"         "http_stub_status_module"
check_module "Stream (TCP/UDP)"    "stream_module"

echo ""

# ================================================
# Configuration Files
# ================================================

echo -e "${BOLD}Configuration${RESET}"
echo "----------------------------------------------------"
echo "  Main config  : /etc/nginx/nginx.conf"
echo "  Conf.d       : /etc/nginx/conf.d/"

VHOST_COUNT=$(ls /etc/nginx/conf.d/*.conf 2>/dev/null | grep -v shieldpress | grep -v cache-zone | wc -l)
CACHE_COUNT=$(ls /etc/nginx/conf.d/cache-zone-*.conf 2>/dev/null | wc -l)
echo "  Virtual hosts : $VHOST_COUNT"
echo "  Cache zones   : $CACHE_COUNT"

echo ""

# ================================================
# Config Test
# ================================================

echo -e "${BOLD}Config Test${RESET}"
echo "----------------------------------------------------"
if nginx -t 2>&1; then
    ok "Configuration OK"
else
    fail "Configuration has errors"
fi

echo ""

# ================================================
# Connections (if stub_status is available)
# ================================================

if echo "$NGINX_V" | grep -q "http_stub_status_module"; then
    STUB_URL="http://127.0.0.1/nginx_status"
    STUB_DATA=$(curl -s "$STUB_URL" 2>/dev/null)
    if [ -n "$STUB_DATA" ] && echo "$STUB_DATA" | grep -q "Active connections"; then
        echo -e "${BOLD}Live Connections${RESET}"
        echo "----------------------------------------------------"
        echo "$STUB_DATA" | sed 's/^/  /'
        echo ""
    fi
fi

# ================================================
# Worker Info
# ================================================

echo -e "${BOLD}Worker Processes${RESET}"
echo "----------------------------------------------------"
WORKER_COUNT=$(pgrep -c "nginx: worker" 2>/dev/null || echo 0)
echo "  Workers running : $WORKER_COUNT"

WORKER_PROC=$(grep "^worker_processes" /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
echo "  Workers config  : ${WORKER_PROC:-auto}"

WORKER_CONN=$(grep "worker_connections" /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
echo "  Connections/worker : ${WORKER_CONN:-1024}"

echo ""

# ================================================
# HTTP/3 Status
# ================================================

echo -e "${BOLD}HTTP/3 Status${RESET}"
echo "----------------------------------------------------"
if [ -f /etc/nginx/conf.d/shieldpress-http3.conf ]; then
    ok "HTTP/3 config enabled"
else
    warn "HTTP/3 not configured"
fi

echo ""

# ================================================
# FastCGI Cache Status
# ================================================

echo -e "${BOLD}FastCGI Cache${RESET}"
echo "----------------------------------------------------"
if [ -d /var/cache/nginx ] && ls /var/cache/nginx/*/ &>/dev/null 2>&1; then
    CACHE_SIZE=$(du -sh /var/cache/nginx/ 2>/dev/null | awk '{print $1}')
    echo "  Cache directory : /var/cache/nginx/"
    echo "  Current size    : ${CACHE_SIZE:-0}"
    echo "  Domains cached  :"
    for cdir in /var/cache/nginx/*/; do
        [ -d "$cdir" ] || continue
        DNAME=$(basename "$cdir")
        DSIZE=$(du -sh "$cdir" 2>/dev/null | awk '{print $1}')
        echo "    - $DNAME ($DSIZE)"
    done
else
    warn "No FastCGI cache active"
fi

echo ""
read -p "Press Enter..."
