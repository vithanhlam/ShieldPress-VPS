#!/bin/bash
# ============================================================
#  Email Server - 1-Click Installer
#  Installs: Postfix + Dovecot + Rspamd + OpenDKIM
#            + Fail2Ban jails + Let's Encrypt for mail
#  Target: AlmaLinux 9/10 (Fedora/RHEL)
# ============================================================

set -e
set -o pipefail

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
MAIL_DIR="/var/mail/vhosts"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

# ============================================================
#  PRE-FLIGHT CHECKS
# ============================================================

clear
sp_header "Email Server Installer" "1-Click Setup"

echo ""
info "Checking system requirements..."
echo ""

# Root check
if [ "$EUID" -ne 0 ]; then
    fail "Must run as root"
    read -p "Press Enter..."
    exit 1
fi

# Check if already installed
if mail_installed; then
    warn "Email server is already installed!"
    echo ""
    read -p "Reinstall? This will overwrite configs (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0
fi

# RAM check
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
if [ "$TOTAL_RAM" -lt 1500 ]; then
    warn "RAM: ${TOTAL_RAM}MB - Recommended minimum is 2GB for mail server"
    read -p "Continue anyway? (y/n): " RAM_CONFIRM
    [[ ! "$RAM_CONFIRM" =~ ^[Yy]$ ]] && exit 0
else
    ok "RAM: ${TOTAL_RAM}MB"
fi

# Internet check
if ! curl -s --connect-timeout 5 https://google.com >/dev/null 2>&1; then
    fail "No internet connection"
    read -p "Press Enter..."
    exit 1
fi
ok "Internet connection"

# ============================================================
#  COLLECT USER INPUT
# ============================================================

echo ""
sp_hr
echo -e "  ${BOLD}Enter your mail server details${RESET}"
sp_hr
echo ""

# Domain
while true; do
    read -p "  Domain (e.g. shieldpress.net): " MAIL_DOMAIN
    if validate_domain "$MAIL_DOMAIN"; then
        break
    fi
    fail "Invalid domain format"
done

# Email account
while true; do
    read -p "  Email username (e.g. support): " MAIL_USER
    if [[ "$MAIL_USER" =~ ^[a-zA-Z0-9._%+-]+$ ]]; then
        break
    fi
    fail "Invalid username (letters, numbers, dots, hyphens only)"
done

MAIL_EMAIL="${MAIL_USER}@${MAIL_DOMAIN}"
info "Email account: $MAIL_EMAIL"

# Password
while true; do
    read -sp "  Password (min 8 chars): " MAIL_PASS
    echo ""
    if [ ${#MAIL_PASS} -ge 8 ]; then
        read -p "  Confirm password? (y/N): " CONFIRM_PASS
        CONFIRM_PASS="${CONFIRM_PASS:-N}"
        if [[ "$CONFIRM_PASS" =~ ^[Yy]$ ]]; then
            read -sp "  Confirm password: " MAIL_PASS2
            echo ""
            if [ "$MAIL_PASS" = "$MAIL_PASS2" ]; then
                break
            fi
            fail "Passwords do not match"
        else
            break
        fi
    else
        fail "Password too short (minimum 8 characters)"
    fi
done

# SMTP Relay
echo ""
sp_hr
echo -e "  ${BOLD}SMTP Relay Configuration${RESET}"
sp_hr
echo ""
echo -e "  ${GREEN}[1]${RESET} Brevo (free 300 emails/day) ${DIM}← Recommended${RESET}"
echo -e "  ${BLUE}[2]${RESET} Amazon SES"
echo -e "  ${YELLOW}[3]${RESET} Skip (configure later)"
echo ""

read -p "  Select relay (1/2/3): " RELAY_CHOICE

RELAY_TYPE="none"
RELAY_KEY=""
RELAY_SECRET=""
RELAY_REGION=""

case $RELAY_CHOICE in
    1)
        RELAY_TYPE="brevo"
        echo -e "  ${DIM}Go to: Brevo → Settings → SMTP & API → SMTP${RESET}"
        echo -e "  ${DIM}Login = your Brevo login email${RESET}"
        echo -e "  ${DIM}SMTP Key = the generated SMTP key (not API key)${RESET}"
        echo ""
        read -p "  Brevo Login (email): " RELAY_LOGIN
        read -p "  Brevo SMTP Key: " RELAY_KEY
        if [ -z "$RELAY_KEY" ] || [ -z "$RELAY_LOGIN" ]; then
            warn "Incomplete credentials - relay will be configured later"
            RELAY_TYPE="none"
        fi
        ;;
    2)
        RELAY_TYPE="ses"
        echo -e "  ${DIM}Go to: SES Console → SMTP Settings → Create SMTP Credentials${RESET}"
        echo -e "  ${DIM}SMTP Username and Password are separate from IAM credentials${RESET}"
        echo ""
        read -p "  SES SMTP Username: " RELAY_KEY
        read -sp "  SES SMTP Password: " RELAY_SECRET
        echo ""
        read -p "  SES Region (e.g. us-east-1): " RELAY_REGION
        [ -z "$RELAY_REGION" ] && RELAY_REGION="us-east-1"
        if [ -z "$RELAY_KEY" ] || [ -z "$RELAY_SECRET" ]; then
            warn "Incomplete SES credentials - relay will be configured later"
            RELAY_TYPE="none"
        fi
        ;;
    *)
        info "Skipping relay setup - you can configure later from Email menu"
        ;;
