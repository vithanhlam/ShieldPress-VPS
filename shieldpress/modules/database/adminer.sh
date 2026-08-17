#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/database.log"
DATA_FILE="/etc/shieldpress/adminer.env"

ADMINER_DIR="/var/www/adminer"
NGINX_CONF="/etc/nginx/conf.d/000-adminer.conf"
HTPASSWD="/etc/nginx/.adminer_pass"

ADMIN_PORT=5599

mkdir -p "$DATA_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "/etc/shieldpress"

# ==============================
# DETECT SERVER IP
# ==============================

SERVER_IP=$(curl -s --connect-timeout 3 --max-time 5 ifconfig.me || curl -s --connect-timeout 3 --max-time 5 api.ipify.org)

# ==============================
# AUTO-DETECT PHP-FPM SOCKET
# ==============================

detect_php_sock(){
    local sock=""
    # Try Remi PHP versions from newest to oldest
    for ver in 84 83 82 81 80; do
        sock="/var/opt/remi/php${ver}/run/php-fpm/www.sock"
        if [ -S "$sock" ]; then
            echo "$sock"
            return 0
        fi
    done
    # Fallback: system default PHP-FPM
    for sock in /run/php-fpm/www.sock /var/run/php-fpm/www.sock; do
        if [ -S "$sock" ]; then
            echo "$sock"
            return 0
        fi
    done
    # Last resort: find any active php-fpm socket
    sock=$(find /var/opt/remi /run /var/run -name "www.sock" -type s 2>/dev/null | head -1)
    if [ -n "$sock" ]; then
        echo "$sock"
        return 0
    fi
    echo ""
    return 1
}

PHP_SOCK=""

# ==============================
# ENSURE DEFAULT PHP SOCKET PERMISSION
# ==============================

fix_php_socket() {
    PHP_SOCK=$(detect_php_sock)
    if [ -z "$PHP_SOCK" ]; then
        echo "WARNING: No PHP-FPM socket found. Make sure PHP-FPM is installed and running."
        return 1
    fi
    if [ -S "$PHP_SOCK" ]; then
        chown nginx:nginx "$PHP_SOCK" 2>/dev/null
        chmod 660 "$PHP_SOCK" 2>/dev/null
    fi
}

# ==============================
# INSTALL ADMINER IF MISSING
# ==============================

install_adminer() {

    if [ -f "$ADMINER_DIR/index.php" ]; then
        return
    fi

    echo "Installing Adminer..."
    mkdir -p $ADMINER_DIR
    wget -q https://www.adminer.org/latest.php -O $ADMINER_DIR/index.php
    chmod -R 755 $ADMINER_DIR

    # SELinux context
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_content_t "/var/www/adminer(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t httpd_sys_content_t "/var/www/adminer(/.*)?"
        restorecon -Rv /var/www/adminer >/dev/null 2>&1
    fi
}

# ==============================
# ENABLE ADMINER
# ==============================

enable_adminer() {

    install_adminer
    fix_php_socket || return

    echo "Using PHP-FPM socket: $PHP_SOCK"
    echo ""

    read -p "Set Adminer username: " ADMIN_USER
    read -s -p "Set Adminer password: " ADMIN_PASS
    echo ""

    if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
        echo "Username / Password cannot be empty!"
        return
    fi

    dnf install -y httpd-tools >/dev/null 2>&1

    # Use SHA1 (stable with nginx)
    htpasswd -csb "$HTPASSWD" "$ADMIN_USER" "$ADMIN_PASS"

    chown root:nginx "$HTPASSWD"
    chmod 640 "$HTPASSWD"

    # SELinux allow port
    if command -v semanage >/dev/null 2>&1; then
        semanage port -a -t http_port_t -p tcp ${ADMIN_PORT} 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp ${ADMIN_PORT}
    fi

    cat > "$NGINX_CONF" <<EOF
server {
    listen ${ADMIN_PORT};
    server_name _;

    root ${ADMINER_DIR};
    index index.php;

    auth_basic "Adminer Login";
    auth_basic_user_file ${HTPASSWD};

    location / {
        try_files \$uri \$uri/ /index.php;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    nginx -t || return
    systemctl reload nginx

    # Firewall
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${ADMIN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    cat > "$DATA_FILE" <<EOF
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
ADMIN_PORT=${ADMIN_PORT}
STATUS=enabled
EOF
    chmod 600 "$DATA_FILE"

    echo ""
    echo "========================================"
    echo "Adminer ENABLED"
    echo "URL: http://${SERVER_IP}:${ADMIN_PORT}"
    echo "========================================"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Adminer enabled" >> "$LOG_FILE"
}

# ==============================
# DISABLE ADMINER
# ==============================

disable_adminer() {

    rm -f "$NGINX_CONF"

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port=${ADMIN_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    nginx -t || return
    systemctl reload nginx

    if [ -f "$DATA_FILE" ]; then
        sed -i "s/STATUS=.*/STATUS=disabled/" "$DATA_FILE"
    fi

    echo "Adminer disabled."
}

# ==============================
# REMOVE ADMINER
# ==============================

remove_adminer() {

    read -p "Confirm remove Adminer? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    disable_adminer

    rm -rf "$ADMINER_DIR"
    rm -f "$HTPASSWD"
    rm -f "$DATA_FILE"

    echo "Adminer completely removed."
}

# ==============================
# MENU
# ==============================

while true; do

clear
echo "===================================================="
echo "         ADMINER MANAGER (PORT 5599 FIXED)"
echo "===================================================="

STATUS="disabled"
if [ -f "$DATA_FILE" ]; then
    STATUS=$(grep "^STATUS=" "$DATA_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    ADMIN_USER=$(grep "^ADMIN_USER=" "$DATA_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    ADMIN_PASS=$(grep "^ADMIN_PASS=" "$DATA_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    ADMIN_PORT=$(grep "^ADMIN_PORT=" "$DATA_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    STATUS="${STATUS:-disabled}"
fi

echo "Status : ${STATUS:-disabled}"

if [ "$STATUS" == "enabled" ]; then
    echo "URL   : http://${SERVER_IP}:${ADMIN_PORT}"
    echo "User  : ${ADMIN_USER}"
    echo "Pass  : ${ADMIN_PASS}"
fi

echo ""
echo " 1) Enable Adminer"
echo " 2) Disable Adminer"
echo " 3) Remove Adminer"
echo " 0) Back"
echo "----------------------------------------------------"

read -p "Select option: " choice

case $choice in
    1) enable_adminer ;;
    2) disable_adminer ;;
    3) remove_adminer ;;
    0) break ;;
    *) echo "Invalid option!" ;;
esac

echo ""
read -p "Press Enter to continue..."

done