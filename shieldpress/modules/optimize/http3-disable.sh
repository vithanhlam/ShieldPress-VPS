#!/bin/bash
declare -F sp_header >/dev/null || source "${BASE_DIR:-/opt/shieldpress}/core/ui.sh"

CONF="/etc/nginx/conf.d/shieldpress-http3.conf"

sp_title 'Disable HTTP/3 (QUIC)'

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
    sp_title 'HTTP/3 Disabled Successfully'
else
    echo "[ERROR] Nginx config error, rolling back..."
    mv "${CONF}.bak" "$CONF"
    nginx -t && systemctl reload nginx
fi

read -p "Press Enter..."