esac

# Confirm
echo ""
sp_hr
echo -e "  ${BOLD}Installation Summary${RESET}"
sp_hr
echo ""
echo -e "  Domain        : ${GREEN}$MAIL_DOMAIN${RESET}"
echo -e "  Email         : ${GREEN}$MAIL_EMAIL${RESET}"
echo -e "  SMTP Relay    : ${CYAN}${RELAY_TYPE}${RESET}"
echo -e "  Hostname      : ${CYAN}mail.${MAIL_DOMAIN}${RESET}"
echo ""
echo -e "  ${BOLD}Components to install:${RESET}"
echo -e "  ${DIM}├── Postfix (SMTP server)${RESET}"
echo -e "  ${DIM}├── Dovecot (IMAP server)${RESET}"
echo -e "  ${DIM}├── Rspamd (spam filter)${RESET}"
echo -e "  ${DIM}├── OpenDKIM (email signing)${RESET}"
echo -e "  ${DIM}├── Fail2Ban jails (brute-force protection)${RESET}"
echo -e "  ${DIM}└── Let's Encrypt SSL (mail.${MAIL_DOMAIN})${RESET}"
echo ""

read -p "Start installation? (y/n): " START_CONFIRM
[[ ! "$START_CONFIRM" =~ ^[Yy]$ ]] && exit 0

echo ""
log "=== EMAIL INSTALLATION STARTED ==="
log "Domain: $MAIL_DOMAIN | User: $MAIL_USER | Relay: $RELAY_TYPE"

# ============================================================
#  STEP 1: Install packages
# ============================================================

info "Step 1/7 - Installing packages..."

dnf install -y \
    postfix \
    dovecot \
    dovecot-pigeonhole \
    opendkim \
    opendkim-tools \
    certbot \
    cyrus-sasl cyrus-sasl-plain \
    2>&1 | tee -a "$LOG_FILE"

# Rspamd repo + install
if ! command -v rspamd &>/dev/null; then
    if [ ! -f /etc/yum.repos.d/rspamd.repo ]; then
        curl -s https://rspamd.com/rpm-stable/centos-9/rspamd.repo -o /etc/yum.repos.d/rspamd.repo 2>/dev/null
    fi
    dnf install -y rspamd 2>&1 | tee -a "$LOG_FILE"
fi

ok "Packages installed"

# ============================================================
#  STEP 2: Create mail user & directories
# ============================================================

info "Step 2/7 - Setting up mail directories..."

# Create vmail user
if ! id vmail &>/dev/null; then
    groupadd -g 5000 vmail
    useradd -g vmail -u 5000 -d "$MAIL_DIR" -s /sbin/nologin -M vmail
