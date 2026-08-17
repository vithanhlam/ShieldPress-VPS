#!/bin/bash
# ============================================================
#  Webmail Info & Management
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"
HTPASSWD_FILE="/etc/nginx/.webmail_htpasswd"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Webmail (Roundcube)" "Installed"

MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
MAIL_HOSTNAME="mail.${MAIL_DOMAIN}"

# Get HTTP Auth username
HTAUTH_USER=""
if [ -f "$HTPASSWD_FILE" ]; then
    HTAUTH_USER=$(head -1 "$HTPASSWD_FILE" | cut -d: -f1)
fi

echo ""
echo -e "  ${BOLD}Access URL:${RESET}"
echo -e "  ${GREEN}https://${MAIL_HOSTNAME}${RESET}"
echo ""
echo -e "  ${BOLD}Step 1 - HTTP Basic Auth (browser popup):${RESET}"
echo -e "  Username : ${CYAN}${HTAUTH_USER:-not set}${RESET}"
echo -e "  Password : ${DIM}(set during installation)${RESET}"
echo ""
echo -e "  ${BOLD}Step 2 - Roundcube Login:${RESET}"
echo -e "  Username : ${CYAN}your-email@${MAIL_DOMAIN}${RESET}"
echo -e "  Password : ${DIM}(email account password)${RESET}"
echo ""

# SSL status
CERT_PATH="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
if [ -f "$CERT_PATH" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
    echo -e "  ${BOLD}SSL:${RESET} ${GREEN}Let's Encrypt (expires: ${EXPIRY})${RESET}"
else
    echo -e "  ${BOLD}SSL:${RESET} ${YELLOW}Not configured${RESET}"
fi

echo ""
sp_hr
echo ""
WEBMAIL_DIR="/var/www/webmail"
RC_CONFIG="$WEBMAIL_DIR/config/config.inc.php"

# Show session info
if [ -f "$RC_CONFIG" ]; then
    IP_CHECK=$(grep "ip_check" "$RC_CONFIG" 2>/dev/null | grep -v "^//" | head -1)
    SESSION_LIFE=$(grep "session_lifetime" "$RC_CONFIG" 2>/dev/null | grep -v "^//" | head -1)
    if echo "$IP_CHECK" | grep -q "true"; then
        echo -e "  ${BOLD}Session:${RESET} ${RED}ip_check = true (causes logout on IP change)${RESET}"
        echo -e "  ${DIM}  → Select [3] to fix this${RESET}"
    else
        echo -e "  ${BOLD}Session:${RESET} ${GREEN}OK${RESET}"
    fi
    echo ""
fi

echo -e "  ${GREEN}[1]${RESET} Change HTTP Auth password"
echo -e "  ${CYAN}[3]${RESET} Fix session logout (ip_check + session lifetime)"
echo -e "  ${YELLOW}[4]${RESET} Reinstall Webmail"
echo -e "  ${RED}[2]${RESET} Uninstall Webmail"
echo -e "  ${WHITE}[0]${RESET} Back"
echo ""

read -p "  Select: " CHOICE

case $CHOICE in
    1)
        echo ""
        read -p "  New username: " NEW_USER
        if [ -z "$NEW_USER" ]; then
            fail "Username cannot be empty"
            read -p "Press Enter..."
            exit 1
        fi
        read -sp "  New password (min 6 chars): " NEW_PASS
        echo ""
        if [ ${#NEW_PASS} -lt 6 ]; then
            fail "Password too short"
            read -p "Press Enter..."
            exit 1
        fi

        echo "${NEW_USER}:$(openssl passwd -apr1 "$NEW_PASS")" > "$HTPASSWD_FILE"
        chown root:nginx "$HTPASSWD_FILE"
        chmod 640 "$HTPASSWD_FILE"
        systemctl reload nginx 2>/dev/null

        ok "HTTP Auth updated (user: ${NEW_USER})"
        read -p "Press Enter..."
        ;;
    2)
        bash $MODULE_DIR/uninstall-webmail.sh
        ;;
    3)
        echo ""
        if [ ! -f "$RC_CONFIG" ]; then
            fail "Roundcube config not found at $RC_CONFIG"
            read -p "Press Enter..."
            exit 1
        fi

        info "Fixing webmail session settings..."

        # Fix ip_check
        if grep -q "ip_check" "$RC_CONFIG"; then
            sed -i "s/\\\$config\['ip_check'\] = true/\$config['ip_check'] = false/" "$RC_CONFIG"
        else
            sed -i "/session_lifetime/a \\\$config['ip_check'] = false;" "$RC_CONFIG"
        fi

        # Fix session_lifetime
        if grep -q "session_lifetime" "$RC_CONFIG"; then
            sed -i "s/\\\$config\['session_lifetime'\] = [0-9]*/\$config['session_lifetime'] = 60/" "$RC_CONFIG"
        fi

        ok "ip_check = false (no logout on IP change)"
        ok "session_lifetime = 60 minutes"
        echo ""
        echo -e "  ${DIM}Refresh the Webmail page to apply changes${RESET}"
        read -p "Press Enter..."
        ;;
    4)
        echo ""
        warn "This will reinstall Roundcube webmail (current config will be reset)."
        read -p "Continue? (y/n): " REINSTALL_CONFIRM
        [[ ! "$REINSTALL_CONFIRM" =~ ^[Yy]$ ]] && break
        bash $MODULE_DIR/uninstall-webmail.sh
        bash $MODULE_DIR/install-webmail.sh
        break
        ;;
    0|*)
        exit 0
        ;;
esac
