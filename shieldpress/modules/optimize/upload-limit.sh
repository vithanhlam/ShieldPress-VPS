#!/bin/bash

PERF_CONF="/etc/nginx/conf.d/shieldpress-performance.conf"
PHP_VERSIONS=("81" "82" "83" "84")

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

set_limit(){
    LIMIT=$1
    echo "Setting upload limit to ${LIMIT}..."

    # NGINX global - sửa trong shieldpress-performance.conf
    if [ -f "$PERF_CONF" ]; then
        if grep -q "client_max_body_size" "$PERF_CONF"; then
            sed -i "s/client_max_body_size.*/client_max_body_size ${LIMIT};/" "$PERF_CONF"
        else
            echo "client_max_body_size ${LIMIT};" >> "$PERF_CONF"
        fi
        rm -f /etc/nginx/conf.d/shieldpress-upload.conf
        ok "Nginx global upload limit set to ${LIMIT}"
    else
        cat > /etc/nginx/conf.d/shieldpress-upload.conf <<NGEOF
client_max_body_size ${LIMIT};
NGEOF
        ok "Nginx upload limit set to ${LIMIT}"
    fi

    # NGINX per-domain - update all domain configs
    for DOMAIN_CONF in /etc/nginx/conf.d/*.conf; do
        [ -f "$DOMAIN_CONF" ] || continue
        [[ "$DOMAIN_CONF" == *shieldpress-* ]] && continue
        [[ "$DOMAIN_CONF" == *cache-zone-* ]] && continue
        if grep -q "client_max_body_size" "$DOMAIN_CONF"; then
            sed -i "s/client_max_body_size.*/client_max_body_size ${LIMIT};/" "$DOMAIN_CONF"
        fi
    done
    ok "Per-domain nginx configs updated"

    # PHP - update php.ini + ALL pool configs (www.conf + per-domain pools)
    for v in "${PHP_VERSIONS[@]}"; do
        PHP_INI="/etc/opt/remi/php${v}/php.ini"
        [ -f "$PHP_INI" ] || continue

        sed -i "s/^upload_max_filesize.*/upload_max_filesize = ${LIMIT}/" "$PHP_INI"
        sed -i "s/^post_max_size.*/post_max_size = ${LIMIT}/"             "$PHP_INI"
        sed -i "s/^memory_limit.*/memory_limit = 512M/"                   "$PHP_INI"

        # Update ALL pool configs (www.conf + per-domain pools)
        for POOL_CONF in /etc/opt/remi/php${v}/php-fpm.d/*.conf; do
            [ -f "$POOL_CONF" ] || continue
            sed -i "s/php_admin_value\[upload_max_filesize\].*/php_admin_value[upload_max_filesize] = ${LIMIT}/" "$POOL_CONF"
            sed -i "s/php_admin_value\[post_max_size\].*/php_admin_value[post_max_size] = ${LIMIT}/"             "$POOL_CONF"
        done

        systemctl restart php${v}-php-fpm 2>/dev/null && \
            ok "PHP${v} updated" || warn "PHP${v} restart failed"
    done

    # Test and reload nginx
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Nginx reloaded"
    else
        warn "Nginx config test failed:"
        nginx -t
    fi

    echo ""
    echo "================================"
    echo "Upload limit set to ${LIMIT}"
    echo "================================"
    read -p "Press Enter..."
}

while true; do
clear
echo "================================================"
echo "            UPLOAD LIMIT MANAGER"
echo "================================================"
echo "1) 64MB"
echo "2) 128MB"
echo "3) 256MB"
echo "4) 512MB"
echo "5) 1GB"
echo "6) 2GB"
echo "7) 5GB"
echo "8) 10GB"
echo "9) 20GB"
echo "0) Back"
echo "------------------------------------------------"
read -p "Select: " opt

case $opt in
1) set_limit "64M"   ;;
2) set_limit "128M"  ;;
3) set_limit "256M"  ;;
4) set_limit "512M"  ;;
5) set_limit "1024M" ;;
6) set_limit "2048M" ;;
7) set_limit "5120M" ;;
8) set_limit "10240M" ;;
9) set_limit "20480M" ;;
0) exit ;;
*) echo "Invalid option"; sleep 1 ;;
esac
done
