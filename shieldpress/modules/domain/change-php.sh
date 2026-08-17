#!/bin/bash

source /opt/shieldpress/modules/domain/helpers.sh

LOG_FILE="$LOG_DIR/php-change.log"
mkdir -p "$LOG_DIR"

log(){
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

pause(){
    echo ""
    read -p "Press Enter to continue..."
}

select_domain || exit 1

OLD_PHP_VERSION="$PHP_VERSION"
OLD_PHP_SHORT=$(echo "$OLD_PHP_VERSION" | tr -d '.')

echo "Current PHP: $OLD_PHP_VERSION"
echo ""

select_php_version || exit 1

NEW_PHP_VERSION="$PHP_VERSION"
NEW_PHP_SHORT=$(php_version_to_short "$NEW_PHP_VERSION")

if [ "$OLD_PHP_SHORT" = "$NEW_PHP_SHORT" ]; then
    echo "Selected PHP version is the same. Nothing to change."
    pause
    exit 0
fi

NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
NGINX_BACKUP="${NGINX_CONF}.phpbak.$(date +%Y%m%d_%H%M%S)"

OLD_POOL="/etc/opt/remi/php${OLD_PHP_SHORT}/php-fpm.d/${CLEAN_DOMAIN}.conf"
NEW_POOL="/etc/opt/remi/php${NEW_PHP_SHORT}/php-fpm.d/${CLEAN_DOMAIN}.conf"

# Ensure the requested PHP runtime exists before changing the pool/socket.
if ! ensure_php_version_installed "$NEW_PHP_VERSION"; then
    echo "PHP ${NEW_PHP_VERSION} install failed!"
    pause
    exit 1
fi

# ==========================================
# BACKUP NGINX CONFIG
# ==========================================

cp "$NGINX_CONF" "$NGINX_BACKUP"

# ==========================================
# REMOVE OLD POOL
# ==========================================

if [ -f "$OLD_POOL" ]; then
    rm -f "$OLD_POOL"
    systemctl restart "php${OLD_PHP_SHORT}-php-fpm" 2>/dev/null
fi

# ==========================================
# CREATE NEW POOL
# ==========================================

create_php_pool || {
    echo "Failed to create new PHP pool!"
    mv "$NGINX_BACKUP" "$NGINX_CONF"
    pause
    exit 1
}

# ==========================================
# UPDATE NGINX SOCKET REFERENCE SAFELY
# ==========================================

sed -i "s/php${OLD_PHP_SHORT}\/run\/php-fpm/php${NEW_PHP_SHORT}\/run\/php-fpm/g" "$NGINX_CONF"

# ==========================================
# VALIDATE NGINX BEFORE RELOAD
# ==========================================

nginx -t
if [ $? -ne 0 ]; then
    echo "Nginx config error! Rolling back..."
    mv "$NGINX_BACKUP" "$NGINX_CONF"
    create_php_pool
    pause
    exit 1
fi

# ==========================================
# RESTART SERVICES
# ==========================================

systemctl restart "php${NEW_PHP_SHORT}-php-fpm"
systemctl reload nginx

# ==========================================
# UPDATE domain.env
# ==========================================

sed -i "s/^PHP_VERSION=.*/PHP_VERSION=${NEW_PHP_VERSION}/" \
"$DOMAIN_PATH/config/domain.env"

echo ""
echo "===================================="
echo "PHP version changed successfully!"
echo "Old: $OLD_PHP_VERSION"
echo "New: $NEW_PHP_VERSION"
echo "===================================="

log "Domain $SELECTED_DOMAIN PHP changed from $OLD_PHP_VERSION to $NEW_PHP_VERSION"

pause