fi

mkdir -p "$MAIL_DIR/$MAIL_DOMAIN/$MAIL_USER"
chown -R vmail:vmail "$MAIL_DIR"
chmod -R 770 "$MAIL_DIR"

mkdir -p "$ETC_DIR"

ok "Mail directories created"

# ============================================================
#  STEP 3: Configure Postfix
# ============================================================

info "Step 3/7 - Configuring Postfix..."

HOSTNAME="mail.${MAIL_DOMAIN}"

# Backup original config
[ -f /etc/postfix/main.cf ] && cp /etc/postfix/main.cf /etc/postfix/main.cf.bak.$(date +%s)

cat > /etc/postfix/main.cf <<POSTFIX_EOF
# ============================================================
# ShieldPress Mail Server - Postfix Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# Basic settings
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

# Hostname
myhostname = ${HOSTNAME}
mydomain = ${MAIL_DOMAIN}
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost

# Network
inet_interfaces = all
inet_protocols = ipv4

# Mailbox
virtual_mailbox_domains = /etc/postfix/virtual_domains
virtual_mailbox_base = ${MAIL_DIR}
virtual_mailbox_maps = hash:/etc/postfix/virtual_mailbox
virtual_alias_maps = hash:/etc/postfix/virtual_alias
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000

# Size limits
message_size_limit = 52428800
mailbox_size_limit = 0

# TLS - Incoming
smtpd_use_tls = yes
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_cert_file = /etc/pki/tls/certs/postfix.pem
smtpd_tls_key_file = /etc/pki/tls/private/postfix.key
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# TLS - Outgoing
smtp_tls_security_level = may
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# SASL Authentication
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname

# Restrictions
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks,
    reject_non_fqdn_helo_hostname,
    reject_invalid_helo_hostname,
    permit

smtpd_sender_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain,
    permit

smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    reject_non_fqdn_recipient,
    reject_unknown_recipient_domain,
    permit

# Milters (OpenDKIM + Rspamd)
smtpd_milters = inet:localhost:8891, inet:localhost:11332
non_smtpd_milters = inet:localhost:8891, inet:localhost:11332
milter_protocol = 6
milter_default_action = accept
milter_mail_macros = i {mail_addr} {client_addr} {client_name} {auth_authen}
POSTFIX_EOF

# Virtual domains
echo "$MAIL_DOMAIN" > /etc/postfix/virtual_domains

# Virtual mailbox
echo "${MAIL_EMAIL}    ${MAIL_DOMAIN}/${MAIL_USER}/" > /etc/postfix/virtual_mailbox
postmap /etc/postfix/virtual_mailbox

# Virtual aliases (empty for now)
touch /etc/postfix/virtual_alias
postmap /etc/postfix/virtual_alias

# Enable submission port (587)
cat > /etc/postfix/master.cf.submission <<'SUBMIT_EOF'
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
SUBMIT_EOF

# Append submission to master.cf if not already there
if ! grep -q "^submission" /etc/postfix/master.cf; then
    cat /etc/postfix/master.cf.submission >> /etc/postfix/master.cf
fi
rm -f /etc/postfix/master.cf.submission

# Self-signed cert as temporary placeholder (always regenerate with correct hostname)
openssl req -new -x509 -days 365 -nodes \
    -out /etc/pki/tls/certs/postfix.pem \
    -keyout /etc/pki/tls/private/postfix.key \
    -subj "/CN=mail.${MAIL_DOMAIN}" 2>/dev/null

ok "Postfix configured"

# ============================================================
#  STEP 4: Configure Dovecot
# ============================================================

info "Step 4/7 - Configuring Dovecot..."

# Backup original
[ -f /etc/dovecot/dovecot.conf ] && cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak.$(date +%s)

# Disable default conf.d to prevent override conflicts
# AlmaLinux ships 10-auth.conf, 10-mail.conf etc. that conflict
if [ -d /etc/dovecot/conf.d ]; then
    mv /etc/dovecot/conf.d /etc/dovecot/conf.d.disabled 2>/dev/null || true
