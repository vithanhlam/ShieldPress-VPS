#!/bin/bash
# ============================================================
#  Email Client Setup Guide
#  - Outlook, Thunderbird, Gmail App, iPhone, Android
#  - IMAP/SMTP connection settings
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Email Client Setup" "Connect Outlook, Phone & Apps"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

# Get config
MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')

if [ -z "$MAIL_DOMAIN" ]; then
    read -p "Enter your mail domain: " MAIL_DOMAIN
fi

get_server_ip

MAIL_HOST="mail.${MAIL_DOMAIN}"

echo ""
echo -e "  ${BOLD}${WHITE}Server Information${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Mail Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "  Server IP    : ${GREEN}${SERVER_IP:-YOUR_SERVER_IP}${RESET}"
echo ""
echo -e "  ${BOLD}${CYAN}Incoming Mail (IMAP)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Server   : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "  Port     : ${GREEN}993${RESET}"
echo -e "  Security : ${GREEN}SSL/TLS${RESET}"
echo ""
echo -e "  ${BOLD}${CYAN}Outgoing Mail (SMTP)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Server   : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "  Port     : ${GREEN}587${RESET}"
echo -e "  Security : ${GREEN}STARTTLS${RESET}"
echo ""
echo -e "  ${BOLD}${CYAN}Login Credentials${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  Username : ${GREEN}your-full-email@${MAIL_DOMAIN}${RESET}"
echo -e "  Password : ${GREEN}(password set when creating account)${RESET}"
echo ""

sp_hr
echo ""
echo -e "  ${BOLD}${WHITE}Setup Guides${RESET}"
echo ""

# ============================
# Outlook (Desktop & Web)
# ============================
echo -e "  ${BOLD}${BLUE}1. Microsoft Outlook (Desktop / Microsoft 365)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Open Outlook > ${BOLD}File${RESET} > ${BOLD}Add Account${RESET}"
echo -e "  2) Enter your email: ${GREEN}you@${MAIL_DOMAIN}${RESET}"
echo -e "  3) Select ${BOLD}Advanced options${RESET} > ${BOLD}Let me set up my account manually${RESET}"
echo -e "  4) Choose ${BOLD}IMAP${RESET}"
echo -e "  5) Incoming mail:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}993${RESET}"
echo -e "     - Encrypt : ${GREEN}SSL/TLS${RESET}"
echo -e "  6) Outgoing mail:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}587${RESET}"
echo -e "     - Encrypt : ${GREEN}STARTTLS${RESET}"
echo -e "  7) Enter password > ${BOLD}Connect${RESET}"
echo ""

# ============================
# Thunderbird
# ============================
echo -e "  ${BOLD}${BLUE}2. Mozilla Thunderbird${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Open Thunderbird > ${BOLD}Account Settings${RESET} > ${BOLD}Account Actions${RESET} > ${BOLD}Add Mail Account${RESET}"
echo -e "  2) Enter name, email ${GREEN}you@${MAIL_DOMAIN}${RESET}, and password"
echo -e "  3) Click ${BOLD}Configure manually${RESET}"
echo -e "  4) Set:"
echo -e "     IMAP : ${GREEN}${MAIL_HOST}${RESET}  Port ${GREEN}993${RESET}  SSL/TLS  Normal password"
echo -e "     SMTP : ${GREEN}${MAIL_HOST}${RESET}  Port ${GREEN}587${RESET}  STARTTLS  Normal password"
echo -e "  5) Username: ${GREEN}you@${MAIL_DOMAIN}${RESET} (full email)"
echo -e "  6) Click ${BOLD}Done${RESET}"
echo ""

# ============================
# Gmail App (Android)
# ============================
echo -e "  ${BOLD}${BLUE}3. Gmail App (Android)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Open Gmail > tap avatar (top right) > ${BOLD}Add another account${RESET}"
echo -e "  2) Choose ${BOLD}Other${RESET}"
echo -e "  3) Enter: ${GREEN}you@${MAIL_DOMAIN}${RESET}"
echo -e "  4) Select ${BOLD}Personal (IMAP)${RESET}"
echo -e "  5) Password: enter your email password"
echo -e "  6) Incoming server:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}993${RESET}"
echo -e "     - Security: ${GREEN}SSL/TLS${RESET}"
echo -e "  7) Outgoing server:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}587${RESET}"
echo -e "     - Security: ${GREEN}STARTTLS${RESET}"
echo -e "  8) Tap ${BOLD}Next${RESET} > Done"
echo ""

