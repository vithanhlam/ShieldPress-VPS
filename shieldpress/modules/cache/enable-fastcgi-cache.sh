#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

CLEAN_DOMAIN=$(echo "$SELECTED_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
CACHE_CONF="/etc/nginx/conf.d/shieldpress-cache.conf"
NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
CACHE_ZONE_CONF="/etc/nginx/conf.d/cache-zone-${CLEAN_DOMAIN}.conf"
CACHE_DIR="/var/cache/nginx/${CLEAN_DOMAIN}"
CACHE_ZONE="SHIELDPRESS_${CLEAN_DOMAIN}"

echo "===================================================="
echo "        ENABLE FASTCGI CACHE - $SELECTED_DOMAIN"
echo "===================================================="

if [ ! -f "$NGINX_CONF" ]; then
    echo "[FAIL] Nginx config not found: $NGINX_CONF"
    read -p "Press Enter..."; exit 1
fi

# ============================================================
# CHECK: Đã có cache rules trong nginx conf chưa?
# ============================================================
if grep -q "fastcgi_cache" "$NGINX_CONF" 2>/dev/null; then
    echo "[INFO] Cache rules already in nginx conf"

    if grep -q "fastcgi_cache_valid" "$NGINX_CONF" 2>/dev/null; then
        sed -i 's/^[[:space:]]*fastcgi_cache_valid.*/        fastcgi_cache_valid  200 301 302 6h;/' "$NGINX_CONF"
        echo "[OK] Cache TTL set to 6h"
    fi

    # Đảm bảo cache dir tồn tại
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR"
        chown nginx:nginx "$CACHE_DIR"
        chmod 755 "$CACHE_DIR"
        echo "[OK] Cache dir created: $CACHE_DIR"
    fi

    # Đảm bảo cache zone conf tồn tại
    if [ ! -f "$CACHE_ZONE_CONF" ]; then
        TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
        CACHE_MAX=$((TOTAL_RAM / 4))
        [ "$CACHE_MAX" -lt 512  ] && CACHE_MAX=512
        [ "$CACHE_MAX" -gt 2048 ] && CACHE_MAX=2048

        cat > "$CACHE_ZONE_CONF" << ZEOF
# Cache zone for: $SELECTED_DOMAIN
fastcgi_cache_path ${CACHE_DIR} levels=1:2 keys_zone=${CACHE_ZONE}:10m inactive=60m max_size=${CACHE_MAX}m;
ZEOF
        echo "[OK] Cache zone config created: $CACHE_ZONE"
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        echo ""
        echo "[OK] FastCGI Cache ENABLED for $SELECTED_DOMAIN"
        echo "     Cache dir : $CACHE_DIR"
        echo "     Cache zone: $CACHE_ZONE"
    else
        echo "[FAIL] Nginx config error:"
        nginx -t
    fi
    read -p "Press Enter..."; exit 0
fi

# ============================================================
# ENABLE: Domain không có cache rules (đã bị disable trước đó)
# ============================================================

# Tạo thư mục cache riêng cho domain
mkdir -p "$CACHE_DIR"
chown nginx:nginx "$CACHE_DIR"
chmod 755 "$CACHE_DIR"

# Global skip cache maps (nếu chưa có)
if [ ! -f "$CACHE_CONF" ] || ! grep -q "skip_cache" "$CACHE_CONF" 2>/dev/null; then
    echo "Adding global FastCGI cache maps..."
    cat > "$CACHE_CONF" << 'NGEOF'
# ====================================================
# ShieldPress Per-Domain FastCGI Cache
# ====================================================

map $http_cookie $skip_cache {
    default 0;
    ~*wordpress_logged_in      1;
    ~*comment_author           1;
    ~*woocommerce_items_in_cart 1;
    ~*wp-postpass              1;
}

map $request_uri $skip_uri {
    default 0;
    ~*/wp-admin/   1;
    ~*/wp-login    1;
    ~*/cart        1;
    ~*/checkout    1;
    ~*/my-account  1;
}

map "${skip_cache}${skip_uri}" $bypass_cache {
    default 0;
    ~1      1;
}
NGEOF
fi

# Tạo cache zone riêng cho domain
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
CACHE_MAX=$((TOTAL_RAM / 4))
[ "$CACHE_MAX" -lt 512  ] && CACHE_MAX=512
[ "$CACHE_MAX" -gt 2048 ] && CACHE_MAX=2048

cat > "$CACHE_ZONE_CONF" << ZEOF
# Cache zone for: $SELECTED_DOMAIN
fastcgi_cache_path ${CACHE_DIR} levels=1:2 keys_zone=${CACHE_ZONE}:10m inactive=60m max_size=${CACHE_MAX}m;
ZEOF

echo "[OK] Cache zone created: $CACHE_ZONE (max ${CACHE_MAX}MB)"

# Backup nginx conf trước khi sửa
NGINX_BAK="${NGINX_CONF}.bak.$(date +%s)"
cp "$NGINX_CONF" "$NGINX_BAK"

echo "Injecting FastCGI cache rules..."

# Inject sau fastcgi_buffer_size (cuối block fastcgi settings)
# Nếu không tìm thấy, inject sau fastcgi_pass đầu tiên
INJECT_LINE=$(grep -n 'fastcgi_buffer_size' "$NGINX_CONF" | head -1 | cut -d: -f1)
if [ -z "$INJECT_LINE" ]; then
    INJECT_LINE=$(grep -n 'fastcgi_pass' "$NGINX_CONF" | head -1 | cut -d: -f1)
fi

if [ -z "$INJECT_LINE" ]; then
    echo "[FAIL] No fastcgi_pass found in $NGINX_CONF"
    cp "$NGINX_BAK" "$NGINX_CONF"
    rm -f "$CACHE_ZONE_CONF" "$NGINX_BAK"
    read -p "Press Enter..."; exit 1
fi

sed -i "${INJECT_LINE}a\\
\\
        set \$skip_cache 0;\\
        if (\$request_method = POST)               { set \$skip_cache 1; }\\
        if (\$request_uri ~* \"/wp-admin/\")          { set \$skip_cache 1; }\\
        if (\$request_uri ~* \"/wp-login.php\")       { set \$skip_cache 1; }\\
        if (\$http_cookie ~* \"wordpress_logged_in\") { set \$skip_cache 1; }\\
\\
        fastcgi_cache_bypass \$skip_cache;\\
        fastcgi_no_cache     \$skip_cache;\\
        fastcgi_cache        ${CACHE_ZONE};\\
        fastcgi_cache_key    \"\$scheme\$request_method\$host\$request_uri\";\\
        fastcgi_cache_valid  200 301 302 6h;\\
        add_header X-Cache \$upstream_cache_status;" "$NGINX_CONF"

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    rm -f "$NGINX_BAK"
    echo ""
    echo "[OK] FastCGI Cache ENABLED for $SELECTED_DOMAIN"
    echo "     Cache dir : $CACHE_DIR"
    echo "     Cache zone: $CACHE_ZONE"
else
    echo "[FAIL] Nginx config error, rolling back..."
    nginx -t
    cp "$NGINX_BAK" "$NGINX_CONF"
    rm -f "$CACHE_ZONE_CONF"
    nginx -t && systemctl reload nginx
    rm -f "$NGINX_BAK"
fi

read -p "Press Enter..."