fi

cat > /etc/dovecot/dovecot.conf <<DOVECOT_EOF
# ============================================================
# ShieldPress Mail Server - Dovecot Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

protocols = imap lmtp

# Logging
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log

# SSL
ssl = required
ssl_cert = </etc/pki/tls/certs/postfix.pem
ssl_key = </etc/pki/tls/private/postfix.key
ssl_min_protocol = TLSv1.2

# Authentication
disable_plaintext_auth = yes
auth_mechanisms = plain login

passdb {
    driver = passwd-file
    args = scheme=SHA512-CRYPT /etc/dovecot/users
}

userdb {
    driver = static
    args = uid=vmail gid=vmail home=${MAIL_DIR}/%d/%n
}

# Mail location
mail_location = maildir:${MAIL_DIR}/%d/%n/Maildir

# Namespace
namespace inbox {
    inbox = yes
    separator = /

    mailbox Drafts {
        auto = subscribe
        special_use = \\Drafts
    }
    mailbox Sent {
        auto = subscribe
        special_use = \\Sent
    }
    mailbox Trash {
        auto = subscribe
        special_use = \\Trash
    }
    mailbox Junk {
        auto = subscribe
        special_use = \\Junk
    }
    mailbox Archive {
        auto = no
        special_use = \\Archive
    }
}

# LMTP for local delivery
service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
        mode = 0600
        user = postfix
        group = postfix
    }
}

# Auth for Postfix SASL
service auth {
    unix_listener /var/spool/postfix/private/auth {
        mode = 0666
        user = postfix
        group = postfix
    }
    unix_listener auth-userdb {
        mode = 0600
        user = vmail
    }
}

# Sieve (spam to Junk)
protocol lmtp {
    mail_plugins = \$mail_plugins sieve
}

plugin {
    sieve = ${MAIL_DIR}/%d/%n/.dovecot.sieve
    sieve_default = /etc/dovecot/sieve/default.sieve
    sieve_dir = ${MAIL_DIR}/%d/%n/sieve
}
DOVECOT_EOF

# Create password file with first user
HASHED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$MAIL_PASS" 2>/dev/null)
if [ -z "$HASHED_PASS" ]; then
    # Fallback: use openssl if doveadm fails
    HASHED_PASS=$(openssl passwd -6 "$MAIL_PASS" 2>/dev/null)
    HASHED_PASS="{SHA512-CRYPT}${HASHED_PASS}"
fi
echo "${MAIL_EMAIL}:${HASHED_PASS}" > /etc/dovecot/users
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# Default sieve rule - move spam to Junk
mkdir -p /etc/dovecot/sieve
cat > /etc/dovecot/sieve/default.sieve <<'SIEVE_EOF'
require ["fileinto", "mailbox"];

if header :is "X-Spam" "Yes" {
    fileinto :create "Junk";
    stop;
}
SIEVE_EOF

sievec /etc/dovecot/sieve/default.sieve 2>/dev/null || true

# Update Postfix to use Dovecot LMTP for delivery
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"

# Verify Dovecot config
if doveconf -n >/dev/null 2>&1; then
    ok "Dovecot configured"
else
    warn "Dovecot config has warnings (check: doveconf -n)"
fi

# Verify auth works
systemctl restart dovecot 2>/dev/null
sleep 1
AUTH_TEST=$(doveadm auth test "$MAIL_EMAIL" "$MAIL_PASS" 2>&1 || true)
if echo "$AUTH_TEST" | grep -qi "passdb\|ok"; then
    ok "Dovecot auth verified for $MAIL_EMAIL"
else
    warn "Dovecot auth test failed: $AUTH_TEST"
    warn "Check: /etc/dovecot/users permissions and content"
fi

# ============================================================
#  STEP 5: Configure Rspamd
# ============================================================

info "Step 5/7 - Configuring Rspamd..."

mkdir -p /etc/rspamd/local.d

