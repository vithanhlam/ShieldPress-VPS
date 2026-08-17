#!/bin/bash
source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

# ------------------------------------------------
# Fix: Luôn tính lại ROOT từ DOMAIN_PATH
# domain.env có thể ghi đè ROOT bằng giá trị cũ/sai
# ------------------------------------------------
ROOT="$DOMAIN_PATH/public_html"

PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $CLEAN_DOMAIN $PHP_BIN /usr/local/bin/wp"

# ------------------------------------------------
# Kiểm tra WordPress thực sự tồn tại
# ------------------------------------------------

if [ ! -f "$ROOT/wp-config.php" ]; then
    echo ""
    echo "ERROR: WordPress not found at $ROOT"
    echo "Please install WordPress first (WordPress Manager > Install WordPress)"
    echo ""
    read -p "Press Enter..."
    exit 1
fi

# Kiểm tra PHP binary
if [ ! -x "$PHP_BIN" ]; then
    echo "ERROR: PHP binary not found: $PHP_BIN"
    read -p "Press Enter..."
    exit 1
fi

echo ""
echo "===================================================="
echo "  WordPress Update - $SELECTED_DOMAIN"
echo "===================================================="
echo "Path : $ROOT"
echo "PHP  : $PHP_VERSION"
echo "===================================================="
echo ""
echo "1) Update Core"
echo "2) Update Plugins"
echo "3) Update Themes"
echo "4) Update All"
echo "0) Cancel"
echo "----------------------------------------------------"
read -p "Select: " opt

case $opt in
1)
    echo "Updating WordPress core..."
    $WP_CMD core update --path="$ROOT"
    ;;
2)
    echo "Updating plugins..."
    $WP_CMD plugin update --all --path="$ROOT"
    ;;
3)
    echo "Updating themes..."
    $WP_CMD theme update --all --path="$ROOT"
    ;;
4)
    echo "Updating core..."
    $WP_CMD core update --path="$ROOT"
    echo "Updating plugins..."
    $WP_CMD plugin update --all --path="$ROOT"
    echo "Updating themes..."
    $WP_CMD theme update --all --path="$ROOT"
    ;;
0)
    echo "Cancelled."
    exit 0
    ;;
*)
    echo "Invalid option"
    read -p "Press Enter..."
    exit 1
    ;;
esac

# ------------------------------------------------
# Smart Cache Purge (Per-Domain)
# ------------------------------------------------

echo ""
echo "Smart Purging cache for $SELECTED_DOMAIN..."

# WP object cache
$WP_CMD cache flush --path="$ROOT" 2>/dev/null && echo "[OK] WP cache flushed"

# Redis / Valkey object cache
$WP_CMD redis flush --path="$ROOT" 2>/dev/null || true

# FastCGI cache - CHỈ xóa cache của domain này
CACHE_DIR="/var/cache/nginx/${CLEAN_DOMAIN}"
if [ -d "$CACHE_DIR" ]; then
    find "$CACHE_DIR" -type f -delete 2>/dev/null
    echo "[OK] FastCGI cache cleared ($SELECTED_DOMAIN only)"
else
    # Fallback cho cache kiểu cũ
    if [ -d "/var/cache/nginx" ]; then
        find /var/cache/nginx -maxdepth 1 -type f -delete 2>/dev/null
        echo "[OK] Legacy shared cache cleared"
    fi
fi

# Reload PHP-FPM để clear OPcache
systemctl reload php${PHP_SHORT}-php-fpm 2>/dev/null && echo "[OK] OPcache reloaded"

echo ""
echo "===================================================="
echo "Update complete! - $SELECTED_DOMAIN"
echo "===================================================="

read -p "Press Enter..."
