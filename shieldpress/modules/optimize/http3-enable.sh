#!/bin/bash
declare -F sp_header >/dev/null || source "${BASE_DIR:-/opt/shieldpress}/core/ui.sh"

CONF="/etc/nginx/conf.d/shieldpress-http3.conf"

sp_title 'Enable HTTP/3 (QUIC)'

if ! nginx -V 2>&1 | grep -q http_v3_module; then
    echo "[WARN] HTTP/3 module not found in Nginx!"
    echo "Nginx mainline from nginx.org includes HTTP/3 by default."
    read -p "Press Enter..."
    exit 1
fi

if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'NGEOF'
# ShieldPress HTTP3 CONFIG
add_header Alt-Svc 'h3=":443"; ma=86400' always;
quic_retry on;
ssl_protocols TLSv1.2 TLSv1.3;
NGEOF
    echo "[OK] HTTP/3 config created"
else
    echo "[OK] HTTP/3 config already exists"
fi

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo ""
    sp_title 'HTTP/3 Enabled Successfully'
else
    echo "[ERROR] Nginx config test failed, HTTP/3 NOT enabled"
fi

read -p "Press Enter..."
