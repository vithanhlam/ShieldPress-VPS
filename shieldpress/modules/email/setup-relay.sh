#!/bin/bash
# ============================================================
#  Setup / Change SMTP Relay
#  Priority: Brevo (free 300/day) → Amazon SES
# ============================================================


BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "SMTP Relay Setup" "Configure outbound email"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

# Show current relay
get_relay_info
echo ""
echo -e "  Current relay: ${BOLD}${RELAY_STATUS}${RESET}"
echo ""
sp_hr
echo ""
echo -e "  ${GREEN}[1]${RESET} Brevo (free 300 emails/day) ${DIM}← Recommended${RESET}"
echo -e "  ${BLUE}[2]${RESET} Amazon SES"
echo -e "  ${RED}[3]${RESET} Remove relay (send directly)"
echo -e "  ${WHITE}[0]${RESET} Cancel"
echo ""

read -p "  Select: " CHOICE

case $CHOICE in
    1)
        echo ""
        info "Brevo SMTP Setup"
        echo -e "  ${DIM}Get your SMTP key at: https://app.brevo.com/settings/keys/smtp${RESET}"
        echo ""

        # Get sender email
        echo -e "  ${DIM}Go to: Brevo → Settings → SMTP & API → SMTP${RESET}"
        echo -e "  ${DIM}Login = your Brevo login email${RESET}"
        echo -e "  ${DIM}SMTP Key = the generated SMTP key (not API key)${RESET}"
        echo ""
        read -p "  Brevo Login (email): " BREVO_LOGIN
        read -p "  Brevo SMTP Key: " BREVO_KEY
        if [ -z "$BREVO_KEY" ] || [ -z "$BREVO_LOGIN" ]; then
            fail "Both login and SMTP key are required"
            read -p "Press Enter..."
            exit 1
        fi

        # Configure Postfix relay
        postconf -e "relayhost = [smtp-relay.brevo.com]:587"
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_tls_security_level = encrypt"

        echo "[smtp-relay.brevo.com]:587 ${BREVO_LOGIN}:${BREVO_KEY}" > /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd

        # Update config
        sed -i "s/^RELAY_TYPE=.*/RELAY_TYPE=brevo/" "$EMAIL_CONFIG" 2>/dev/null || \
            echo "RELAY_TYPE=brevo" >> "$EMAIL_CONFIG"

        systemctl restart postfix

        ok "Brevo relay configured"
        echo ""
        echo -e "  ${DIM}Free tier: 300 emails/day${RESET}"
        echo -e "  ${DIM}Make sure to verify sender domain in Brevo dashboard${RESET}"
        ;;

    2)
        echo ""
        info "Amazon SES Setup"
        echo -e "  ${DIM}Go to: SES Console → SMTP Settings → Create SMTP Credentials${RESET}"
        echo -e "  ${DIM}SMTP Username and Password are separate from IAM credentials${RESET}"
        echo ""

        read -p "  SES SMTP Username: " SES_KEY
        read -sp "  SES SMTP Password: " SES_SECRET
        echo ""
        read -p "  SES Region (e.g. us-east-1): " SES_REGION
        [ -z "$SES_REGION" ] && SES_REGION="us-east-1"

        if [ -z "$SES_KEY" ] || [ -z "$SES_SECRET" ]; then
            fail "Both SMTP Username and Password are required"
            read -p "Press Enter..."
            exit 1
        fi

        # Configure Postfix relay
        postconf -e "relayhost = [email-smtp.${SES_REGION}.amazonaws.com]:587"
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_tls_security_level = encrypt"

        echo "[email-smtp.${SES_REGION}.amazonaws.com]:587 ${SES_KEY}:${SES_SECRET}" > /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd

        # Update config
        sed -i "s/^RELAY_TYPE=.*/RELAY_TYPE=ses/" "$EMAIL_CONFIG" 2>/dev/null || \
            echo "RELAY_TYPE=ses" >> "$EMAIL_CONFIG"
        sed -i "s/^RELAY_REGION=.*/RELAY_REGION=${SES_REGION}/" "$EMAIL_CONFIG" 2>/dev/null || \
            echo "RELAY_REGION=${SES_REGION}" >> "$EMAIL_CONFIG"

        systemctl restart postfix

        ok "Amazon SES relay configured (Region: ${SES_REGION})"
        echo ""
        echo -e "  ${DIM}Make sure to verify sender domain/email in SES console${RESET}"
        echo -e "  ${DIM}If in sandbox mode, you can only send to verified addresses${RESET}"
        ;;

    3)
        echo ""
        warn "Removing relay - emails will be sent directly from this server"
        warn "Your server IP may get blacklisted if not properly configured"
        read -p "Continue? (y/n): " CONFIRM
        [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

        # Remove relay config
        postconf -e "relayhost ="
        postconf -e "smtp_sasl_auth_enable = no"

        rm -f /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db

        sed -i "s/^RELAY_TYPE=.*/RELAY_TYPE=none/" "$EMAIL_CONFIG" 2>/dev/null || true

        systemctl restart postfix

        ok "Relay removed - sending directly"
        ;;

    0|*)
        exit 0
        ;;
esac

echo ""
read -p "Press Enter..."
