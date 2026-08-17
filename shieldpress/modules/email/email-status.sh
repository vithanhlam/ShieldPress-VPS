#!/bin/bash
# ============================================================
#  Email Server Status
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Email Server Status" "Services & configuration"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

echo ""

# Service status
echo -e "  ${BOLD}Services:${RESET}"
echo -e "  ──────────────────────────────────────"

check_service(){
    local name="$1"
    local service="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "  %-16s ${GREEN}● Running${RESET}\n" "$name"
    else
        printf "  %-16s ${RED}● Stopped${RESET}\n" "$name"
    fi
}

check_service "Postfix"   "postfix"
check_service "Dovecot"   "dovecot"
check_service "Rspamd"    "rspamd"
check_service "OpenDKIM"  "opendkim"

echo ""

# Configuration info
if [ -f "$EMAIL_CONFIG" ]; then
    MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" | cut -d'=' -f2 | tr -d '[:space:]')
    MAIL_HOSTNAME=$(grep "^MAIL_HOSTNAME=" "$EMAIL_CONFIG" | cut -d'=' -f2 | tr -d '[:space:]')
    INSTALLED=$(grep "^INSTALLED=" "$EMAIL_CONFIG" | cut -d'=' -f2-)

    echo -e "  ${BOLD}Configuration:${RESET}"
    echo -e "  ──────────────────────────────────────"
    echo -e "  Domain     : ${CYAN}${MAIL_DOMAIN}${RESET}"
    echo -e "  Hostname   : ${CYAN}${MAIL_HOSTNAME}${RESET}"
    echo -e "  Installed  : ${DIM}${INSTALLED}${RESET}"
fi

# Relay status
echo ""
get_relay_info
echo -e "  ${BOLD}SMTP Relay:${RESET}"
echo -e "  ──────────────────────────────────────"
echo -e "  Type       : ${CYAN}${RELAY_STATUS}${RESET}"

# SSL status
echo ""
echo -e "  ${BOLD}SSL Certificate:${RESET}"
echo -e "  ──────────────────────────────────────"
if [ -n "$MAIL_HOSTNAME" ]; then
    CERT_PATH="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
        EXPIRY_TS=$(date -d "$EXPIRY" +%s 2>/dev/null)
        NOW_TS=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

        if [ "$DAYS_LEFT" -gt 30 ]; then
            echo -e "  Status     : ${GREEN}Let's Encrypt (${DAYS_LEFT} days left)${RESET}"
        elif [ "$DAYS_LEFT" -gt 0 ]; then
            echo -e "  Status     : ${YELLOW}Let's Encrypt (${DAYS_LEFT} days left - renew soon!)${RESET}"
        else
            echo -e "  Status     : ${RED}EXPIRED${RESET}"
        fi
    else
        echo -e "  Status     : ${YELLOW}Self-signed (Let's Encrypt not configured)${RESET}"
    fi
fi

# Accounts count
echo ""
echo -e "  ${BOLD}Accounts:${RESET}"
echo -e "  ──────────────────────────────────────"
TOTAL_ACCOUNTS=0
TOTAL_DOMAINS=0
for d in "$MAIL_DIR"/*/; do
    [ -d "$d" ] || continue
    ((TOTAL_DOMAINS++))
    for u in "$d"/*/; do
        [ -d "$u" ] || continue
        ((TOTAL_ACCOUNTS++))
    done
done
echo -e "  Domains    : ${CYAN}${TOTAL_DOMAINS}${RESET}"
echo -e "  Accounts   : ${CYAN}${TOTAL_ACCOUNTS}${RESET}"

# Mail queue
echo ""
echo -e "  ${BOLD}Mail Queue:${RESET}"
echo -e "  ──────────────────────────────────────"
QUEUE_COUNT=$(postqueue -p 2>/dev/null | tail -1 | grep -oP '\d+' | head -1)
[ -z "$QUEUE_COUNT" ] && QUEUE_COUNT=0
if [ "$QUEUE_COUNT" -eq 0 ]; then
    echo -e "  Queue      : ${GREEN}Empty${RESET}"
else
    echo -e "  Queue      : ${YELLOW}${QUEUE_COUNT} message(s)${RESET}"
fi

# Port check
echo ""
echo -e "  ${BOLD}Ports:${RESET}"
echo -e "  ──────────────────────────────────────"

check_port(){
    local port="$1"
    local name="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        printf "  %-6s %-20s ${GREEN}● Open${RESET}\n" "$port" "$name"
    else
        printf "  %-6s %-20s ${RED}● Closed${RESET}\n" "$port" "$name"
    fi
}

check_port 25  "SMTP"
check_port 587 "Submission (STARTTLS)"
check_port 993 "IMAPS (SSL)"
check_port 143 "IMAP"

echo ""
read -p "Press Enter..."
