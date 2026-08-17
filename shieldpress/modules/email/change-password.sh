#!/bin/bash
# ============================================================
#  Change Email Password
# ============================================================


BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Change Password" "Update email password"

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

# List accounts
echo ""
echo "Accounts for $DOMAIN:"
echo "--------------------------------"

ACCOUNTS=()
i=1
for u in "$MAIL_DIR/$DOMAIN"/*/; do
    [ -d "$u" ] || continue
    UNAME=$(basename "$u")
    printf "  %d) %s@%s\n" "$i" "$UNAME" "$DOMAIN"
    ACCOUNTS[$i]="$UNAME"
    ((i++))
done

if [ $i -eq 1 ]; then
    info "No accounts found"
    read -p "Press Enter..."
    exit 0
fi

echo "--------------------------------"
read -p "Select account: " CHOICE

USERNAME="${ACCOUNTS[$CHOICE]}"
if [ -z "$USERNAME" ]; then
    fail "Invalid selection"
    read -p "Press Enter..."
    exit 1
fi

EMAIL="${USERNAME}@${DOMAIN}"
echo ""
info "Changing password for: $EMAIL"

# New password
while true; do
    read -sp "New password (min 8 chars): " PASS
    echo ""
    if [ ${#PASS} -ge 8 ]; then
        read -sp "Confirm new password: " PASS2
        echo ""
        if [ "$PASS" = "$PASS2" ]; then
            break
        fi
        fail "Passwords do not match"
    else
        fail "Password too short"
    fi
done

# Update password in Dovecot users file
HASHED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASS" 2>/dev/null)
if [ -z "$HASHED_PASS" ]; then
    HASHED_PASS="{SHA512-CRYPT}$(openssl passwd -6 "$PASS" 2>/dev/null)"
fi

# Remove old entry and add new
sed -i "/^${EMAIL}:/d" /etc/dovecot/users
echo "${EMAIL}:${HASHED_PASS}" >> /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# Reload Dovecot
systemctl reload dovecot 2>/dev/null

log "Password changed for: $EMAIL"
ok "Password changed for: $EMAIL"

echo ""
read -p "Press Enter..."
