#!/bin/bash

DOMAINS_ROOT="/home/domains"
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo "================================================================================"
echo "                                DOMAIN LIST"
echo "================================================================================"
printf "%-25s %-12s %-8s %-8s %-10s %-8s %-10s\n" \
    "Domain" "Created" "PHP" "SSL" "Status" "WP" "Size"
echo "--------------------------------------------------------------------------------"

for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue

    DOMAIN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    CREATED=$(grep "^CREATED=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    PHP_VER=$(grep "^PHP_VERSION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    SSL=$(grep "^SSL=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

    [ -z "$DOMAIN" ] && continue

    CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN}.conf"

    # ===== STATUS =====
    LOCK_FILE="${NGINX_CONF}.lock"
    if [ -f "$LOCK_FILE" ] && [ -f "${NGINX_CONF}.disabled" ]; then
        STATUS="${RED}LOCKED${RESET}"
    elif [ -f "${NGINX_CONF}.disabled" ]; then
        STATUS="${YELLOW}OFF${RESET}"
    elif [ -f "$NGINX_CONF" ]; then
        STATUS="${GREEN}ON${RESET}"
    else
        STATUS="${RED}NO CONF${RESET}"
    fi

    # ===== WORDPRESS =====
    if [ -f "$d/public_html/wp-config.php" ]; then
        WP="${GREEN}Yes${RESET}"
    else
        WP="${YELLOW}No${RESET}"
    fi

    # ===== SSL =====
    [ "$SSL" = "enabled" ] && SSL_D="${GREEN}ON${RESET}" || SSL_D="${RED}OFF${RESET}"

    # ===== SIZE (NEW) =====
    SIZE=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    [ -z "$SIZE" ] && SIZE="0"

    printf "%-25s %-12s %-8s %-8b %-10b %-8b %-10s\n" \
        "$DOMAIN" "${CREATED:--}" "$PHP_VER" "$SSL_D" "$STATUS" "$WP" "$SIZE"
done

echo "================================================================================"
echo ""

# ===== TOTAL =====
TOTAL=$(ls -d "$DOMAINS_ROOT"/*/ 2>/dev/null | wc -l)

# Tổng dung lượng
TOTAL_SIZE=$(du -sh "$DOMAINS_ROOT" 2>/dev/null | awk '{print $1}')

echo "Total domains : $TOTAL"
echo "Total disk    : $TOTAL_SIZE"
echo ""

read -p "Press Enter..."