#!/bin/bash

DOMAINS_ROOT="/home/domains"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

clear
echo "============================================================"
echo "                 SSL STATUS OVERVIEW"
echo "============================================================"
printf "%-28s %-12s %-10s %-10s\n" "Domain" "Provider" "Status" "Days Left"
echo "------------------------------------------------------------"

for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue

    # Đọc domain + SSL type từ domain.env
    DOMAIN=$(grep "^DOMAIN="      "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    CLEAN=$(grep  "^CLEAN_DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    SSL_TYPE=$(grep "^SSL_TYPE="  "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    SSL_VAL=$(grep  "^SSL="       "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

    [ -z "$DOMAIN" ] && continue

    # Fallback CLEAN_DOMAIN nếu domain.env cũ chưa có
    if [ -z "$CLEAN" ]; then
        CLEAN=$(echo "$DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
    fi

    # Xác định cert path theo SSL_TYPE
    CERT_PATH=""
    PROVIDER_LABEL=""

    case "$SSL_TYPE" in
        letsencrypt)
            CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
            PROVIDER_LABEL="Let's Encrypt"
            ;;
        zerossl)
            # ZeroSSL cũng dùng certbot/acme — cùng path với Let's Encrypt
            CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
            PROVIDER_LABEL="ZeroSSL"
            ;;
        cloudflare)
            CERT_PATH="/etc/nginx/ssl/${CLEAN}/cloudflare-origin.pem"
            PROVIDER_LABEL="Cloudflare"
            ;;
        custom)
            CERT_PATH="/etc/nginx/ssl/${CLEAN}/fullchain.pem"
            PROVIDER_LABEL="Custom"
            ;;
        *)
            # SSL_TYPE chưa set (domain cũ) — thử detect tự động
            if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
                PROVIDER_LABEL="Let's Encrypt"
            elif [ -f "/etc/nginx/ssl/${CLEAN}/cloudflare-origin.pem" ]; then
                CERT_PATH="/etc/nginx/ssl/${CLEAN}/cloudflare-origin.pem"
                PROVIDER_LABEL="Cloudflare"
            elif [ -f "/etc/nginx/ssl/${CLEAN}/fullchain.pem" ]; then
                CERT_PATH="/etc/nginx/ssl/${CLEAN}/fullchain.pem"
                PROVIDER_LABEL="Custom"
            else
                PROVIDER_LABEL="-"
            fi
            ;;
    esac

    DAYS_LEFT="-"

    if [ -n "$CERT_PATH" ] && [ -f "$CERT_PATH" ]; then
        EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
        EXPIRY_TS=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null)
        NOW_TS=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

        if [ "$DAYS_LEFT" -lt 7 ]; then
            STATUS="${RED}CRITICAL${RESET}"
        elif [ "$DAYS_LEFT" -lt 15 ]; then
            STATUS="${YELLOW}expiring${RESET}"
        else
            STATUS="${GREEN}active${RESET}"
        fi
    elif [ "$SSL_VAL" = "disabled" ] || [ -z "$SSL_TYPE" ]; then
        STATUS="${RED}disabled${RESET}"
    else
        # SSL_TYPE đã set nhưng cert file không tìm thấy — có thể bị xóa tay
        STATUS="${RED}cert missing${RESET}"
    fi

    printf "%-28s %-12s %-20b %-10s\n" "$DOMAIN" "$PROVIDER_LABEL" "$STATUS" "$DAYS_LEFT"
done

echo "------------------------------------------------------------"
echo ""

# Certbot auto-renew (dùng cho Let's Encrypt và ZeroSSL)
echo -n "Certbot Auto Renew : "
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    echo -e "${GREEN}● Active${RESET}"
elif systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
    echo -e "${GREEN}● Active (snap)${RESET}"
else
    echo -e "${YELLOW}● Not running${RESET} (run: systemctl enable --now certbot.timer)"
fi

# ACME auto-renew (ZeroSSL / acme.sh)
if command -v acme.sh >/dev/null 2>&1 || [ -f /root/.acme.sh/acme.sh ]; then
    echo -n "acme.sh Auto Renew : "
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        echo -e "${GREEN}● Active (cron)${RESET}"
    else
        echo -e "${YELLOW}● No cron found${RESET}"
    fi
fi

echo ""
