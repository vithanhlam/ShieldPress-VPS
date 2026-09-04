#!/bin/bash
# ============================================================
#  Install Roundcube Webmail
#  Access email via browser at https://mail.domain.com
#  Lightweight: ~30MB RAM, runs on existing Nginx + PHP
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"
DOMAINS_ROOT="/home/domains"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Install Webmail" "Roundcube web client"

if ! mail_installed; then
    fail "Email server not installed. Install email server first."
    read -p "Press Enter..."
    exit 1
fi

# Get mail domain
MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
MAIL_HOSTNAME="mail.${MAIL_DOMAIN}"

if [ -z "$MAIL_DOMAIN" ]; then
    fail "Mail domain not configured"
    read -p "Press Enter..."
    exit 1
fi

# Check if already installed
if [ -f "$ETC_DIR/.webmail_installed" ]; then
    warn "Webmail is already installed!"
    echo -e "  URL: ${GREEN}https://${MAIL_HOSTNAME}${RESET}"
    echo ""
    read -p "Reinstall? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0
fi

echo ""
info "This will install Roundcube webmail at:"
echo -e "  ${GREEN}https://${MAIL_HOSTNAME}${RESET}"
echo ""
echo -e "  ${BOLD}Components:${RESET}"
echo -e "  ${DIM}├── Roundcube (latest stable)${RESET}"
echo -e "  ${DIM}├── Nginx vhost for ${MAIL_HOSTNAME}${RESET}"
echo -e "  ${DIM}├── Let's Encrypt SSL${RESET}"
echo -e "  ${DIM}└── SQLite database (no extra DB needed)${RESET}"
echo ""

# HTTP Basic Auth - optional, or reuse existing
HTAUTH_USER=""
HTAUTH_PASS=""
SETUP_AUTH=false

if [ -f "/etc/nginx/.webmail_htpasswd" ]; then
    EXISTING_AUTH_USER=$(head -1 /etc/nginx/.webmail_htpasswd | cut -d: -f1 2>/dev/null)
    info "Existing HTTP Basic Auth found (user: ${EXISTING_AUTH_USER:-unknown})"
    read -p "  Keep existing HTTP Auth? (Y/n): " KEEP_AUTH
    KEEP_AUTH="${KEEP_AUTH:-Y}"
    if [[ "$KEEP_AUTH" =~ ^[Yy]$ ]]; then
        SETUP_AUTH=false
        info "Keeping existing HTTP Auth"
    else
        SETUP_AUTH=true
    fi
else
    echo ""
    sp_hr
    echo -e "  ${BOLD}HTTP Basic Auth${RESET} ${DIM}(optional extra security layer)${RESET}"
    sp_hr
    echo ""
    read -p "  Set up HTTP Basic Auth? (y/N): " ASK_AUTH
    ASK_AUTH="${ASK_AUTH:-N}"
    [[ "$ASK_AUTH" =~ ^[Yy]$ ]] && SETUP_AUTH=true || SETUP_AUTH=false
    $SETUP_AUTH || info "Skipping HTTP Auth - configure later via Webmail settings [1]"
fi

