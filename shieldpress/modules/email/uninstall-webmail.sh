#!/bin/bash
# ============================================================
#  Uninstall Roundcube Webmail
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Uninstall Webmail" "Remove Roundcube"

if [ ! -f "$ETC_DIR/.webmail_installed" ]; then
    fail "Webmail is not installed"
    read -p "Press Enter..."
    exit 1
fi

echo ""
warn "This will remove Roundcube webmail and its Nginx config."
echo ""
read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# Remove Nginx vhost and htpasswd
rm -f /etc/nginx/conf.d/webmail.conf
rm -f /etc/nginx/.webmail_htpasswd
nginx -t 2>/dev/null && systemctl reload nginx

# Remove Roundcube files
rm -rf /var/www/webmail

# Remove marker
rm -f "$ETC_DIR/.webmail_installed"

# Remove from config
sed -i '/^WEBMAIL=/d' "$EMAIL_CONFIG" 2>/dev/null || true

log "Webmail uninstalled"
ok "Webmail removed"

echo ""
read -p "Press Enter..."
