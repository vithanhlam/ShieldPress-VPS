#!/bin/bash
# ============================================================
#  Install / Renew SSL Certificate for Mail Server
#  Applies Let's Encrypt cert to Postfix + Dovecot
# ============================================================

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"
source "$BASE_DIR/modules/ssl/ssl-renewal.sh"

clear
sp_header "Mail SSL" "Let's Encrypt for mail server"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')

if [ -z "$MAIL_DOMAIN" ]; then
    fail "Mail domain not found in config"
    read -p "Press Enter..."
    exit 1
fi

MAIL_HOSTNAME="mail.${MAIL_DOMAIN}"
CERT_DIR="/etc/letsencrypt/live/${MAIL_HOSTNAME}"

get_server_ip

echo ""
info "Mail hostname : ${MAIL_HOSTNAME}"
info "Server IP     : ${SERVER_IP}"
echo ""

# Show current SSL status
if [ -f "$CERT_DIR/fullchain.pem" ]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    if openssl x509 -checkend 86400 -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null; then
        ok "Current SSL certificate valid (expires: ${EXPIRY})"
    else
        warn "SSL certificate EXPIRED or expires within 24h (${EXPIRY})"
    fi
    info "The existing certificate will be renewed when due."
else
    warn "No SSL certificate found for ${MAIL_HOSTNAME}"
fi

# Check DNS
echo ""
info "Checking DNS for ${MAIL_HOSTNAME}..."
A_RECORD=$(dig +short A "${MAIL_HOSTNAME}" 2>/dev/null | tail -1)

if [ -z "$A_RECORD" ]; then
    fail "DNS lookup failed - ${MAIL_HOSTNAME} has no A record"
    echo ""
    warn "Add this DNS record first:"
    echo -e "  ${CYAN}A${RESET}  mail.${MAIL_DOMAIN}  →  ${SERVER_IP}"
    read -p "Press Enter..."
    exit 1
fi

if [ "$A_RECORD" != "$SERVER_IP" ]; then
    fail "${MAIL_HOSTNAME} → ${A_RECORD} (expected ${SERVER_IP})"
    warn "Update your DNS A record to point to this server"
    read -p "Press Enter..."
    exit 1
fi

ok "DNS OK: ${MAIL_HOSTNAME} → ${A_RECORD}"

echo ""
read -p "Install/renew SSL for ${MAIL_HOSTNAME}? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

echo ""
# Use Nginx for HTTP-01 without stopping websites. An existing standalone
# lineage is tested and migrated before the next scheduled renewal.
if ! certbot plugins --text 2>/dev/null | grep nginx >/dev/null; then
    dnf install -y certbot python3-certbot-nginx || exit 1
fi
ssl_install_mail "$MAIL_HOSTNAME" "postmaster@$MAIL_DOMAIN" 2>&1 | tee -a "$LOG_FILE"
CERTBOT_EXIT=${PIPESTATUS[0]}

echo ""

if [ $CERTBOT_EXIT -eq 0 ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    # Apply and reload only after Certbot and auto-renew setup succeeded.
    if ! (
        postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem" &&
        postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem" &&
        sed -i "s|ssl_cert = .*|ssl_cert = <$CERT_DIR/fullchain.pem|" /etc/dovecot/dovecot.conf &&
        sed -i "s|ssl_key = .*|ssl_key = <$CERT_DIR/privkey.pem|" /etc/dovecot/dovecot.conf &&
        systemctl reload postfix && systemctl reload dovecot
    ); then
        fail "Certificate obtained, but mail services could not apply it"
        exit 1
    fi

    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    ok "SSL installed and applied to Postfix + Dovecot"
    echo ""
    echo -e "  Certificate : ${GREEN}${MAIL_HOSTNAME}${RESET}"
    echo -e "  Expires     : ${CYAN}${EXPIRY}${RESET}"

    log "SSL installed for ${MAIL_HOSTNAME} (expires: ${EXPIRY})"
else
    fail "SSL installation failed (certbot exit: $CERTBOT_EXIT)"
    warn "Check logs: journalctl -u certbot-renew.service -n 50"
    exit 1
fi

echo ""
read -p "Press Enter..."
