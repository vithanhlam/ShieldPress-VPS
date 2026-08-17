#!/bin/bash

DOMAINS_ROOT="/home/domains"
UPLOAD_LIMIT="${SHIELDPRESS_UPLOAD_LIMIT:-1024M}"

ok(){ echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

get_env_value(){
    grep "^$1=" "$2" | cut -d'=' -f2- | tr -d '[:space:]'
}

ensure_server_directive(){
    local conf="$1"
    local key="$2"
    local value="$3"

    if grep -q "^[[:space:]]*${key}[[:space:]]" "$conf"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]].*|    ${key} ${value};|" "$conf"
    else
        sed -i "/server_name/a\\    ${key} ${value};" "$conf"
    fi
}

ensure_after(){
    local conf="$1"
    local key="$2"
    local line="$3"
    local anchor="$4"

    if grep -q "^[[:space:]]*${key}[[:space:]]" "$conf"; then
        sed -i "s|^[[:space:]]*${key}[[:space:]].*|        ${line};|" "$conf"
    else
        sed -i "/${anchor}/a\\        ${line};" "$conf"
    fi
}

ensure_laravel_conf(){
    local conf="$1"

    ensure_server_directive "$conf" "client_max_body_size" "$UPLOAD_LIMIT"
    ensure_server_directive "$conf" "client_body_timeout" "300s"
    ensure_server_directive "$conf" "client_header_timeout" "60s"
    ensure_server_directive "$conf" "send_timeout" "300s"
    ensure_server_directive "$conf" "keepalive_timeout" "65s"

    ensure_after "$conf" "fastcgi_connect_timeout" "fastcgi_connect_timeout 300" "fastcgi_index"
    ensure_after "$conf" "fastcgi_send_timeout" "fastcgi_send_timeout    300" "fastcgi_connect_timeout"
    ensure_after "$conf" "fastcgi_read_timeout" "fastcgi_read_timeout    300" "fastcgi_send_timeout"
    ensure_after "$conf" "fastcgi_buffer_size" "fastcgi_buffer_size 32k" "fastcgi_read_timeout"
    ensure_after "$conf" "fastcgi_buffers" "fastcgi_buffers 16 16k" "fastcgi_buffer_size"
    ensure_after "$conf" "fastcgi_busy_buffers_size" "fastcgi_busy_buffers_size 64k" "fastcgi_buffers"

    grep -q "bootstrap/cache" "$conf" || sed -i '/location ~ \/\./i\\    location ~* ^/(app|bootstrap/cache|config|database|resources|routes|storage|tests|vendor)/ {\n        deny all;\n    }\n' "$conf"
}

ensure_nodejs_conf(){
    local conf="$1"

    ensure_server_directive "$conf" "client_max_body_size" "$UPLOAD_LIMIT"
    ensure_server_directive "$conf" "client_body_timeout" "300s"
    ensure_server_directive "$conf" "client_header_timeout" "60s"
    ensure_server_directive "$conf" "send_timeout" "300s"
    ensure_server_directive "$conf" "keepalive_timeout" "65s"

    ensure_after "$conf" "proxy_connect_timeout" "proxy_connect_timeout 60s" "proxy_cache_bypass"
    ensure_after "$conf" "proxy_send_timeout" "proxy_send_timeout 300s" "proxy_connect_timeout"
    ensure_after "$conf" "proxy_read_timeout" "proxy_read_timeout 300s" "proxy_send_timeout"
    ensure_after "$conf" "proxy_buffering" "proxy_buffering off" "proxy_read_timeout"
    ensure_after "$conf" "proxy_request_buffering" "proxy_request_buffering off" "proxy_buffering"
    ensure_after "$conf" "proxy_redirect" "proxy_redirect off" "proxy_request_buffering"
    ensure_after "$conf" "proxy_max_temp_file_size" "proxy_max_temp_file_size 0" "proxy_redirect"

    grep -q "X-Forwarded-Host" "$conf" || sed -i '/X-Forwarded-Proto/a\\        proxy_set_header X-Forwarded-Host $host;\n        proxy_set_header X-Forwarded-Port $server_port;\n        proxy_set_header X-Forwarded-Server $host;' "$conf"
    grep -q "npm-shrinkwrap" "$conf" || sed -i '/location ~ \/\./i\\    location ~* /(package\\.json|package-lock\\.json|npm-shrinkwrap\\.json|yarn\\.lock|pnpm-lock\\.yaml|\\.env|\\.git|\\.svn) {\n        deny all;\n    }\n' "$conf"
}

echo "===================================================="
echo "        LARAVEL / NODE.JS NGINX TUNER"
echo "===================================================="
echo "Upload limit: $UPLOAD_LIMIT"
echo ""

COUNT=0

for env in "$DOMAINS_ROOT"/*/config/domain.env; do
    [ -f "$env" ] || continue

    DOMAIN=$(get_env_value DOMAIN "$env")
    APP_TYPE=$(get_env_value APP_TYPE "$env")
    CLEAN_DOMAIN=$(basename "$(dirname "$(dirname "$env")")")
    CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

    [ -f "$CONF" ] || continue

    case "$APP_TYPE" in
        laravel)
            cp "$CONF" "${CONF}.bak_nginx_tune_$(date +%s)"
            ensure_laravel_conf "$CONF"
            ok "$DOMAIN Laravel Nginx tuned"
            COUNT=$((COUNT + 1))
            ;;
        nodejs)
            cp "$CONF" "${CONF}.bak_nginx_tune_$(date +%s)"
            ensure_nodejs_conf "$CONF"
            ok "$DOMAIN Node.js Nginx tuned"
            COUNT=$((COUNT + 1))
            ;;
    esac
done

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    ok "Nginx reloaded"
else
    warn "Nginx config test failed. Check backups: /etc/nginx/conf.d/*.bak_nginx_tune_*"
    nginx -t
fi

echo ""
echo "Tuned $COUNT Laravel/Node.js domains."
read -p "Press Enter..."
