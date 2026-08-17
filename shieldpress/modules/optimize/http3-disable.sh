#!/bin/bash

CONF="/etc/nginx/conf.d/shieldpress-http3.conf"

echo "======================================"
echo "         DISABLE HTTP/3 (QUIC)"
echo "======================================"

if [ ! -f "$CONF" ]; then
    echo "HTTP/3 config not found, already disabled."
    read -p "Press Enter..."
    exit 0
fi

cp "$CONF" "${CONF}.bak"
sed -i '/Alt-Svc/d'   "$CONF"
sed -i '/quic_retry/d' "$CONF"

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo ""
    echo "======================================"
    echo "HTTP/3 Disabled Successfully"
    echo "======================================"
else
    echo "[ERROR] Nginx config error, rolling back..."
    mv "${CONF}.bak" "$CONF"
    nginx -t && systemctl reload nginx
fi

read -p "Press Enter..."
