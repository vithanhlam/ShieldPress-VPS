#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/wp-install.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

generate_prefix() {
    echo "wp_$(tr -dc a-z0-9 </dev/urandom | head -c6)_"
}

install_wpcli_if_missing() {
    if ! command -v wp &> /dev/null; then
        log "WP-CLI not found. Installing..."
        curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar >> "$LOG_FILE" 2>&1
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        log "WP-CLI installed successfully."
    else
        log "WP-CLI already installed."
    fi

    # Ensure 'php' is in PATH (Remi PHP not symlinked by default)
    if ! command -v php &> /dev/null; then
        local php_bin=""
        for ver in 84 83 82 81 80 74; do
            if [ -x "/opt/remi/php${ver}/root/usr/bin/php" ]; then
                php_bin="/opt/remi/php${ver}/root/usr/bin/php"
                break
            fi
        done
        if [ -n "$php_bin" ]; then
            ln -sf "$php_bin" /usr/local/bin/php
            log "PHP symlink created: /usr/local/bin/php → $php_bin"
        else
            log "WARNING: No PHP binary found to symlink"
        fi
    fi
}

# ==========================
# VALIDATE EMAIL
# ==========================

is_valid_email() {
    local email="$1"

    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]] || return 1
    [[ "$email" != *".."* ]] || return 1
}

# ==========================
# INPUT WITH VALIDATION
# ==========================

collect_input() {
    while true; do

        echo ""
        echo "===================================================="
        echo "  Enter WordPress Installation Info"
        echo "===================================================="

        # Site Title
        while true; do
            read -p "Site Title: " TITLE
            [ -n "$TITLE" ] && break
            echo "  Site title cannot be empty!"
        done

        # Admin User
        while true; do
            read -p "Admin Username: " ADMIN_USER
            if [ -z "$ADMIN_USER" ]; then
                echo "  Username cannot be empty!"
            elif [[ "$ADMIN_USER" =~ [^a-zA-Z0-9_-] ]]; then
                echo "  Username can only contain letters, numbers, _ and -"
            else
                break
            fi
        done

        # Admin Password
        while true; do
            read -s -p "Admin Password (min 8 chars): " ADMIN_PASS
            echo ""
            if [ ${#ADMIN_PASS} -lt 8 ]; then
                echo "  Password must be at least 8 characters!"
            else
                read -s -p "Confirm Password: " ADMIN_PASS2
                echo ""
                if [ "$ADMIN_PASS" != "$ADMIN_PASS2" ]; then
                    echo "  Passwords do not match!"
                else
                    break
                fi
            fi
        done

        # Admin Email
        while true; do
            read -p "Admin Email: " ADMIN_EMAIL
            if [ -z "$ADMIN_EMAIL" ]; then
                echo "  Email cannot be empty!"
            elif ! is_valid_email "$ADMIN_EMAIL"; then
                echo "  Invalid email format! Example: admin@example.com"
            else
                break
            fi
        done

        # ==========================
        # CONFIRMATION SCREEN
        # ==========================

        echo ""
        echo "===================================================="
        echo "  Confirm Installation Details"
        echo "===================================================="
        echo "  Domain     : $SELECTED_DOMAIN"
        echo "  Site URL   : $SITE_URL"
        echo "  Site Title : $TITLE"
        echo "  Admin User : $ADMIN_USER"
        echo "  Admin Email: $ADMIN_EMAIL"
        echo "  Password   : $(echo "$ADMIN_PASS" | sed 's/./*/g')"
        echo "  PHP        : $PHP_VERSION"
        echo "  DB Name    : $DB_NAME"
        echo "===================================================="
        echo ""
        echo "1) Confirm & Install"
        echo "2) Re-enter Info"
        echo "0) Cancel"
        echo "----------------------------------------------------"
        read -p "Select: " CONFIRM_OPT

        case $CONFIRM_OPT in
            1) return 0 ;;
            2) continue ;;
            0) echo "Cancelled."; exit 0 ;;
            *) echo "Invalid option, please try again." ;;
        esac

    done
}

# ==========================
# START
# ==========================

log "========== START WORDPRESS INSTALL =========="

install_wpcli_if_missing