# ============================
# iPhone / iPad
# ============================
echo -e "  ${BOLD}${BLUE}4. iPhone / iPad (iOS Mail)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Go to ${BOLD}Settings${RESET} > ${BOLD}Mail${RESET} > ${BOLD}Accounts${RESET} > ${BOLD}Add Account${RESET}"
echo -e "  2) Tap ${BOLD}Other${RESET} > ${BOLD}Add Mail Account${RESET}"
echo -e "  3) Enter:"
echo -e "     - Name    : Your display name"
echo -e "     - Email   : ${GREEN}you@${MAIL_DOMAIN}${RESET}"
echo -e "     - Password: your email password"
echo -e "  4) Tap ${BOLD}Next${RESET} > choose ${BOLD}IMAP${RESET}"
echo -e "  5) Incoming mail server:"
echo -e "     - Host name : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - User name : ${GREEN}you@${MAIL_DOMAIN}${RESET}"
echo -e "     - Password  : your password"
echo -e "  6) Outgoing mail server:"
echo -e "     - Host name : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - User name : ${GREEN}you@${MAIL_DOMAIN}${RESET}"
echo -e "     - Password  : your password"
echo -e "  7) Tap ${BOLD}Save${RESET}"
echo -e "  ${DIM}  iOS auto-detects SSL on port 993 and STARTTLS on port 587${RESET}"
echo ""

# ============================
# Samsung Email / Android Mail
# ============================
echo -e "  ${BOLD}${BLUE}5. Samsung Email / Android Default Mail${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Open Email app > ${BOLD}Add account${RESET} > ${BOLD}Other${RESET}"
echo -e "  2) Enter: ${GREEN}you@${MAIL_DOMAIN}${RESET} and password"
echo -e "  3) Tap ${BOLD}Manual setup${RESET} > choose ${BOLD}IMAP account${RESET}"
echo -e "  4) Incoming server:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}993${RESET}"
echo -e "     - Security: ${GREEN}SSL/TLS${RESET}"
echo -e "  5) Outgoing server:"
echo -e "     - Server  : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "     - Port    : ${GREEN}587${RESET}"
echo -e "     - Security: ${GREEN}STARTTLS${RESET}"
echo -e "  6) Tap ${BOLD}Sign in${RESET}"
echo ""

# ============================
# macOS Mail
# ============================
echo -e "  ${BOLD}${BLUE}6. macOS Mail${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  1) Open Mail > ${BOLD}Mail${RESET} menu > ${BOLD}Add Account${RESET}"
echo -e "  2) Choose ${BOLD}Other Mail Account${RESET} > ${BOLD}Continue${RESET}"
echo -e "  3) Enter name, email ${GREEN}you@${MAIL_DOMAIN}${RESET}, password"
echo -e "  4) Click ${BOLD}Sign In${RESET} — if auto-detect fails, enter manually:"
echo -e "     IMAP : ${GREEN}${MAIL_HOST}${RESET}  (port 993, SSL/TLS)"
echo -e "     SMTP : ${GREEN}${MAIL_HOST}${RESET}  (port 587, STARTTLS)"
echo -e "  5) Click ${BOLD}Sign In${RESET}"
echo ""

