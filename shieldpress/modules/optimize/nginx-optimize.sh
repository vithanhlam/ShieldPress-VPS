#!/bin/bash

NGINX_CONF="/etc/nginx/nginx.conf"
PERF_CONF="/etc/nginx/conf.d/shieldpress-performance.conf"
BACKUP="/etc/nginx/nginx.conf.bak.$(date +%s)"
CPU=$(nproc)
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

echo "===================================================="
echo "              NGINX OPTIMIZER"
echo "===================================================="
echo "CPU cores: $CPU | RAM: ${TOTAL_RAM}MB"
echo ""

# ================================================
# BACKUP
# ================================================

cp "$NGINX_CONF" "$BACKUP"
PERF_BACKUP=""
if [ -f "$PERF_CONF" ]; then
    PERF_BACKUP="${PERF_CONF}.bak.$(date +%s)"
    cp "$PERF_CONF" "$PERF_BACKUP"
fi

# ================================================
# NGINX.CONF - worker tuning
# ================================================

sed -i "s/^worker_processes.*/worker_processes auto;/" "$NGINX_CONF"

WORKER_CONN=$((CPU * 4096))
sed -i '/worker_connections/d' "$NGINX_CONF"
sed -i "/events {/a \    worker_connections $WORKER_CONN;" "$NGINX_CONF"

grep -q "worker_rlimit_nofile" "$NGINX_CONF" || \
    sed -i '1i worker_rlimit_nofile 100000;' "$NGINX_CONF"

# multi_accept
if ! grep -q "multi_accept" "$NGINX_CONF"; then
    sed -i "/worker_connections/a \    multi_accept on;" "$NGINX_CONF"
fi

# use epoll
if ! grep -q "use epoll" "$NGINX_CONF"; then
    sed -i "/events {/a \    use epoll;" "$NGINX_CONF"
fi

# Ensure core directives in nginx.conf http block
for DIRECTIVE in "sendfile on" "tcp_nopush on" "tcp_nodelay on" "keepalive_timeout 65"; do
    KEY=$(echo "$DIRECTIVE" | awk '{print $1}')
    if ! grep -q "^\s*${KEY}" "$NGINX_CONF"; then
        sed -i "/http {/a \    ${DIRECTIVE};" "$NGINX_CONF"
    fi
done

ok "nginx.conf tuned (workers=auto, connections=$WORKER_CONN)"

# ================================================
# PERFORMANCE CONF - full rewrite
# ================================================

# open_file_cache based on RAM
if [ "$TOTAL_RAM" -ge 4096 ]; then
    FILE_CACHE_MAX=50000
elif [ "$TOTAL_RAM" -ge 2048 ]; then
    FILE_CACHE_MAX=20000
else
    FILE_CACHE_MAX=10000
fi

# Keep current client_max_body_size if already set
CURRENT_BODY_SIZE="1024M"
if [ -f "$PERF_CONF" ] && grep -q "client_max_body_size" "$PERF_CONF"; then
    CURRENT_BODY_SIZE=$(grep "client_max_body_size" "$PERF_CONF" | awk '{print $2}' | tr -d ';')
fi

cat > "$PERF_CONF" <<EOF
# ====================================================
# ShieldPress Nginx Performance Config
# Auto-tuned for ${TOTAL_RAM}MB RAM / ${CPU} CPU cores
# ====================================================

# --- Connection Tuning ---
keepalive_requests  1000;
reset_timedout_connection on;

# --- Buffer Tuning ---
client_body_buffer_size    128k;
client_header_buffer_size  4k;
large_client_header_buffers 4 32k;

# --- Hash Tables ---
types_hash_max_size       2048;
server_names_hash_max_size 2048;
server_names_hash_bucket_size 128;

# --- File Descriptor Cache ---
open_file_cache          max=${FILE_CACHE_MAX} inactive=60s;
open_file_cache_valid    30s;
open_file_cache_min_uses 2;
open_file_cache_errors   on;

# --- Gzip Compression ---
gzip              on;
gzip_comp_level   5;
gzip_min_length   256;
gzip_vary         on;
gzip_proxied      any;
gzip_buffers      16 8k;
gzip_http_version 1.1;
gzip_types
    text/plain
    text/css
    text/javascript
    text/xml
    application/javascript
    application/json
    application/xml
    application/xml+rss
    application/rss+xml
    application/atom+xml
    application/vnd.ms-fontobject
    application/x-font-ttf
    font/opentype
    image/svg+xml;

# --- Upload Limit ---
client_max_body_size ${CURRENT_BODY_SIZE};

# --- Timeouts ---
client_body_timeout   300;
client_header_timeout 60;
send_timeout          300;

# --- Upstream Defaults ---
proxy_connect_timeout 60s;
proxy_send_timeout    300s;
proxy_read_timeout    300s;
fastcgi_connect_timeout 300s;
fastcgi_send_timeout    300s;
fastcgi_read_timeout    300s;
EOF

ok "Performance conf rebuilt (open_file_cache=$FILE_CACHE_MAX, keepalive=1000)"

# ================================================
# TEST & RELOAD
# ================================================

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    echo ""
    ok "Nginx fully optimized!"
else
    warn "Nginx config error, rolling back..."
    cp "$BACKUP" "$NGINX_CONF"
    [ -n "$PERF_BACKUP" ] && cp "$PERF_BACKUP" "$PERF_CONF"
    nginx -t && systemctl reload nginx
fi

read -p "Press Enter..."
