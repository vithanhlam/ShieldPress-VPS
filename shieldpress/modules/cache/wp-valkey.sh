#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $SYSTEM_USER $PHP_BIN /usr/local/bin/wp"

echo "===================================================="
echo "     VALKEY OBJECT CACHE MANAGER - $SELECTED_DOMAIN"
echo "===================================================="

if [ ! -f "$ROOT/wp-config.php" ]; then
    echo "[FAIL] WordPress not found at $ROOT"
    read -p "Press Enter..."; exit 1
fi

if [ ! -x "$PHP_BIN" ]; then
    echo "[FAIL] PHP binary not found: $PHP_BIN"
    read -p "Press Enter..."; exit 1
fi

if ! command -v valkey-cli >/dev/null 2>&1; then
    echo "[FAIL] Valkey not installed. Install via Cache Manager > Valkey Server."
    read -p "Press Enter..."; exit 1
fi

# Stop Redis if running to avoid conflict
if systemctl is-active --quiet redis 2>/dev/null; then
    echo "[INFO] Stopping Redis to avoid conflict..."
    systemctl stop redis && systemctl disable redis
fi

if ! systemctl is-active --quiet valkey; then
    echo "Starting Valkey..."
    systemctl start valkey
fi

if ! valkey-cli ping 2>/dev/null | grep -qi pong; then
    echo "[FAIL] Valkey not responding!"
    read -p "Press Enter..."; exit 1
fi
echo "[OK] Valkey is running"

# PHP redis extension
if ! "$PHP_BIN" -m 2>/dev/null | grep -qi redis; then
    echo "Installing PHP redis extension..."
    dnf install -y "php${PHP_SHORT}-php-pecl-redis" >/dev/null 2>&1
    systemctl restart "php${PHP_SHORT}-php-fpm"
fi

echo ""
echo "1) Enable Valkey Object Cache"
echo "2) Disable Valkey Object Cache"
echo "3) Flush Valkey Cache"
echo "4) Cache Status"
echo "0) Cancel"
echo "----------------------------------------------------"
read -p "Select: " OPT

WP_CONFIG="$ROOT/wp-config.php"

add_wp_define(){
    local KEY=$1 VAL=$2
    # Remove old define to avoid duplicates, then add fresh
    sed -i "/define('$KEY'/d" "$WP_CONFIG"
    sed -i "/That's all, stop editing/i define('$KEY', $VAL);" "$WP_CONFIG"
}

case $OPT in
1)
    echo "Installing redis-cache plugin..."
    $WP_CMD plugin install redis-cache --activate --path="$ROOT" 2>/dev/null

    echo "Configuring wp-config.php..."

    # Remove old password define if exists (from old version)
    sed -i "/define('WP_REDIS_PASSWORD'/d" "$WP_CONFIG"

    add_wp_define "WP_REDIS_HOST"         "'127.0.0.1'"
    add_wp_define "WP_REDIS_PORT"         "6379"
    add_wp_define "WP_REDIS_CLIENT"       "'phpredis'"
    add_wp_define "WP_REDIS_PREFIX"       "'${SELECTED_DOMAIN}:'"
    add_wp_define "WP_REDIS_TIMEOUT"      "1"
    add_wp_define "WP_REDIS_READ_TIMEOUT" "1"

    rm -f "$ROOT/wp-content/object-cache.php"
    $WP_CMD redis enable --path="$ROOT" 2>/dev/null

    valkey-cli FLUSHALL >/dev/null 2>&1
    systemctl restart "php${PHP_SHORT}-php-fpm"
    systemctl reload nginx

    echo ""
    STATUS=$($WP_CMD redis status --path="$ROOT" 2>/dev/null)
    echo "$STATUS"

    echo ""
    if echo "$STATUS" | grep -qi "connected"; then
        echo "[OK] Valkey Object Cache ENABLED for $SELECTED_DOMAIN"
    else
        echo "[WARN] Cache not connected. Check logs."
    fi
    ;;
2)
    $WP_CMD redis disable --path="$ROOT" 2>/dev/null
    sed -i "/define('WP_REDIS_/d" "$WP_CONFIG"
    echo "[OK] Valkey Object Cache disabled"
    ;;
3)
    valkey-cli FLUSHALL 2>/dev/null && echo "[OK] Valkey flushed"
    $WP_CMD cache flush --path="$ROOT" 2>/dev/null
    ;;
4)
    $WP_CMD redis status --path="$ROOT" 2>/dev/null
    echo ""
    echo "Valkey memory: $(valkey-cli info memory 2>/dev/null | grep used_memory_human | cut -d: -f2)"
    ;;
0) exit 0 ;;
*) echo "Invalid option" ;;
esac

echo ""
read -p "Press Enter..."