# Worker configuration
cat > /etc/rspamd/local.d/worker-normal.inc <<'RSPAMD_WORKER'
bind_socket = "localhost:11333";
RSPAMD_WORKER

cat > /etc/rspamd/local.d/worker-proxy.inc <<'RSPAMD_PROXY'
bind_socket = "localhost:11332";
milter = yes;
timeout = 120s;
upstream "local" {
    default = yes;
    self_scan = yes;
}
RSPAMD_PROXY

# Classifier (spam learning)
cat > /etc/rspamd/local.d/classifier-bayes.conf <<'RSPAMD_BAYES'
autolearn = true;
RSPAMD_BAYES

# Actions - what to do with spam
cat > /etc/rspamd/local.d/actions.conf <<'RSPAMD_ACTIONS'
reject = 15;
add_header = 6;
greylist = 4;
RSPAMD_ACTIONS

# Add header for sieve filtering
cat > /etc/rspamd/local.d/milter_headers.conf <<'RSPAMD_HEADERS'
use = ["x-spam-status", "x-spam-flag", "authentication-results"];
RSPAMD_HEADERS

ok "Rspamd configured"

# ============================================================
#  STEP 6: Configure OpenDKIM
# ============================================================

info "Step 6/7 - Configuring OpenDKIM + DNS records..."

mkdir -p /etc/opendkim/keys

cat > /etc/opendkim.conf <<DKIM_EOF
AutoRestart             Yes
AutoRestartRate         10/1h
Canonicalization        relaxed/simple
Domain                  ${MAIL_DOMAIN}
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Mode                    sv
PidFile                 /run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256
UserID                  opendkim:opendkim
Socket                  inet:8891@localhost
Syslog                  Yes
SyslogSuccess           Yes
LogWhy                  Yes
DKIM_EOF

# Trusted hosts
cat > /etc/opendkim/TrustedHosts <<TRUST_EOF
127.0.0.1
localhost
${MAIL_DOMAIN}
*.${MAIL_DOMAIN}
TRUST_EOF

# Generate DKIM key
generate_dkim "$MAIL_DOMAIN"

# Key table
echo "mail._domainkey.${MAIL_DOMAIN} ${MAIL_DOMAIN}:mail:/etc/opendkim/keys/${MAIL_DOMAIN}/mail.private" > /etc/opendkim/KeyTable

# Signing table
echo "*@${MAIL_DOMAIN} mail._domainkey.${MAIL_DOMAIN}" > /etc/opendkim/SigningTable

ok "OpenDKIM configured"

# ============================================================
#  STEP 7: Fail2Ban + Firewall + SSL
# ============================================================

info "Step 7/7 - Security & SSL..."

# Fail2Ban jails for mail
if command -v fail2ban-client &>/dev/null; then
    cat > /etc/fail2ban/jail.d/mail.conf <<'F2B_EOF'
[postfix]
enabled  = true
port     = smtp,465,submission
filter   = postfix
logpath  = /var/log/maillog
maxretry = 5
findtime = 600
bantime  = 3600

[dovecot]
enabled  = true
port     = imap,993,pop3,995
filter   = dovecot
logpath  = /var/log/dovecot.log
maxretry = 5
findtime = 600
bantime  = 3600

[postfix-sasl]
enabled  = true
port     = smtp,465,submission
filter   = postfix[mode=auth]
logpath  = /var/log/maillog
maxretry = 3
findtime = 600
bantime  = 7200
F2B_EOF

    systemctl restart fail2ban 2>/dev/null || true
    ok "Fail2Ban mail jails enabled"
else
    warn "Fail2Ban not installed - mail jails skipped"
fi

# Firewall - open mail ports
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=smtp 2>/dev/null || true
    firewall-cmd --permanent --add-service=smtps 2>/dev/null || true
    firewall-cmd --permanent --add-port=587/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-service=imap 2>/dev/null || true
    firewall-cmd --permanent --add-service=imaps 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    ok "Firewall ports opened (25, 465, 587, 143, 993)"
fi

# Let's Encrypt SSL for mail hostname
get_server_ip
CERT_DIR="/etc/letsencrypt/live/mail.${MAIL_DOMAIN}"

