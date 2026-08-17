#!/bin/bash

PHP_VERSIONS=("81" "82" "83" "84")

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

echo "===================================================="
echo "              ENABLE PHP JIT"
echo "===================================================="

for v in "${PHP_VERSIONS[@]}"; do
    INI="/etc/opt/remi/php${v}/php.d/10-opcache.ini"
    SVC="php${v}-php-fpm"

    [ -f "$INI" ] || continue

    # Xóa dòng cũ tránh duplicate
    sed -i '/^opcache\.jit=/d'             "$INI"
    sed -i '/^opcache\.jit_buffer_size=/d' "$INI"
    sed -i '/^opcache\.enable=/d'          "$INI"

    cat >> "$INI" <<JITEOF
opcache.enable=1
opcache.jit=1255
opcache.jit_buffer_size=128M
JITEOF

    systemctl restart "$SVC" 2>/dev/null && \
        ok "PHP${v} JIT enabled" || warn "PHP${v} restart failed"
done

echo ""
echo "PHP JIT configuration complete."
read -p "Press Enter..."