# ============================
# WordPress SMTP
# ============================
echo -e "  ${BOLD}${BLUE}7. WordPress (WP Mail SMTP / FluentSMTP / Post SMTP)${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  ${BOLD}Plugin recommended:${RESET} WP Mail SMTP or FluentSMTP"
echo ""
echo -e "  ${BOLD}SMTP Settings:${RESET}"
echo -e "  SMTP Host     : ${GREEN}${MAIL_HOST}${RESET}"
echo -e "  SMTP Port     : ${GREEN}587${RESET}"
echo -e "  Encryption    : ${GREEN}TLS${RESET}  ${RED}(NOT SSL — select TLS/STARTTLS)${RESET}"
echo -e "  Authentication: ${GREEN}Yes${RESET}"
echo -e "  Username      : ${GREEN}your-full-email@${MAIL_DOMAIN}${RESET}  ${RED}(full email, NOT just the username)${RESET}"
echo -e "  Password      : ${GREEN}(email account password)${RESET}"
echo ""
echo -e "  ${BOLD}WP Mail SMTP — steps:${RESET}"
echo -e "  1) WP Admin > ${BOLD}WP Mail SMTP${RESET} > ${BOLD}Settings${RESET}"
echo -e "  2) Select mailer: ${BOLD}Other SMTP${RESET}"
echo -e "  3) SMTP Host: ${GREEN}${MAIL_HOST}${RESET}"
echo -e "  4) Encryption: select ${GREEN}TLS${RESET} (port auto-fills to 587)"
echo -e "  5) Authentication: ${GREEN}On${RESET}"
echo -e "  6) Username: ${GREEN}full-email@${MAIL_DOMAIN}${RESET}"
echo -e "  7) Password: email account password"
echo -e "  8) Click ${BOLD}Save Settings${RESET} then ${BOLD}Send Test Email${RESET}"
echo ""
echo -e "  ${BOLD}${YELLOW}Common mistakes:${RESET}"
echo -e "  ${RED}✗ Wrong:${RESET}   Encryption = SSL, Port = 465"
echo -e "  ${GREEN}✓ Correct:${RESET} Encryption = TLS, Port = 587"
echo -e "  ${RED}✗ Wrong:${RESET}   Username = support"
echo -e "  ${GREEN}✓ Correct:${RESET} Username = support@${MAIL_DOMAIN}"
echo ""
echo -e "  ${DIM}If SSL certificate error: disable 'Verify SSL' in the plugin${RESET}"
echo -e "  ${DIM}(or install Let's Encrypt for mail.${MAIL_DOMAIN} via ShieldPress SSL)${RESET}"
echo ""

sp_hr
echo ""
echo -e "  ${BOLD}${YELLOW}Troubleshooting${RESET}"
echo -e "  ──────────────────────────────────────────────────"
echo -e "  ${RED}Cannot connect?${RESET}"
echo -e "    - Make sure DNS A record for ${CYAN}mail.${MAIL_DOMAIN}${RESET} points to ${CYAN}${SERVER_IP:-YOUR_IP}${RESET}"
echo -e "    - Check firewall ports: ${CYAN}993${RESET} (IMAP) and ${CYAN}587${RESET} (SMTP) must be open"
echo -e "    - Run: ${DIM}shieldpress${RESET} > ${DIM}Email Server${RESET} > ${DIM}Email Server Status${RESET}"
echo ""
echo -e "  ${RED}Using Cloudflare? (most common cause of SMTP failure)${RESET}"
echo -e "    - Go to Cloudflare DNS and find the ${CYAN}mail${RESET} A record"
echo -e "    - The proxy status MUST be ${BOLD}DNS only (grey cloud)${RESET}"
echo -e "    - If it shows an ${BOLD}orange cloud${RESET}, click it to turn it grey"
echo -e "    - Cloudflare proxy only passes HTTP/HTTPS — it blocks ports 25, 587, 993"
echo -e "    - With orange cloud ON: no email client or WordPress SMTP can connect"
echo ""
echo -e "  ${RED}Certificate warning?${RESET}"
echo -e "    - Install SSL for ${CYAN}mail.${MAIL_DOMAIN}${RESET} via ShieldPress SSL Manager"
echo -e "    - Or accept the self-signed certificate on first connection"
echo ""
echo -e "  ${RED}Authentication failed?${RESET}"
echo -e "    - Username must be full email: ${CYAN}you@${MAIL_DOMAIN}${RESET} (not just \"you\")"
echo -e "    - Reset password: ${DIM}shieldpress${RESET} > ${DIM}Email Server${RESET} > ${DIM}Change Password${RESET}"
echo ""

read -p "Press Enter..."