# Reuse existing valid cert if available (avoids breaking SSL on reinstall)
if [ -f "$CERT_DIR/fullchain.pem" ] && openssl x509 -checkend 86400 -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null; then
    info "Existing SSL certificate found for mail.${MAIL_DOMAIN} - reusing..."

    # Apply to Postfix
    postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem"
    postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem"

    # Apply to Dovecot
    sed -i "s|ssl_cert = .*|ssl_cert = <$CERT_DIR/fullchain.pem|" /etc/dovecot/dovecot.conf
    sed -i "s|ssl_key = .*|ssl_key = <$CERT_DIR/privkey.pem|" /etc/dovecot/dovecot.conf

    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)
    ok "SSL certificate applied (expires: ${EXPIRY})"
else
    A_RECORD=$(dig +short A "mail.${MAIL_DOMAIN}" 2>/dev/null | tail -1)

    if [ -n "$A_RECORD" ] && [ "$A_RECORD" = "$SERVER_IP" ]; then
        info "Requesting Let's Encrypt certificate for mail.${MAIL_DOMAIN}..."

        # Stop Nginx temporarily so certbot can use port 80
        NGINX_WAS_RUNNING=false
        if systemctl is-active --quiet nginx 2>/dev/null; then
            NGINX_WAS_RUNNING=true
            systemctl stop nginx 2>/dev/null
        fi

        certbot certonly --standalone \
            --agree-tos --non-interactive \
            -d "mail.${MAIL_DOMAIN}" \
            --email "postmaster@${MAIL_DOMAIN}" \
            2>&1 | tee -a "$LOG_FILE"

        if $NGINX_WAS_RUNNING; then
            systemctl start nginx 2>/dev/null
        fi

        if [ -f "$CERT_DIR/fullchain.pem" ]; then
            postconf -e "smtpd_tls_cert_file = $CERT_DIR/fullchain.pem"
            postconf -e "smtpd_tls_key_file = $CERT_DIR/privkey.pem"
            sed -i "s|ssl_cert = .*|ssl_cert = <$CERT_DIR/fullchain.pem|" /etc/dovecot/dovecot.conf
            sed -i "s|ssl_key = .*|ssl_key = <$CERT_DIR/privkey.pem|" /etc/dovecot/dovecot.conf
            ok "Let's Encrypt SSL installed for mail.${MAIL_DOMAIN}"
        else
            warn "Let's Encrypt failed - using self-signed certificate"
            warn "Use [12] Install SSL from Email menu after DNS is ready"
        fi
    else
        warn "mail.${MAIL_DOMAIN} does not point to this server (${SERVER_IP}) yet"
        warn "Using self-signed certificate - use [12] Install SSL after DNS is ready"
    fi
fi

# ============================================================
#  CONFIGURE SMTP RELAY
# ============================================================

if [ "$RELAY_TYPE" = "brevo" ]; then
    info "Configuring Brevo SMTP relay..."

    postconf -e "relayhost = [smtp-relay.brevo.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"

    echo "[smtp-relay.brevo.com]:587 ${RELAY_LOGIN}:${RELAY_KEY}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    ok "Brevo relay configured (300 free emails/day)"

elif [ "$RELAY_TYPE" = "ses" ]; then
    info "Configuring Amazon SES relay..."

    postconf -e "relayhost = [email-smtp.${RELAY_REGION}.amazonaws.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"

    echo "[email-smtp.${RELAY_REGION}.amazonaws.com]:587 ${RELAY_KEY}:${RELAY_SECRET}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    ok "Amazon SES relay configured (Region: ${RELAY_REGION})"
fi

# ============================================================
#  SAVE CONFIG & START SERVICES
# ============================================================

# Save email config
cat > "$EMAIL_CONFIG" <<CONFIG_EOF
# ShieldPress Email Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
MAIL_DOMAIN=${MAIL_DOMAIN}
MAIL_HOSTNAME=${HOSTNAME}
MAIL_USER=${MAIL_USER}
RELAY_TYPE=${RELAY_TYPE}
RELAY_REGION=${RELAY_REGION}
INSTALLED=$(date '+%Y-%m-%d %H:%M:%S')
CONFIG_EOF
chmod 600 "$EMAIL_CONFIG"