if $SETUP_AUTH; then
    echo ""
    while true; do
        read -p "  Auth username: " HTAUTH_USER
        if [[ "$HTAUTH_USER" =~ ^[a-zA-Z0-9._-]+$ ]] && [ -n "$HTAUTH_USER" ]; then
            break
        fi
        fail "Invalid username (letters, numbers, dots, hyphens only)"
    done

    while true; do
        read -sp "  Auth password (min 6 chars): " HTAUTH_PASS
        echo ""
        if [ ${#HTAUTH_PASS} -ge 6 ]; then
            read -sp "  Confirm password: " HTAUTH_PASS2
            echo ""
            if [ "$HTAUTH_PASS" = "$HTAUTH_PASS2" ]; then
                break
            fi
            fail "Passwords do not match"
        else
            fail "Password too short"
        fi
    done
fi

echo ""
read -p "Start installation? (y/n): " START
[[ ! "$START" =~ ^[Yy]$ ]] && exit 0

echo ""
log "=== WEBMAIL INSTALLATION STARTED ==="

# ============================================================
#  Step 1: Check PHP
# ============================================================

info "Step 1/5 - Checking PHP..."

# Find available PHP version
PHP_VERSION=""
for v in 8.4 8.3 8.2 8.1; do
    if command -v "php-fpm${v/./}" &>/dev/null || [ -f "/etc/php-fpm.d/www.conf" ] || rpm -q "php${v/./}-php-fpm" &>/dev/null 2>&1; then
        PHP_VERSION="$v"
        break
    fi
done

if [ -z "$PHP_VERSION" ]; then
    # Try generic php
    if command -v php &>/dev/null; then
        PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
    fi
fi

if [ -z "$PHP_VERSION" ]; then
    fail "PHP not found. Install PHP from ShieldPress menu first."
    read -p "Press Enter..."
    exit 1
fi

PHP_SHORT="${PHP_VERSION/./}"

# Install required PHP extensions
dnf install -y \
    php${PHP_SHORT}-php-intl \
    php${PHP_SHORT}-php-ldap \
    php${PHP_SHORT}-php-pdo \
    php${PHP_SHORT}-php-xml \
    php${PHP_SHORT}-php-mbstring \
    php${PHP_SHORT}-php-zip \
    php${PHP_SHORT}-php-gd \
    php${PHP_SHORT}-php-sodium \
    php${PHP_SHORT}-php-pecl-imagick \
    2>/dev/null || true

ok "PHP $PHP_VERSION ready"

# ============================================================
#  Step 2: Download Roundcube
# ============================================================

info "Step 2/5 - Downloading Roundcube..."

WEBMAIL_DIR="/var/www/webmail"

# Get latest stable version
RC_VERSION=$(curl -fsSL --connect-timeout 3 --max-time 8 \
    https://api.github.com/repos/roundcube/roundcubemail/releases/latest 2>/dev/null \
    | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | head -1)
# Keep the fallback on the current stable security branch, never an old release.
[ -z "$RC_VERSION" ] && RC_VERSION="1.7.3"

RC_URL="https://github.com/roundcube/roundcubemail/releases/download/${RC_VERSION}/roundcubemail-${RC_VERSION}-complete.tar.gz"

mkdir -p "$WEBMAIL_DIR"

if curl -fsSL "$RC_URL" -o /tmp/roundcube.tar.gz 2>/dev/null; then
    tar -xzf /tmp/roundcube.tar.gz -C /tmp/
    cp -rf /tmp/roundcubemail-${RC_VERSION}/* "$WEBMAIL_DIR/"
    rm -rf /tmp/roundcube.tar.gz /tmp/roundcubemail-${RC_VERSION}
    ok "Roundcube ${RC_VERSION} downloaded"
else
    fail "Failed to download Roundcube"
    read -p "Press Enter..."
    exit 1
fi

# Set permissions
chown -R nginx:nginx "$WEBMAIL_DIR"
chmod -R 755 "$WEBMAIL_DIR"
chmod -R 770 "$WEBMAIL_DIR/temp" "$WEBMAIL_DIR/logs"

# ============================================================
#  Step 3: Configure Roundcube
# ============================================================

info "Step 3/5 - Configuring Roundcube..."

# Generate random DES key
DES_KEY=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

cat > "$WEBMAIL_DIR/config/config.inc.php" <<RC_CONFIG
<?php

\$config = array();

// Database (SQLite - no extra DB needed)
\$config['db_dsnw'] = 'sqlite:///$WEBMAIL_DIR/db/roundcube.db?mode=0640';

// IMAP server
\$config['imap_host'] = 'ssl://localhost:993';
\$config['imap_conn_options'] = array(
    'ssl' => array(
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ),
);

// SMTP server
\$config['smtp_host'] = 'tls://localhost';
\$config['smtp_port'] = 587;
\$config['smtp_conn_options'] = array(
    'ssl' => array(
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ),
);

// System
\$config['support_url'] = '';
\$config['product_name'] = 'ShieldPress Mail';
\$config['des_key'] = '${DES_KEY}';
\$config['plugins'] = array('archive', 'zipdownload', 'managesieve');
\$config['language'] = 'en_US';
\$config['skin'] = 'elastic';

// User interface
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['username_domain'] = '${MAIL_DOMAIN}';

// Security
\$config['login_autocomplete'] = 2;
\$config['ip_check'] = false;
\$config['session_lifetime'] = 60;

// Temp and logs
\$config['temp_dir'] = '$WEBMAIL_DIR/temp/';
\$config['log_dir'] = '$WEBMAIL_DIR/logs/';
RC_CONFIG

# Create SQLite database directory
mkdir -p "$WEBMAIL_DIR/db"
chown nginx:nginx "$WEBMAIL_DIR/db"

# Initialize SQLite database
if [ -f "$WEBMAIL_DIR/SQL/sqlite.initial.sql" ]; then
    sqlite3 "$WEBMAIL_DIR/db/roundcube.db" < "$WEBMAIL_DIR/SQL/sqlite.initial.sql" 2>/dev/null
    chown nginx:nginx "$WEBMAIL_DIR/db/roundcube.db"
    chmod 640 "$WEBMAIL_DIR/db/roundcube.db"
fi

# Remove installer directory for security
rm -rf "$WEBMAIL_DIR/installer"

ok "Roundcube configured"

# ============================================================
#  Step 4: Nginx vhost + SSL
# ============================================================

info "Step 4/5 - Configuring Nginx + SSL..."

# Detect PHP-FPM socket
PHP_SOCK=""
for sock in "/var/opt/remi/php${PHP_SHORT}/run/php-fpm/www.sock" \
            "/run/php-fpm/www.sock" \
            "/var/run/php-fpm/www.sock" \
            "/run/php${PHP_SHORT}-php-fpm.sock"; do
    if [ -S "$sock" ]; then
        PHP_SOCK="$sock"
        break
    fi
done

# Fallback to TCP
if [ -z "$PHP_SOCK" ]; then
    PHP_SOCK="127.0.0.1:9000"
    PHP_FASTCGI="$PHP_SOCK"
else
    PHP_FASTCGI="unix:$PHP_SOCK"
fi

# Create / update htpasswd file
HTPASSWD_FILE="/etc/nginx/.webmail_htpasswd"
if $SETUP_AUTH && [ -n "$HTAUTH_USER" ]; then
    echo "${HTAUTH_USER}:$(openssl passwd -apr1 "$HTAUTH_PASS")" > "$HTPASSWD_FILE"
    chown root:nginx "$HTPASSWD_FILE"
    chmod 640 "$HTPASSWD_FILE"
    ok "HTTP Basic Auth configured (user: ${HTAUTH_USER})"
fi

# Build auth_basic block for Nginx (only if htpasswd exists)
if [ -f "$HTPASSWD_FILE" ]; then
    AUTH_BASIC_BLOCK="    auth_basic \"ShieldPress Mail\";
    auth_basic_user_file ${HTPASSWD_FILE};"
else
    AUTH_BASIC_BLOCK=""
fi

# Create Nginx vhost (HTTP first for Let's Encrypt)
cat > /etc/nginx/conf.d/webmail.conf <<NGINX_EOF
server {
    listen 80;
    server_name ${MAIL_HOSTNAME};
    root ${WEBMAIL_DIR}/public_html;
    index index.php;

${AUTH_BASIC_BLOCK}

    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    # All requests go through index.php (Roundcube handles asset serving via PHP)
    location / {
        try_files \$uri /index.php\$request_uri;
    }

    location ~ \.php(\$|/) {
        fastcgi_pass ${PHP_FASTCGI};
        fastcgi_index index.php;
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
        fastcgi_read_timeout 60;
    }

    location ~ /\. {
        deny all;
    }
}
NGINX_EOF

# Test and reload Nginx
nginx -t 2>/dev/null
if [ $? -ne 0 ]; then
    warn "Nginx config error - check: nginx -t"
    read -p "Press Enter..."
    exit 1
fi

systemctl reload nginx

# SSL with Let's Encrypt
get_server_ip
A_RECORD=$(dig +short A "${MAIL_HOSTNAME}" 2>/dev/null | tail -1)

if [ -n "$A_RECORD" ] && [ "$A_RECORD" = "$SERVER_IP" ]; then
    info "Requesting SSL certificate for ${MAIL_HOSTNAME}..."

    certbot --nginx \
        --agree-tos --non-interactive \
        -d "${MAIL_HOSTNAME}" \
        --email "postmaster@${MAIL_DOMAIN}" \
        2>&1 | tee -a "$LOG_FILE"

    if [ $? -eq 0 ]; then
        ok "Let's Encrypt SSL installed for ${MAIL_HOSTNAME}"
    else
        warn "SSL failed - webmail accessible via HTTP only"
        warn "Run: certbot --nginx -d ${MAIL_HOSTNAME}"
    fi
else
    warn "DNS for ${MAIL_HOSTNAME} does not point to this server"
    warn "SSL skipped - set A record first, then run:"
    warn "certbot --nginx -d ${MAIL_HOSTNAME}"
fi

ok "Nginx configured"

# ============================================================
#  Step 5: Finalize
# ============================================================

info "Step 5/5 - Finalizing..."

# Mark as installed
touch "$ETC_DIR/.webmail_installed"

# Save webmail info to config
if grep -q "^WEBMAIL=" "$EMAIL_CONFIG" 2>/dev/null; then
    sed -i "s|^WEBMAIL=.*|WEBMAIL=${MAIL_HOSTNAME}|" "$EMAIL_CONFIG"
else
    echo "WEBMAIL=${MAIL_HOSTNAME}" >> "$EMAIL_CONFIG"
fi

log "=== WEBMAIL INSTALLATION COMPLETED ==="

echo ""
sp_hr
echo -e "  ${BOLD}${GREEN}Webmail Installed Successfully!${RESET}"
sp_hr
echo ""
echo -e "  ${BOLD}Access:${RESET}"
echo -e "  URL      : ${GREEN}https://${MAIL_HOSTNAME}${RESET}"
echo ""
if [ -f "$HTPASSWD_FILE" ]; then
    HTAUTH_DISPLAY=$(head -1 "$HTPASSWD_FILE" | cut -d: -f1 2>/dev/null)
    echo -e "  ${BOLD}Step 1 - HTTP Basic Auth (browser popup):${RESET}"
    echo -e "  Username : ${CYAN}${HTAUTH_DISPLAY}${RESET}"
    echo -e "  Password : (as entered)"
    echo ""
    echo -e "  ${BOLD}Step 2 - Roundcube Login:${RESET}"
else
    echo -e "  ${DIM}HTTP Auth not configured - set up via Webmail settings [1]${RESET}"
    echo ""
    echo -e "  ${BOLD}Roundcube Login:${RESET}"
fi
echo -e "  Username : ${CYAN}support@${MAIL_DOMAIN}${RESET} (or any email account)"
echo -e "  Password : (email account password)"
echo ""
echo -e "  ${BOLD}Details:${RESET}"
echo -e "  Roundcube: ${CYAN}${RC_VERSION}${RESET}"
echo -e "  PHP      : ${CYAN}${PHP_VERSION}${RESET}"
echo -e "  Database : ${CYAN}SQLite${RESET}"
echo -e "  Path     : ${DIM}${WEBMAIL_DIR}${RESET}"
echo ""
sp_hr

read -p "Press Enter..."
