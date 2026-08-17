#!/bin/bash

echo "===================================================="
echo "            CLEAR ALL CACHE (GLOBAL)"
echo "===================================================="
echo ""

# OPcache - restart tất cả PHP-FPM
echo "Clearing OPcache..."
for v in 81 82 83 84; do
    SVC="php${v}-php-fpm"
    systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
    systemctl is-active --quiet "$SVC" || continue
    systemctl restart "$SVC" 2>/dev/null && echo "[OK] php${v}-php-fpm restarted"
done

# Valkey
echo "Flushing Valkey..."
if valkey-cli ping >/dev/null 2>&1; then
    valkey-cli FLUSHALL >/dev/null 2>&1 && echo "[OK] Valkey flushed"
else
    echo "[INFO] Valkey not running"
fi

# FastCGI cache - xóa theo từng domain
echo "Clearing FastCGI cache..."
CLEARED=0
if [ -d /var/cache/nginx ]; then
    for DOMAIN_CACHE in /var/cache/nginx/*/; do
        [ -d "$DOMAIN_CACHE" ] || continue
        DOMAIN_NAME=$(basename "$DOMAIN_CACHE")
        find "$DOMAIN_CACHE" -type f -delete 2>/dev/null
        echo "[OK] Cache cleared: $DOMAIN_NAME"
        CLEARED=$((CLEARED + 1))
    done

    # Fallback: xóa file rời ở thư mục gốc (cache kiểu cũ)
    LOOSE_FILES=$(find /var/cache/nginx -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [ "$LOOSE_FILES" -gt 0 ]; then
        find /var/cache/nginx -maxdepth 1 -type f -delete 2>/dev/null
        echo "[OK] Legacy shared cache cleared ($LOOSE_FILES files)"
    fi

    [ "$CLEARED" -eq 0 ] && [ "$LOOSE_FILES" -eq 0 ] && echo "[INFO] No cache data found"
fi

# Reload nginx
systemctl reload nginx 2>/dev/null && echo "[OK] Nginx reloaded"

echo ""
echo "[OK] All cache layers cleared ($CLEARED domains)."
read -p "Press Enter..."