# Enable and start services
systemctl enable postfix dovecot rspamd opendkim 2>/dev/null
systemctl restart opendkim 2>/dev/null
systemctl restart rspamd 2>/dev/null
systemctl restart postfix 2>/dev/null
systemctl restart dovecot 2>/dev/null

# Mark as installed
touch "$ETC_DIR/.mail_installed"

# Create Maildir structure for the first user
su - vmail -s /bin/bash -c "mkdir -p $MAIL_DIR/$MAIL_DOMAIN/$MAIL_USER/Maildir/{cur,new,tmp}" 2>/dev/null || \
    mkdir -p "$MAIL_DIR/$MAIL_DOMAIN/$MAIL_USER/Maildir"/{cur,new,tmp}
chown -R vmail:vmail "$MAIL_DIR"

log "=== EMAIL INSTALLATION COMPLETED ==="

# ============================================================
#  SHOW RESULTS
# ============================================================

echo ""
sp_hr
echo -e "  ${BOLD}${GREEN}Email Server Installed Successfully!${RESET}"
sp_hr
echo ""
echo -e "  ${BOLD}Mail Account:${RESET}"
echo -e "  Email     : ${GREEN}${MAIL_EMAIL}${RESET}"
echo -e "  Password  : (as entered)"
echo ""
echo -e "  ${BOLD}Server Settings (for mail client):${RESET}"
echo -e "  IMAP      : mail.${MAIL_DOMAIN}  Port 993 (SSL)"
echo -e "  SMTP      : mail.${MAIL_DOMAIN}  Port 587 (STARTTLS)"
echo -e "  Username  : ${MAIL_EMAIL}"
echo ""
echo -e "  ${BOLD}${YELLOW}DNS Records Required:${RESET}"
echo -e "  ${DIM}Add these DNS records at your domain registrar:${RESET}"
echo ""
echo -e "  ${CYAN}MX${RESET}     ${MAIL_DOMAIN}         → mail.${MAIL_DOMAIN}  (Priority 10)"
echo -e "  ${CYAN}A${RESET}      mail.${MAIL_DOMAIN}    → ${SERVER_IP:-YOUR_SERVER_IP}"
echo -e "  ${CYAN}TXT${RESET}    ${MAIL_DOMAIN}         → v=spf1 mx a ip4:${SERVER_IP:-YOUR_IP} ~all"
echo -e "  ${CYAN}TXT${RESET}    _dmarc.${MAIL_DOMAIN}  → v=DMARC1; p=quarantine; rua=mailto:postmaster@${MAIL_DOMAIN}"
echo ""

# Show DKIM record (clean single-line value)
DKIM_VALUE=$(get_dkim_value "$MAIL_DOMAIN")
if [ -n "$DKIM_VALUE" ]; then
    echo -e "  ${CYAN}TXT${RESET}    mail._domainkey.${MAIL_DOMAIN} →"
    echo -e "  ${DIM}${DKIM_VALUE}${RESET}"
fi

# Export DNS records to file
echo ""
EXPORT_FILE=$(export_dns_records "$MAIL_DOMAIN" "${SERVER_IP:-YOUR_SERVER_IP}")
echo ""
echo -e "  ${BOLD}${GREEN}DNS records file:${RESET}"
echo -e "  ${CYAN}${EXPORT_FILE}${RESET}"
echo ""
echo -e "  ${DIM}Download file via SFTP:${RESET}"
echo -e "  ${DIM}  sftp root@${SERVER_IP:-YOUR_IP}:${EXPORT_FILE} .${RESET}"
echo -e "  ${DIM}Copy each record into Cloudflare DNS panel${RESET}"
echo -e "  ${DIM}Delete file after use: rm ${EXPORT_FILE}${RESET}"
sp_hr
echo ""

read -p "Press Enter to continue..."
