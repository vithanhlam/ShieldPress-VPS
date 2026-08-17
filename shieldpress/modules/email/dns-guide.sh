#!/bin/bash
# ============================================================
#  DNS Records Guide for Email
#  - Shows clean copy-paste ready records
#  - Exports to file for Cloudflare import
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "DNS Records Guide" "Required DNS for email"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

# Get config
MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')

if [ -z "$MAIL_DOMAIN" ]; then
    read -p "Enter domain: " MAIL_DOMAIN
fi

get_server_ip

# Get clean DKIM value
DKIM_VALUE=$(get_dkim_value "$MAIL_DOMAIN")

echo ""
echo -e "  ${BOLD}${YELLOW}Add these DNS records at your domain registrar:${RESET}"
echo ""

# MX Record
echo -e "  ${BOLD}${CYAN}1. MX Record${RESET} (receive email)"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Type     : MX"
echo -e "  Name     : ${GREEN}@${RESET}"
echo -e "  Value    : ${GREEN}mail.${MAIL_DOMAIN}${RESET}"
echo -e "  Priority : ${GREEN}10${RESET}"
echo ""

# A Record
echo -e "  ${BOLD}${CYAN}2. A Record${RESET} (mail server hostname)"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Type     : A"
echo -e "  Name     : ${GREEN}mail${RESET}"
echo -e "  Value    : ${GREEN}${SERVER_IP:-YOUR_SERVER_IP}${RESET}"
echo -e "  Proxy    : ${RED}DNS only (grey cloud)${RESET}  — NEVER orange cloud"
echo ""
echo -e "  ${BOLD}${RED}  IMPORTANT — Cloudflare users:${RESET}"
echo -e "  ${YELLOW}  The 'mail' A record MUST be set to DNS only (grey cloud).${RESET}"
echo -e "  ${YELLOW}  If the orange cloud (proxy) is ON, Cloudflare only forwards${RESET}"
echo -e "  ${YELLOW}  HTTP/HTTPS traffic. Ports 25, 587, 993 are blocked entirely.${RESET}"
echo -e "  ${YELLOW}  Result: SMTP and IMAP connections fail from all clients,${RESET}"
echo -e "  ${YELLOW}  including WordPress, Outlook, and Thunderbird.${RESET}"
echo ""

# SPF Record
echo -e "  ${BOLD}${CYAN}3. SPF Record${RESET} (authorize sending)"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Type     : TXT"
echo -e "  Name     : ${GREEN}@${RESET}"
echo -e "  Value    :"
echo ""
echo -e "  ${GREEN}v=spf1 mx a ip4:${SERVER_IP:-YOUR_IP} ~all${RESET}"
echo ""

# DKIM Record
echo -e "  ${BOLD}${CYAN}4. DKIM Record${RESET} (email signing)"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Type     : TXT"
echo -e "  Name     : ${GREEN}mail._domainkey${RESET}"
echo -e "  Value    :"
echo ""

if [ -n "$DKIM_VALUE" ]; then
    echo -e "  ${GREEN}${DKIM_VALUE}${RESET}"
else
    echo -e "  ${RED}DKIM key not generated yet${RESET}"
fi
echo ""

# DMARC Record
echo -e "  ${BOLD}${CYAN}5. DMARC Record${RESET} (policy enforcement)"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Type     : TXT"
echo -e "  Name     : ${GREEN}_dmarc${RESET}"
echo -e "  Value    :"
echo ""
echo -e "  ${GREEN}v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}${RESET}"
echo ""

# Reverse DNS
echo -e "  ${BOLD}${CYAN}6. Reverse DNS (PTR)${RESET} ${DIM}(set at VPS provider)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  IP       : ${GREEN}${SERVER_IP:-YOUR_IP}${RESET}"
echo -e "  Hostname : ${GREEN}mail.${MAIL_DOMAIN}${RESET}"
echo -e "  ${DIM}Set this in your VPS provider's control panel${RESET}"
echo ""

sp_hr

# Export to file
echo ""
EXPORT_FILE=$(export_dns_records "$MAIL_DOMAIN" "${SERVER_IP:-YOUR_SERVER_IP}")
ok "DNS records exported"
echo ""
echo -e "  ${BOLD}File:${RESET} ${CYAN}${EXPORT_FILE}${RESET}"
echo ""
echo -e "  ${DIM}Download via SFTP:${RESET}"
echo -e "  ${DIM}  sftp root@${SERVER_IP:-YOUR_IP}:${EXPORT_FILE} .${RESET}"
echo -e "  ${DIM}Copy each record into Cloudflare DNS panel${RESET}"
echo -e "  ${DIM}Delete file after use: rm ${EXPORT_FILE}${RESET}"

# Verify current DNS
echo ""
sp_hr
echo ""
echo -e "  ${BOLD}Current DNS Status:${RESET}"
echo -e "  ──────────────────────────────────────────────────"

if command -v dig &>/dev/null; then
    # Check MX
    MX_RECORD=$(dig +short MX "$MAIL_DOMAIN" 2>/dev/null | head -1)
    if [ -n "$MX_RECORD" ]; then
        echo -e "  MX     : ${GREEN}$MX_RECORD${RESET}"
    else
        echo -e "  MX     : ${RED}Not configured${RESET}"
    fi

    # Check A record for mail
    A_RECORD=$(dig +short A "mail.${MAIL_DOMAIN}" 2>/dev/null | head -1)
    if [ -n "$A_RECORD" ]; then
        if [ "$A_RECORD" = "$SERVER_IP" ]; then
            echo -e "  A      : ${GREEN}$A_RECORD (correct)${RESET}"
        else
            echo -e "  A      : ${YELLOW}$A_RECORD (expected $SERVER_IP)${RESET}"
        fi
    else
        echo -e "  A      : ${RED}Not configured${RESET}"
    fi

    # Check SPF
    SPF_RECORD=$(dig +short TXT "$MAIL_DOMAIN" 2>/dev/null | grep "v=spf1" | head -1)
    if [ -n "$SPF_RECORD" ]; then
        echo -e "  SPF    : ${GREEN}$SPF_RECORD${RESET}"
    else
        echo -e "  SPF    : ${RED}Not configured${RESET}"
    fi

    # Check DKIM
    DKIM_RECORD=$(dig +short TXT "mail._domainkey.${MAIL_DOMAIN}" 2>/dev/null | head -1)
    if [ -n "$DKIM_RECORD" ]; then
        echo -e "  DKIM   : ${GREEN}Configured${RESET}"
    else
        echo -e "  DKIM   : ${RED}Not configured${RESET}"
    fi

    # Check DMARC
    DMARC_RECORD=$(dig +short TXT "_dmarc.${MAIL_DOMAIN}" 2>/dev/null | head -1)
    if [ -n "$DMARC_RECORD" ]; then
        echo -e "  DMARC  : ${GREEN}$DMARC_RECORD${RESET}"
    else
        echo -e "  DMARC  : ${RED}Not configured${RESET}"
    fi
else
    echo -e "  ${DIM}Install bind-utils for DNS verification: dnf install bind-utils${RESET}"
fi

echo ""
read -p "Press Enter..."
