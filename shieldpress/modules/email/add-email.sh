#!/bin/bash
# ============================================================
#  Add Email Account
# ============================================================


BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Add Email Account" "Create new mailbox"

if ! mail_installed; then
    fail "Email server not installed. Run 'Install Email Server' first."
    read -p "Press Enter..."
    exit 1
fi

echo ""

# ── Domain selection ──────────────────────────────────────
VIRTUAL_DOMAINS_FILE="/etc/postfix/virtual_domains"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

# Build domain list from configured virtual_domains + email.conf primary domain
declare -a DOMAIN_LIST=()

# Primary domain from email.conf
PRIMARY_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
[ -n "$PRIMARY_DOMAIN" ] && DOMAIN_LIST+=("$PRIMARY_DOMAIN")

# Additional domains from virtual_domains (skip duplicates)
if [ -f "$VIRTUAL_DOMAINS_FILE" ]; then
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '[:space:]')
        [ -z "$line" ] && continue
        # Skip if already in list
        FOUND=0
        for d in "${DOMAIN_LIST[@]}"; do
            [ "$d" = "$line" ] && FOUND=1 && break
        done
        [ "$FOUND" -eq 0 ] && DOMAIN_LIST+=("$line")
    done < "$VIRTUAL_DOMAINS_FILE"
fi

DOMAIN=""

if [ ${#DOMAIN_LIST[@]} -gt 0 ]; then
    echo -e "  ${BOLD}Select domain:${RESET}"
    echo ""
    i=1
    for d in "${DOMAIN_LIST[@]}"; do
        echo -e "  ${CYAN}[$i]${RESET} $d"
        ((i++))
    done
    echo -e "  ${WHITE}[N]${RESET} Enter a new domain"
    echo ""
    read -p "  Select: " DOMAIN_CHOICE

    if [[ "$DOMAIN_CHOICE" =~ ^[0-9]+$ ]] && [ "$DOMAIN_CHOICE" -ge 1 ] && [ "$DOMAIN_CHOICE" -le "${#DOMAIN_LIST[@]}" ]; then
        DOMAIN="${DOMAIN_LIST[$((DOMAIN_CHOICE - 1))]}"
    elif [[ "$DOMAIN_CHOICE" =~ ^[Nn]$ ]]; then
        read -p "  New domain (e.g. shieldpress.net): " DOMAIN
        if ! validate_domain "$DOMAIN"; then
            fail "Invalid domain format"
            read -p "Press Enter..."
            exit 1
        fi
    else
        fail "Invalid selection"
        read -p "Press Enter..."
        exit 1
    fi
else
    # No domains configured yet — fall back to manual input
    read -p "  Domain (e.g. shieldpress.net): " DOMAIN
    if ! validate_domain "$DOMAIN"; then
        fail "Invalid domain format"
        read -p "Press Enter..."
        exit 1
    fi
fi

echo ""
info "Domain: $DOMAIN"

# Check if domain is configured in Postfix
if ! grep -q "^${DOMAIN}$" /etc/postfix/virtual_domains 2>/dev/null; then
    info "Domain $DOMAIN is new - adding to mail server..."
    echo "$DOMAIN" >> /etc/postfix/virtual_domains

    # Generate DKIM for new domain
    generate_dkim "$DOMAIN"

    # Update OpenDKIM tables
    echo "mail._domainkey.${DOMAIN} ${DOMAIN}:mail:/etc/opendkim/keys/${DOMAIN}/mail.private" >> /etc/opendkim/KeyTable
    echo "*@${DOMAIN} mail._domainkey.${DOMAIN}" >> /etc/opendkim/SigningTable

    # Add to trusted hosts
    if ! grep -q "^${DOMAIN}$" /etc/opendkim/TrustedHosts 2>/dev/null; then
        echo "$DOMAIN" >> /etc/opendkim/TrustedHosts
        echo "*.${DOMAIN}" >> /etc/opendkim/TrustedHosts
    fi

    systemctl restart opendkim 2>/dev/null || true
    ok "Domain $DOMAIN added"
fi

# Username
echo ""
read -p "Username (e.g. info): " USERNAME

if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9._%+-]+$ ]]; then
    fail "Invalid username"
    read -p "Press Enter..."
    exit 1
fi

EMAIL="${USERNAME}@${DOMAIN}"

# Check if exists
if email_exists "$USERNAME" "$DOMAIN"; then
    fail "Email $EMAIL already exists"
    read -p "Press Enter..."
    exit 1
fi

# Password
while true; do
    read -sp "Password (min 8 chars): " PASS
    echo ""
    if [ ${#PASS} -ge 8 ]; then
        read -sp "Confirm password: " PASS2
        echo ""
        if [ "$PASS" = "$PASS2" ]; then
            break
        fi
        fail "Passwords do not match"
    else
        fail "Password too short"
    fi
done

# Create mailbox directory
mkdir -p "$MAIL_DIR/$DOMAIN/$USERNAME/Maildir"/{cur,new,tmp}
chown -R vmail:vmail "$MAIL_DIR/$DOMAIN/$USERNAME"

# Add to Dovecot users file
HASHED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASS" 2>/dev/null)
if [ -z "$HASHED_PASS" ]; then
    HASHED_PASS="{SHA512-CRYPT}$(openssl passwd -6 "$PASS" 2>/dev/null)"
fi
echo "${EMAIL}:${HASHED_PASS}" >> /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# Add to Postfix virtual mailbox
echo "${EMAIL}    ${DOMAIN}/${USERNAME}/" >> /etc/postfix/virtual_mailbox
postmap /etc/postfix/virtual_mailbox

# Reload services
systemctl reload postfix 2>/dev/null
systemctl reload dovecot 2>/dev/null

log "Email account created: $EMAIL"
ok "Email account created: $EMAIL"

echo ""
echo -e "  ${BOLD}Mail Client Settings:${RESET}"
echo -e "  Email    : $EMAIL"
echo -e "  IMAP     : mail.${DOMAIN}  Port 993 (SSL)"
echo -e "  SMTP     : mail.${DOMAIN}  Port 587 (STARTTLS)"
echo -e "  Username : $EMAIL"
echo ""

read -p "Press Enter..."
