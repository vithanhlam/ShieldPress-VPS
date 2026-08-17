#!/bin/bash
# ============================================================
#  Uninstall Email Server
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Uninstall Email Server" "Remove mail services"

if ! mail_installed; then
    fail "Email server is not installed"
    read -p "Press Enter..."
    exit 1
fi

echo ""
warn "This will stop and remove all email services:"
echo ""
echo -e "  ${DIM}├── Postfix (SMTP)${RESET}"
echo -e "  ${DIM}├── Dovecot (IMAP)${RESET}"
echo -e "  ${DIM}├── Rspamd (spam filter)${RESET}"
echo -e "  ${DIM}├── OpenDKIM (signing)${RESET}"
echo -e "  ${DIM}└── Fail2Ban mail jails${RESET}"
echo ""

# Count accounts
TOTAL=0
if [ -d "$MAIL_DIR" ]; then
    for d in "$MAIL_DIR"/*/; do
        [ -d "$d" ] || continue
        for u in "$d"/*/; do
            [ -d "$u" ] || continue
            TOTAL=$((TOTAL + 1))
        done
    done
fi

if [ $TOTAL -gt 0 ]; then
    warn "$TOTAL email account(s) and all emails will be deleted!"
fi

echo ""
read -p "Type 'UNINSTALL' to confirm: " CONFIRM

if [ "$CONFIRM" != "UNINSTALL" ]; then
    info "Cancelled"
    read -p "Press Enter..."
    exit 0
fi

echo ""
info "Stopping services..."

# Stop and disable services
systemctl stop postfix dovecot rspamd opendkim 2>/dev/null || true
systemctl disable postfix dovecot rspamd opendkim 2>/dev/null || true

ok "Services stopped"

# Ask about keeping or removing data
echo ""
read -p "Delete all mailbox data? (y/n): " DEL_DATA

if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
    rm -rf "$MAIL_DIR"
    ok "Mailbox data deleted"
else
    info "Mailbox data preserved at $MAIL_DIR"
fi

# Remove configs
rm -f /etc/fail2ban/jail.d/mail.conf
rm -f /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
rm -f /etc/postfix/virtual_domains
rm -f /etc/postfix/virtual_mailbox /etc/postfix/virtual_mailbox.db
rm -f /etc/postfix/virtual_alias /etc/postfix/virtual_alias.db
rm -f /etc/dovecot/users

# Restore conf.d if it was disabled
if [ -d /etc/dovecot/conf.d.disabled ]; then
    mv /etc/dovecot/conf.d.disabled /etc/dovecot/conf.d 2>/dev/null || true
fi

# Remove packages (optional)
echo ""
read -p "Remove mail packages (postfix, dovecot, rspamd)? (y/n): " DEL_PKG

if [[ "$DEL_PKG" =~ ^[Yy]$ ]]; then
    dnf remove -y postfix dovecot dovecot-pigeonhole rspamd opendkim opendkim-tools 2>/dev/null || true
    ok "Packages removed"
else
    info "Packages kept (services disabled)"
fi

# Close firewall ports
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --remove-service=smtp 2>/dev/null || true
    firewall-cmd --permanent --remove-service=smtps 2>/dev/null || true
    firewall-cmd --permanent --remove-port=587/tcp 2>/dev/null || true
    firewall-cmd --permanent --remove-service=imap 2>/dev/null || true
    firewall-cmd --permanent --remove-service=imaps 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    ok "Firewall ports closed"
fi

# Restart fail2ban
systemctl restart fail2ban 2>/dev/null || true

# Remove webmail if installed
if [ -f "$ETC_DIR/.webmail_installed" ]; then
    rm -rf /var/www/webmail
    rm -f /etc/nginx/conf.d/webmail.conf
    rm -f /etc/nginx/.webmail_htpasswd
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    rm -f "$ETC_DIR/.webmail_installed"
    ok "Webmail removed"
fi

# Remove install marker
rm -f "$ETC_DIR/.mail_installed"
rm -f "$EMAIL_CONFIG"

# Remove exported DNS file
rm -f /home/dns-records-*.txt 2>/dev/null || true

log "Email server uninstalled"
ok "Email server uninstalled successfully"

echo ""
read -p "Press Enter..."
