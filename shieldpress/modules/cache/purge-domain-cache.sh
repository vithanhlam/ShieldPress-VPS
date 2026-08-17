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
CLEAN_DOMAIN=$(echo "$SELECTED_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')

echo "===================================================="
echo "          PURGE CACHE - $SELECTED_DOMAIN"
echo "===================================================="
echo ""

# 1. FastCGI cache - CHỈ xóa cache của domain này
CACHE_DIR="/var/cache/nginx/${CLEAN_DOMAIN}"
if [ -d "$CACHE_DIR" ]; then
    find "$CACHE_DIR" -type f -delete 2>/dev/null
    echo "[OK] FastCGI cache cleared ($CACHE_DIR)"
else
    # Fallback: nếu dùng cache chung kiểu cũ
    if [ -d "/var/cache/nginx" ] && grep -q "fastcgi_cache SHIELDPRESS;" "/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf" 2>/dev/null; then
        find /var/cache/nginx -type f -delete 2>/dev/null
        echo "[WARN] Legacy shared cache cleared (consider re-enabling cache for per-domain isolation)"
    else
        echo "[INFO] No FastCGI cache directory for this domain"
    fi
fi

# 2. Valkey object cache - flush chỉ WP cache, không FLUSHALL
if valkey-cli ping >/dev/null 2>&1; then
    # Dùng WP-CLI redis flush thay vì FLUSHALL toàn bộ Valkey
    if [ -x "$PHP_BIN" ] && [ -f "$ROOT/wp-config.php" ]; then
        $WP_CMD redis flush --path="$ROOT" 2>/dev/null && echo "[OK] Valkey object cache flushed (per-domain)" || {
            # Fallback nếu WP redis flush không hoạt động
            valkey-cli FLUSHDB >/dev/null 2>&1
            echo "[OK] Valkey cache flushed (FLUSHDB)"
        }
    else
        valkey-cli FLUSHDB >/dev/null 2>&1
        echo "[OK] Valkey cache flushed (FLUSHDB)"
    fi
fi

# 3. WP object cache
if [ -x "$PHP_BIN" ] && [ -f "$ROOT/wp-config.php" ]; then
    $WP_CMD cache flush --path="$ROOT" 2>/dev/null && echo "[OK] WP object cache flushed"
fi

# 4. OPcache - restart PHP-FPM (chỉ version của domain này)
SVC="php${PHP_SHORT}-php-fpm"
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    systemctl reload "$SVC" && echo "[OK] OPcache cleared (PHP-FPM reloaded)"
fi

echo ""
echo "[OK] All cache layers purged for $SELECTED_DOMAIN"
echo "     Other domains NOT affected."
read -p "Press Enter..."