select_domain || {
    log "ERROR: Domain selection failed"
    exit 1
}

# Fix: Luôn tính lại ROOT từ DOMAIN_PATH
ROOT="$DOMAIN_PATH/public_html"

if [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    log "ERROR: domain.env not found in $DOMAIN_PATH/config/"
    exit 1
fi

source "$DOMAIN_PATH/config/domain.env"

# Recalculate ROOT after source (domain.env may override it)
ROOT="$DOMAIN_PATH/public_html"

log "Installing WordPress for: $SELECTED_DOMAIN"
log "Domain path: $DOMAIN_PATH"
log "Web root: $ROOT"
log "PHP version: $PHP_VERSION"

# ==========================
# AUTO DETECT PHP
# ==========================

PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
PHP_SERVICE="php${PHP_SHORT}-php-fpm"
SOCKET="/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${CLEAN_DOMAIN}.sock"

if [ ! -x "$PHP_BIN" ]; then
    log "ERROR: PHP binary not found: $PHP_BIN"
    exit 1
fi

log "Using PHP binary: $PHP_BIN"

# Keep 'php' symlink pointing to the version used by this install
ln -sf "$PHP_BIN" /usr/local/bin/php

systemctl restart "$PHP_SERVICE" >> "$LOG_FILE" 2>&1
sleep 2

COUNT=0
while [ ! -S "$SOCKET" ] && [ $COUNT -lt 5 ]; do
    sleep 1
    COUNT=$((COUNT+1))
done

if [ ! -S "$SOCKET" ]; then
    log "ERROR: PHP socket not found: $SOCKET"
    exit 1
fi

log "PHP socket OK: $SOCKET"

# WP-CLI can exceed PHP's default 128M memory_limit while extracting core archives.
WP_CMD="sudo -u $CLEAN_DOMAIN $PHP_BIN -d memory_limit=512M /usr/local/bin/wp"

# ==========================
# CHECK EXISTING INSTALL
# ==========================

if [ -f "$ROOT/wp-config.php" ]; then
    echo ""
    echo "ERROR: WordPress already installed at $ROOT"
    echo "Remove existing installation first."
    read -p "Press Enter..."
    exit 1
fi

# ==========================
# DETECT PROTOCOL
# ==========================

if [ "$SSL" = "enabled" ]; then
    PROTOCOL="https"
else
    PROTOCOL="http"
fi

SITE_URL="${PROTOCOL}://${SELECTED_DOMAIN}"

# ==========================
# COLLECT & VALIDATE INPUT
# ==========================

collect_input

PREFIX=$(generate_prefix)
log "Generated DB prefix: $PREFIX"
log "Site URL: $SITE_URL"

# ==========================
# ENSURE PERMISSIONS
# ==========================

log "Preparing directory permissions..."

mkdir -p "$ROOT"

CURRENT_OWNER=$(stat -c "%U" "$DOMAIN_PATH")
if [ "$CURRENT_OWNER" != "$CLEAN_DOMAIN" ]; then
    chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$ROOT"
fi

chmod 755 /home/domains 2>/dev/null
chmod 755 "$DOMAIN_PATH"
chmod 755 "$ROOT"

if ! sudo -u "$CLEAN_DOMAIN" test -w "$ROOT"; then
    log "ERROR: $CLEAN_DOMAIN cannot write to $ROOT"
    ls -ld "$ROOT" >> "$LOG_FILE"
    exit 1
fi

log "Permission check passed."

# ==========================
# DOWNLOAD CORE
# ==========================

umask 022

log "Downloading WordPress core..."
$WP_CMD core download --path="$ROOT" --force >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: core download failed"
    exit 1
fi

log "WordPress core downloaded."

# ==========================
# CREATE CONFIG
# ==========================

log "Creating wp-config.php..."
$WP_CMD config create \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbprefix="$PREFIX" \
    --path="$ROOT" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: config create failed"
    exit 1
fi

log "wp-config.php created."

# ==========================
# INSTALL CORE
# ==========================

log "Running WordPress core install..."
$WP_CMD core install \
    --url="$SITE_URL" \
    --title="$TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" \
    --path="$ROOT" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: core install failed"
    cat "$LOG_FILE" | tail -20
    exit 1
fi

log "WordPress installed successfully."

# ==========================
# FIX PERMISSIONS (FINAL)
# ==========================

log "Finalizing permissions..."

chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$ROOT"
find "$ROOT" -type d \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 755 {} \;
find "$ROOT" -type f \
    -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
    -exec chmod 644 {} \;
chmod 600 "$ROOT/wp-config.php" 2>/dev/null

log "Final permissions applied."

# ==========================
# AUTO PURGE CACHE MU-PLUGIN
# ==========================

MU_TEMPLATE="/opt/shieldpress/templates/wp-mu-plugins/shieldpress-cache-purge.php"
MU_DIR="$ROOT/wp-content/mu-plugins"
PURGE_SCRIPT="/opt/shieldpress/bin/purge-fastcgi-cache"
SIGNAL_SCRIPT="/opt/shieldpress/bin/process-purge-signals"
SUDOERS_FILE="/etc/sudoers.d/shieldpress-cache-purge"
CRON_FILE="/etc/cron.d/shieldpress-cache-purge"

if [ -f "$MU_TEMPLATE" ]; then
    mkdir -p "$MU_DIR"
    cp "$MU_TEMPLATE" "$MU_DIR/shieldpress-cache-purge.php"
    chown "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$MU_DIR/shieldpress-cache-purge.php"
    chmod 644 "$MU_DIR/shieldpress-cache-purge.php"

    # Purge scripts permissions
    for _s in "$PURGE_SCRIPT" "$SIGNAL_SCRIPT"; do
        [ -f "$_s" ] && chmod 755 "$_s" && chown root:root "$_s"
    done

    # Sudoers (for exec method)
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo "ALL ALL=(root) NOPASSWD: $PURGE_SCRIPT" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
    fi

    # Cron to process purge signals (PHP writes to domain tmp dir)
    if [ ! -f "$CRON_FILE" ]; then
        cat > "$CRON_FILE" <<CRONEOF
# ShieldPress: process cache purge signals from PHP
* * * * * root $SIGNAL_SCRIPT >/dev/null 2>&1
CRONEOF
        chmod 644 "$CRON_FILE"
    fi

    log "Auto Purge Cache mu-plugin deployed."
else
    log "WARNING: Auto Purge template not found, skipping."
fi

# ==========================
# SECURITY SNIPPET
# ==========================

SECURITY_SNIPPET="/etc/nginx/snippets/security-wp.conf"

if [ ! -f "$SECURITY_SNIPPET" ]; then
    log "Creating Nginx security snippet..."
    mkdir -p /etc/nginx/snippets
    cat > "$SECURITY_SNIPPET" <<'EOF'
location = /xmlrpc.php { deny all; }
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=()" always;
add_header X-Powered-By "ShieldPress" always;
EOF
fi

NGINX_CONF="/etc/nginx/conf.d/$CLEAN_DOMAIN.conf"

if [ -f "$NGINX_CONF" ]; then
    if ! grep -q "security-wp.conf" "$NGINX_CONF"; then
        log "Injecting security snippet into Nginx config..."
        sed -i '/server_name/a \    include /etc/nginx/snippets/security-wp.conf;' "$NGINX_CONF"
    fi
else
    log "WARNING: Nginx config not found: $NGINX_CONF"
fi

nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1
log "Nginx reloaded."

# ==========================
# SAVE INFO
# ==========================

cat >> "$DOMAIN_PATH/db.txt" <<EOF

----------------------------
WordPress Installed:
URL: $SITE_URL
WP Admin User: $ADMIN_USER
WP Admin Email: $ADMIN_EMAIL
WP Table Prefix: $PREFIX
Installed At: $(date '+%Y-%m-%d %H:%M:%S')
EOF

chmod 600 "$DOMAIN_PATH/db.txt"
log "Installation info saved to db.txt"
log "========== INSTALL COMPLETED SUCCESSFULLY =========="

echo ""
echo "======================================"
echo " WordPress Installed Successfully!"
echo "======================================"
echo " URL      : $SITE_URL"
echo " WP Admin : $SITE_URL/wp-admin"
echo " Username : $ADMIN_USER"
echo " Email    : $ADMIN_EMAIL"
echo "======================================"
read -p "Press Enter..."
