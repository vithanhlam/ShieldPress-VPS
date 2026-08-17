#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

CLEAN_DOMAIN=$(echo "$SELECTED_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
CACHE_ZONE_CONF="/etc/nginx/conf.d/cache-zone-${CLEAN_DOMAIN}.conf"
CACHE_DIR="/var/cache/nginx/${CLEAN_DOMAIN}"

echo "===================================================="
echo "       DISABLE FASTCGI CACHE - $SELECTED_DOMAIN"
echo "===================================================="

if [ ! -f "$NGINX_CONF" ]; then
    echo "[FAIL] Nginx config not found: $NGINX_CONF"
    read -p "Press Enter..."; exit 1
fi

if ! grep -q "fastcgi_cache" "$NGINX_CONF"; then
    echo "FastCGI cache not enabled for $SELECTED_DOMAIN"
    read -p "Press Enter..."; exit 0
fi

# Backup nginx conf trước khi sửa
NGINX_BAK="${NGINX_CONF}.bak.$(date +%s)"
cp "$NGINX_CONF" "$NGINX_BAK"

# Xóa TẤT CẢ cache-related rules (hỗ trợ cả format template và format inject)
sed -i '/set \$skip_cache/d'                  "$NGINX_CONF"
sed -i '/\$request_method = POST.*skip_cache/d' "$NGINX_CONF"
sed -i '/\$request_uri.*skip_cache/d'          "$NGINX_CONF"
sed -i '/\$http_cookie.*skip_cache/d'          "$NGINX_CONF"
sed -i '/fastcgi_cache_bypass/d'              "$NGINX_CONF"
sed -i '/fastcgi_no_cache/d'                  "$NGINX_CONF"
sed -i '/fastcgi_cache_key/d'                 "$NGINX_CONF"
sed -i '/fastcgi_cache_valid/d'               "$NGINX_CONF"
sed -i '/fastcgi_cache /d'                    "$NGINX_CONF"
sed -i '/X-Cache.*upstream_cache_status/d'    "$NGINX_CONF"

# Xóa dòng trống thừa (nhiều dòng trống liên tiếp → 1 dòng)
sed -i '/^$/N;/^\n$/d' "$NGINX_CONF"

# Test nginx TRƯỚC khi xóa zone conf (vì conf đã không còn reference zone)
if nginx -t 2>/dev/null; then
    systemctl reload nginx

    # Xóa cache zone config
    if [ -f "$CACHE_ZONE_CONF" ]; then
        rm -f "$CACHE_ZONE_CONF"
        echo "[OK] Cache zone config removed"
    fi

    # Xóa cache data
    if [ -d "$CACHE_DIR" ]; then
        rm -rf "$CACHE_DIR"
        echo "[OK] Cache data cleared: $CACHE_DIR"
    fi

    # Reload lần nữa sau khi xóa zone conf
    nginx -t 2>/dev/null && systemctl reload nginx

    echo ""
    echo "[OK] FastCGI Cache DISABLED for $SELECTED_DOMAIN"
    rm -f "$NGINX_BAK"
else
    echo "[FAIL] Nginx config error, rolling back..."
    nginx -t
    cp "$NGINX_BAK" "$NGINX_CONF"
    nginx -t && systemctl reload nginx
    rm -f "$NGINX_BAK"
fi

read -p "Press Enter..."