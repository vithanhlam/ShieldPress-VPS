#!/bin/bash
# ============================================================
#  Install / Renew SSL Certificate for Mail Server
#  Applies Let's Encrypt cert to Postfix + Dovecot
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

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
    echo ""
    read -p "Force renew? (y/N): " FORCE_INPUT
    FORCE_INPUT="${FORCE_INPUT:-N}"
    [[ "$FORCE_INPUT" =~ ^[Yy]$ ]] && FORCE_OPTS="--force-renewal" || FORCE_OPTS=""
else
    warn "No SSL certificate found for ${MAIL_HOSTNAME}"
    FORCE_OPTS=""
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
read -p "Install/renew SSL for ${MAIL_HOSTNAME}? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

echo ""
info "Stopping Nginx temporarily to free port 80..."

NGINX_WAS_RUNNING=false
if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_WAS_RUNNING=true
    systemctl stop nginx 2>/dev/null
fi

certbot certonly --standalone \
    --agree-tos --non-interactive \
    $FORCE_OPTS \
    -d "${MAIL_HOSTNAME}" \
    --email "postmaster@${MAIL_DOMAIN}" \
    2>&1 | tee -a "$LOG_FILE"

CERTBOT_EXIT=$?

if $NGINX_WAS_RUNNING; then
    systemctl start nginx 2>/dev/null
fi

echo ""

if [ $CERTBOT_EXIT -eq 0 ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
    # Apply to Postfix
    postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem"
    postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem"

    # Apply to Dovecot
    sed -i "s|ssl_cert = .*|ssl_cert = <$CERT_DIR/fullchain.pem|" /etc/dovecot/dovecot.conf
    sed -i "s|ssl_key = .*|ssl_key = <$CERT_DIR/privkey.pem|" /etc/dovecot/dovecot.conf

    # Restart services to apply cert
    systemctl restart postfix 2>/dev/null
    systemctl restart dovecot 2>/dev/null

    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    ok "SSL installed and applied to Postfix + Dovecot"
    echo ""
    echo -e "  Certificate : ${GREEN}${MAIL_HOSTNAME}${RESET}"
    echo -e "  Expires     : ${CYAN}${EXPIRY}${RESET}"

    log "SSL installed for ${MAIL_HOSTNAME} (expires: ${EXPIRY})"
else
    fail "SSL installation failed (certbot exit: $CERTBOT_EXIT)"
    warn "Check logs: journalctl -xn 50 | grep certbot"
fi

echo ""
read -p "Press Enter..."
