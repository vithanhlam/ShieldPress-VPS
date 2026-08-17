#!/bin/bash

DOMAINS_ROOT="/home/domains"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

clear
echo "================================================================"
echo "                    SMART CACHE STATUS"
echo "================================================================"
printf "%-25s %-10s %-10s %-10s %-6s %-10s\n" "Domain" "FastCGI" "Valkey" "OPcache" "PHP" "CacheSize"
echo "----------------------------------------------------------------"

for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue

    DOMAIN=$(grep      "^DOMAIN="      "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    PHP_VER=$(grep     "^PHP_VERSION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    SYSUSER=$(grep     "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    ROOT_DIR="$d/public_html"

    [ -z "$DOMAIN" ] && continue

    CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN}.conf"
    WP_CONFIG="$ROOT_DIR/wp-config.php"
    PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
    PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

    # FastCGI - check per-domain zone trước, sau đó check zone cũ
    if [ -f "$NGINX_CONF" ] && grep -qE "fastcgi_cache.*SHIELDPRESS" "$NGINX_CONF"; then
        FASTCGI="${GREEN}ON${RESET}"
    else
        FASTCGI="${RED}OFF${RESET}"
    fi

    # Valkey (check wp-config)
    if [ -f "$WP_CONFIG" ] && grep -q "WP_REDIS_HOST" "$WP_CONFIG"; then
        VALKEY="${GREEN}ON${RESET}"
    else
        VALKEY="${RED}OFF${RESET}"
    fi

    # OPcache
    OPCACHE="${RED}OFF${RESET}"
    if [ -x "$PHP_BIN" ]; then
        if "$PHP_BIN" -i 2>/dev/null | grep -q "opcache.enable => On"; then
            OPCACHE="${GREEN}ON${RESET}"
        fi
    fi

    # Cache size per domain
    CACHE_DIR="/var/cache/nginx/${CLEAN}"
    if [ -d "$CACHE_DIR" ]; then
        CACHE_SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
    else
        CACHE_SIZE="-"
    fi

    printf "%-25s %-10b %-10b %-10b %-6s %-10s\n" \
        "$DOMAIN" "$FASTCGI" "$VALKEY" "$OPCACHE" "$PHP_VER" "$CACHE_SIZE"
done

echo "================================================================"
echo ""

# Tổng cache size
TOTAL_CACHE="0"
if [ -d /var/cache/nginx ]; then
    TOTAL_CACHE=$(du -sh /var/cache/nginx 2>/dev/null | awk '{print $1}')
fi
echo -n "Total cache size : $TOTAL_CACHE"
echo ""

echo -n "Valkey : "
systemctl is-active --quiet valkey && echo -e "${GREEN}running${RESET}" || echo -e "${RED}stopped${RESET}"

# Valkey memory info
if valkey-cli ping >/dev/null 2>&1; then
    VALKEY_MEM=$(valkey-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
    VALKEY_MAX=$(valkey-cli config get maxmemory 2>/dev/null | tail -1 | tr -d '\r')
    echo "Valkey memory    : ${VALKEY_MEM:-unknown}"
    [ -n "$VALKEY_MAX" ] && [ "$VALKEY_MAX" != "0" ] && \
        echo "Valkey maxmemory : $(echo "$VALKEY_MAX" | awk '{printf "%.0fMB", $1/1024/1024}')"
fi

echo ""
read -p "Press Enter..."
