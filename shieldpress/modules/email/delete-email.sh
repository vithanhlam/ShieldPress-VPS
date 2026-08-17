#!/bin/bash
# ============================================================
#  Delete Email Account
# ============================================================


BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Delete Email Account" "Remove mailbox"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

# Select domain
if ! select_mail_domain; then
    read -p "Press Enter..."
    exit 1
fi

DOMAIN="$SELECTED_DOMAIN"

# List accounts for domain
echo ""
echo "Accounts for $DOMAIN:"
echo "--------------------------------"

ACCOUNTS=()
i=1
for u in "$MAIL_DIR/$DOMAIN"/*/; do
    [ -d "$u" ] || continue
    UNAME=$(basename "$u")
    # Get mailbox size
    SIZE=$(du -sh "$u" 2>/dev/null | awk '{print $1}')
    printf "  %d) %s@%s  [%s]\n" "$i" "$UNAME" "$DOMAIN" "$SIZE"
    ACCOUNTS[$i]="$UNAME"
    ((i++))
done

if [ $i -eq 1 ]; then
    info "No accounts found for $DOMAIN"
    read -p "Press Enter..."
    exit 0
fi

echo "--------------------------------"
read -p "Select account to delete: " CHOICE

USERNAME="${ACCOUNTS[$CHOICE]}"
if [ -z "$USERNAME" ]; then
    fail "Invalid selection"
    read -p "Press Enter..."
    exit 1
fi

EMAIL="${USERNAME}@${DOMAIN}"

echo ""
warn "This will permanently delete: $EMAIL"
warn "All emails in the mailbox will be lost!"
read -p "Type 'DELETE' to confirm: " CONFIRM

if [ "$CONFIRM" != "DELETE" ]; then
    info "Cancelled"
    read -p "Press Enter..."
    exit 0
fi

# Remove from Dovecot users
sed -i "/^${EMAIL}:/d" /etc/dovecot/users

# Remove from Postfix virtual mailbox
sed -i "/^${EMAIL}/d" /etc/postfix/virtual_mailbox
postmap /etc/postfix/virtual_mailbox

# Remove mailbox directory
rm -rf "$MAIL_DIR/$DOMAIN/$USERNAME"

# If no more accounts for domain, optionally remove domain
REMAINING=$(find "$MAIL_DIR/$DOMAIN" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
    echo ""
    read -p "No more accounts for $DOMAIN. Remove domain too? (y/n): " RM_DOMAIN
    if [[ "$RM_DOMAIN" =~ ^[Yy]$ ]]; then
        sed -i "/^${DOMAIN}$/d" /etc/postfix/virtual_domains
        rmdir "$MAIL_DIR/$DOMAIN" 2>/dev/null || true
        ok "Domain $DOMAIN removed from mail server"
    fi
fi

# Reload services
systemctl reload postfix 2>/dev/null
systemctl reload dovecot 2>/dev/null

log "Email account deleted: $EMAIL"
ok "Email account deleted: $EMAIL"

echo ""
read -p "Press Enter..."
