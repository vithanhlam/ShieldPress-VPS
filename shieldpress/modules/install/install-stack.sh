#!/bin/bash


# ------------------------------------------------
# ROOT CHECK
# Auto escalate to root nếu chưa phải root
# ------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Not running as root. Trying sudo..."
    exec sudo bash "$0" "$@"
    exit $?
fi

set -e
set -o pipefail
trap 'echo "ERROR at line $LINENO"; exit 1' ERR

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh" 2>/dev/null || true
LOG_DIR="${LOG_DIR:-/var/shieldpress/logs}"
LOG_FILE="$LOG_DIR/install.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a $LOG_FILE) 2>&1

echo "==============================================="
echo "            ShieldPress VPS Stack v5"
echo "==============================================="
echo ""
echo "  WARNING: Installation will take several"
echo "  minutes depending on your server specs."
echo "  Please do NOT close this terminal until"
echo "  the process is fully complete."
echo ""
echo "==============================================="
echo ""

# ------------------------------------------------
# LANGUAGE SELECT
# ------------------------------------------------

msg() { echo "$1"; }
ok()    { echo -e "\e[32m[OK]\e[0m $1"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
fail()  { echo -e "\e[31m[FAIL]\e[0m $1"; }

if [ -f /opt/shieldpress/modules/helpers/nodejs-runtime.sh ]; then
    source /opt/shieldpress/modules/helpers/nodejs-runtime.sh
fi
# ------------------------------------------------
# CREATE VERSION
# ------------------------------------------------

mkdir -p /opt/shieldpress
mkdir -p /etc/shieldpress

if [ ! -f /opt/shieldpress/version.txt ]; then
    echo "1.0.0" > /opt/shieldpress/version.txt
    chmod 644 /opt/shieldpress/version.txt
fi

# ------------------------------------------------
# ROOT CHECK
# ------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    msg "Run as root" "Hãy chạy với quyền root"
    exit 1
fi

# ------------------------------------------------
# OS CHECK
# ------------------------------------------------

source /etc/os-release

if [[ "$ID" != "almalinux" ]]; then
    msg "Only AlmaLinux supported" "Chỉ hỗ trợ AlmaLinux"
    exit 1
fi

ALMA_VERSION=$(echo $VERSION_ID | cut -d'.' -f1)

if [[ "$ALMA_VERSION" != "9" && "$ALMA_VERSION" != "10" ]]; then
    msg "Only AlmaLinux 9 or 10 supported" "Chỉ hỗ trợ AlmaLinux 9 hoặc 10"
    exit 1
fi

msg "Detected AlmaLinux $ALMA_VERSION" "Phát hiện AlmaLinux $ALMA_VERSION"

# ------------------------------------------------
# SET DEFAULT TIMEZONE
# ------------------------------------------------

timedatectl set-timezone Asia/Ho_Chi_Minh || true

# ------------------------------------------------
# FIX LOCALE
# ------------------------------------------------

dnf install -y glibc-langpack-en >/dev/null 2>&1 || true
localectl set-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8

# ------------------------------------------------
# HARDWARE CHECK
# ------------------------------------------------

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)
DISK_FREE=$(df / | awk 'NR==2 {print $4}')

msg "Checking hardware..." "Đang kiểm tra phần cứng..."

echo "RAM       : ${TOTAL_RAM}MB"
echo "CPU Cores : ${CPU_CORES}"
echo "Disk Free : $((DISK_FREE/1024))MB"

if [ "$TOTAL_RAM" -lt 1024 ]; then
    msg "Minimum RAM 1GB required" "Cần tối thiểu 1GB RAM"
    exit 1
fi

if [ "$DISK_FREE" -lt 5242880 ]; then
    msg "Minimum disk 5GB required" "Cần tối thiểu 5GB ổ cứng"
    exit 1
fi



# ------------------------------------------------
# INTERNET CHECK
# ------------------------------------------------

msg "Checking internet..." "Kiểm tra kết nối internet..."

if ! curl -s --connect-timeout 5 https://google.com >/dev/null; then
    msg "No internet connection" "Không có kết nối internet"
    exit 1
fi

# ------------------------------------------------
# BASE PACKAGES
# ------------------------------------------------

dnf clean all
dnf -y install dnf-plugins-core || true
rm -rf /var/cache/dnf

dnf makecache --refresh --setopt=skip_if_unavailable=true -y

# ------------------------------------------------
# FIX SYSTEM PACKAGE MISMATCH (QUAN TRỌNG)
# ------------------------------------------------
echo "[INFO] Ensuring system package consistency..."

dnf distro-sync -y || warn "distro-sync failed, continuing..."

echo "[INFO] Fixing OpenSSH ↔ OpenSSL compatibility..."

dnf reinstall -y openssh-server openssh openssl || {
    echo "[WARN] OpenSSH reinstall failed"
}

SSHD_CONF="/etc/ssh/sshd_config"

systemctl daemon-reexec
systemctl daemon-reload

if ! sshd -t; then
    echo "[FAIL] SSH config invalid → rollback"

    # lấy bản backup mới nhất
    LAST_BACKUP=$(ls -t ${SSHD_CONF}.bak.* 2>/dev/null | head -n1)

    if [ -f "$LAST_BACKUP" ]; then
        cp "$LAST_BACKUP" "$SSHD_CONF"
        systemctl restart sshd
        echo "[OK] SSH rollback applied"
    else
        echo "[CRITICAL] No SSH backup found"
    fi

    exit 1
fi

if ! systemctl restart sshd; then
    echo "[FAIL] SSH restart failed → rollback"

    LAST_BACKUP=$(ls -t ${SSHD_CONF}.bak.* 2>/dev/null | head -n1)

    if [ -f "$LAST_BACKUP" ]; then
        cp "$LAST_BACKUP" "$SSHD_CONF"
        systemctl restart sshd
        echo "[OK] SSH rollback applied"
    fi

    exit 1
fi

ok "SSH fixed after distro-sync"

dnf install -y epel-release --setopt=skip_if_unavailable=true || true

dnf install -y \
    curl wget unzip zip tar git openssl \
    firewalld lsof bc jq which \
    dnf-utils policycoreutils-python-utils || true

dnf install -y nano vim


# ------------------------------------------------
# INITIAL CONFIG
# ------------------------------------------------

CONFIG_FILE="/opt/shieldpress/config.env"

detect_current_ssh_port() {
    local detected_port=""

    detected_port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {
        split($4, address, ":")
        port=address[length(address)]
        if (port ~ /^[0-9]+$/) {
            print port
            exit
        }
    }')

    if [ -z "$detected_port" ] && [ -f /etc/ssh/sshd_config ]; then
        detected_port=$(awk '
            /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
                print $2
                exit
            }
        ' /etc/ssh/sshd_config)
    fi

    echo "${detected_port:-22}"
}

if [ ! -f "$CONFIG_FILE" ]; then
    DEFAULT_SSH_PORT="${SSH_PORT:-$(detect_current_ssh_port)}"

    cat > "$CONFIG_FILE" <<EOF
INSTALL_DATE=$(date +%Y-%m-%d)
SSH_PORT=${DEFAULT_SSH_PORT}
EOF
    chmod 600 "$CONFIG_FILE"

    systemctl enable firewalld >/dev/null 2>&1 || true
    systemctl start firewalld >/dev/null 2>&1 || true
fi

ENV_SSH_PORT="${SSH_PORT:-}"
source "$CONFIG_FILE" 2>/dev/null || true
[ -n "$ENV_SSH_PORT" ] && SSH_PORT="$ENV_SSH_PORT"
SSH_PORT="${SSH_PORT:-$(detect_current_ssh_port)}"

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    warn "Invalid SSH_PORT '$SSH_PORT' in $CONFIG_FILE, using 22"
    SSH_PORT=22
fi

if grep -q "^SSH_PORT=" "$CONFIG_FILE"; then
    sed -i "s/^SSH_PORT=.*/SSH_PORT=$SSH_PORT/" "$CONFIG_FILE"
else
    echo "SSH_PORT=$SSH_PORT" >> "$CONFIG_FILE"
fi

open_ssh_firewall_port() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "firewall-cmd not found, cannot open SSH port $SSH_PORT"
        return 0
    fi

    systemctl enable firewalld >/dev/null 2>&1 || true
    systemctl start firewalld >/dev/null 2>&1 || true

    if [ "$SSH_PORT" = "22" ]; then
        firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    else
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp >/dev/null 2>&1 || true
    fi

    firewall-cmd --reload >/dev/null 2>&1 || true
}

# Open the target SSH port before restarting sshd to avoid locking out remote installs.
open_ssh_firewall_port

# ------------------------------------------------
# CONFIGURE SSH (allow root + password auth)
# ------------------------------------------------
SSHD_CONF="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONF}.bak.$(date +%s)"
cp "$SSHD_CONF" "$SSHD_BACKUP"

sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/'       "$SSHD_CONF"
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$SSHD_CONF"
sed -i "0,/^[[:space:]#]*Port[[:space:]]\+.*/s//Port ${SSH_PORT}/" "$SSHD_CONF"

grep -q "^PermitRootLogin "       "$SSHD_CONF" || echo "PermitRootLogin yes"       >> "$SSHD_CONF"
grep -q "^PasswordAuthentication " "$SSHD_CONF" || echo "PasswordAuthentication yes" >> "$SSHD_CONF"
grep -q "^Port " "$SSHD_CONF" || echo "Port $SSH_PORT" >> "$SSHD_CONF"

# AlmaLinux 9/10: also patch drop-in override if exists
for override in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$override" ] || continue
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/'        "$override"
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$override"
    sed -i "0,/^[[:space:]#]*Port[[:space:]]\+.*/s//Port ${SSH_PORT}/" "$override"
done

if [ "$SSH_PORT" != "22" ] && command -v semanage >/dev/null 2>&1; then
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || true
fi

if sshd -t 2>/dev/null; then
    systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    ok "SSH: PermitRootLogin + PasswordAuthentication enabled (port: $SSH_PORT)"
    rm -f "$SSHD_BACKUP"
else
    warn "SSH config test failed — rolling back"
    cp "$SSHD_BACKUP" "$SSHD_CONF"
    rm -f "$SSHD_BACKUP"
fi

# ------------------------------------------------
# SET ROOT PASSWORD (if not already set)
# ------------------------------------------------
if ! passwd -S root 2>/dev/null | grep -qw "P"; then
    echo "" >/dev/tty
    echo "===============================================" >/dev/tty
    echo "  Root password is not set."                   >/dev/tty
    echo "  Please set a root password to allow SSH"     >/dev/tty
    echo "  login with password authentication."         >/dev/tty
    echo "===============================================" >/dev/tty
    passwd root </dev/tty
fi

# ------------------------------------------------
# NGINX
# ------------------------------------------------

msg "Installing Nginx Mainline..." "Cài đặt Nginx bản mới..."

# Remove old nginx if exists
dnf remove -y nginx nginx-core nginx-filesystem || true
rm -f /etc/yum.repos.d/nginx*.repo

# Add nginx mainline repo
cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$ALMA_VERSION/\$basearch/
enabled=1
gpgcheck=1
gpgkey=https://nginx.org/keys/nginx_signing.key
EOF

dnf clean all
dnf makecache

dnf install -y nginx

echo "[INFO] Re-sync after adding repositories..."
dnf update -y || true

systemctl enable nginx --now

# Prepare nginx directories
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/nginx/snippets
mkdir -p /var/cache/nginx
chown -R nginx:nginx /var/cache/nginx
chmod 755 /var/cache/nginx

# Optimize nginx worker_processes
sed -i "s/^worker_processes.*/worker_processes auto;/" /etc/nginx/nginx.conf

# ------------------------------------------------
# NGINX AUTO TUNING
# ------------------------------------------------

WORKER_CONN=$((CPU_CORES * 4096))

sed -i '/worker_connections/d' /etc/nginx/nginx.conf
sed -i "/events {/a \    worker_connections $WORKER_CONN;" /etc/nginx/nginx.conf

grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf || \
    sed -i '1i worker_rlimit_nofile 100000;' /etc/nginx/nginx.conf

# ------------------------------------------------
# NGINX PERFORMANCE CONFIG
# ------------------------------------------------

rm -f /etc/nginx/conf.d/shieldpress-performance.conf

cat > /etc/nginx/conf.d/shieldpress-performance.conf <<'EOF'
# GZIP COMPRESSION
gzip on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_vary on;
gzip_proxied any;
gzip_types
    text/plain
    text/css
    text/javascript
    application/javascript
    application/json
    application/xml
    application/rss+xml
    image/svg+xml;

# UPLOAD LIMIT
client_max_body_size 128M;
EOF

# ------------------------------------------------
# NGINX STATIC CACHE MAP
# ------------------------------------------------

cat > /etc/nginx/conf.d/shieldpress-static-cache.conf <<'EOF'
map $sent_http_content_type $static_expires {
    default         off;
    text/css        30d;
    application/javascript 30d;
    image/jpeg      30d;
    image/png       30d;
    image/gif       30d;
    image/svg+xml   30d;
    image/webp      30d;
}
EOF


# ------------------------------------------------
# NGINX FASTCGI CACHE (Per-Domain Architecture)
# ------------------------------------------------

rm -f /etc/nginx/conf.d/shieldpress-cache.conf

cat > /etc/nginx/conf.d/shieldpress-cache.conf <<'EOF'
# ====================================================
# ShieldPress Per-Domain FastCGI Cache
# ====================================================
# Mỗi domain có cache_path riêng tại:
#   /var/cache/nginx/<clean_domain>/
# Cache zone được khai báo trong file:
#   /etc/nginx/conf.d/cache-zone-<clean_domain>.conf
# ====================================================

# Global skip cache maps (dùng chung cho tất cả domain)
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
EOF


# ---- TLS/SSL Hardening Snippet ----
mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/ssl-hardening.conf <<'EOF'
# ====================================================
# ShieldPress TLS Hardening
# Include this in SSL server blocks
# ====================================================

# Chỉ cho phép TLS 1.2 + 1.3
ssl_protocols TLSv1.2 TLSv1.3;

# Cipher suite mạnh, ưu tiên server
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

# Session cache & tickets
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

# DH parameters (sẽ được tạo nếu chưa có)
# ssl_dhparam /etc/nginx/ssl/dhparam.pem;
EOF

# Tạo DH parameters (background, mất vài phút)
mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/dhparam.pem ]; then
    openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048 &>/dev/null &
    DHPARAM_PID=$!
    ok "DH parameters generating in background (PID: $DHPARAM_PID)"
fi

ok "TLS hardening snippet created (/etc/nginx/snippets/ssl-hardening.conf)"


# Test and reload nginx
nginx -t && systemctl reload nginx
ok "Nginx configured"



# ------------------------------------------------
# SYSTEM TUNING
# ------------------------------------------------

msg "Applying system tuning..." "Tối ưu hệ thống..."

cat > /etc/security/limits.d/shieldpress.conf <<EOF
* soft nofile 100000
* hard nofile 100000
root soft nofile 100000
root hard nofile 100000
EOF

mkdir -p /etc/systemd/system.conf.d

cat > /etc/systemd/system.conf.d/shieldpress.conf <<EOF
[Manager]
DefaultLimitNOFILE=100000
EOF

systemctl daemon-reexec
systemctl daemon-reload

cat > /etc/sysctl.d/shieldpress.conf <<EOF
# Network
net.core.somaxconn          = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout    = 15
net.ipv4.tcp_tw_reuse       = 1

# File system
fs.file-max = 1000000

# Memory
vm.swappiness         = 10
vm.vfs_cache_pressure = 50
EOF

sysctl --system
ulimit -n 100000
ok "System tuning applied"

# ------------------------------------------------
# FAIL2BAN
# ------------------------------------------------

dnf install -y fail2ban

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2ban started"

# ---- Fail2ban Nginx Jails ----
mkdir -p /etc/fail2ban/jail.d
mkdir -p /etc/fail2ban/filter.d

# Jail: Nginx 4xx flood (bot scan, path traversal)
cat > /etc/fail2ban/jail.d/nginx-4xx.conf <<'EOF'
[nginx-4xx]
enabled  = true
port     = http,https
filter   = nginx-4xx
logpath  = /var/log/nginx/domains/*/access.log
maxretry = 30
findtime = 60
bantime  = 3600
EOF

cat > /etc/fail2ban/filter.d/nginx-4xx.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*" (400|403|404|405|444) .*$
ignoreregex = \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2)
EOF

# Jail: Nginx rate limit (429)
cat > /etc/fail2ban/jail.d/nginx-limit.conf <<'EOF'
[nginx-limit]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/domains/*/error.log
maxretry = 10
findtime = 120
bantime  = 7200
EOF

# WordPress login bruteforce (pre-configured)
cat > /etc/fail2ban/jail.d/wordpress.conf <<'EOF'
[wordpress]
enabled  = true
port     = http,https
filter   = wordpress
logpath  = /var/log/nginx/domains/*/access.log
maxretry = 5
findtime = 600
bantime  = 3600
EOF

cat > /etc/fail2ban/filter.d/wordpress.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*(POST /wp-login\.php|POST /xmlrpc\.php)
ignoreregex =
EOF

systemctl restart fail2ban
ok "Fail2ban jails configured (nginx-4xx, nginx-limit, wordpress)"

# ------------------------------------------------
# MARIADB
# ------------------------------------------------

msg "Installing MariaDB..." "Cài MariaDB..."

dnf install -y mariadb-server

systemctl enable mariadb
systemctl restart mariadb

# MariaDB auto tuning - giới hạn buffer pool tối đa 70% RAM
TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
BUFFER_POOL=$((TOTAL_RAM * 35 / 100))

# Giới hạn tối đa 4096MB để tránh OOM trên server nhỏ
[ "$BUFFER_POOL" -gt 4096 ] && BUFFER_POOL=4096
[ "$BUFFER_POOL" -lt 128 ] && BUFFER_POOL=128

rm -f /etc/my.cnf.d/shieldpress-tuning.cnf
cat > /etc/my.cnf.d/shieldpress-tuning.cnf <<EOF
[mysqld]
innodb_buffer_pool_size=${BUFFER_POOL}M
innodb_log_file_size=256M
innodb_flush_method=O_DIRECT
innodb_flush_log_at_trx_commit=2
max_connections=200
tmp_table_size=64M
max_heap_table_size=64M
EOF

systemctl restart mariadb
ok "MariaDB configured (buffer pool: ${BUFFER_POOL}MB)"


# ------------------------------------------------
# VALKEY
# ------------------------------------------------


msg "Installing Valkey..." "Cài Valkey..."

dnf install -y valkey

# Reload systemd để tránh race condition
systemctl daemon-reload

# Enable service
systemctl enable valkey

# Start lần đầu (retry nếu fail)
if ! systemctl start valkey; then
    echo "[WARN] First start failed, retrying..."
    sleep 2
    systemctl start valkey
fi

# Đảm bảo service đã active
if ! systemctl is-active --quiet valkey; then
    echo "[FAIL] Valkey failed to start"
    journalctl -xeu valkey | tail -n 20
    exit 1
fi

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
MAXMEM=$((TOTAL_RAM / 4))
[ "$MAXMEM" -gt 2048 ] && MAXMEM=2048

# Tạo password ngẫu nhiên
if command -v openssl >/dev/null 2>&1; then
    VALKEY_PASS=$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24) || true
else
    VALKEY_PASS=$(head -c 32 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24) || true
fi

if [ -z "$VALKEY_PASS" ]; then
    VALKEY_PASS=$(date +%s | sha256sum | head -c 24)
fi

echo "[INFO] Configuring Valkey..."

VALKEY_CONF="/etc/valkey/valkey.conf"

# Check file tồn tại
if [ ! -f "$VALKEY_CONF" ]; then
    echo "[FAIL] Valkey config not found: $VALKEY_CONF"
    exit 1
fi

# Backup config
cp "$VALKEY_CONF" "$VALKEY_CONF.bak"

# Clean config cũ (an toàn với set -e)
sed -i '/^\s*bind /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*requirepass /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*maxmemory /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*maxmemory-policy /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*rename-command /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*protected-mode /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*appendonly /d' "$VALKEY_CONF" 2>/dev/null || true
sed -i '/^\s*save /d' "$VALKEY_CONF" 2>/dev/null || true

# Append config mới
cat >> "$VALKEY_CONF" <<EOF

# ---- ShieldPress CONFIG ----
bind 127.0.0.1 ::1
protected-mode yes

maxmemory ${MAXMEM}mb
maxmemory-policy allkeys-lru

appendonly no
save ""

tcp-keepalive 60

rename-command DEBUG   ""
rename-command SHUTDOWN SHIELDPRESS_SHUTDOWN
EOF

# Restart sau khi config
if systemctl restart valkey; then
    echo "[OK] Valkey restarted"
else
    echo "[FAIL] Valkey failed after config"
    journalctl -xeu valkey | tail -n 20
    exit 1
fi

# Lưu password
mkdir -p "$DATA_DIR" || true

echo "VALKEY_PASS=${VALKEY_PASS}" > "$DATA_DIR/.valkey_auth" || {
    echo "[WARN] Cannot write valkey password file"
}

chmod 600 "$DATA_DIR/.valkey_auth" || true

ok "Valkey secured (bind localhost, password set, dangerous commands renamed)"

# ------------------------------------------------
# NODE.JS
# ------------------------------------------------

msg "Installing Node.js..." "Cai Node.js..."

if declare -F install_shieldpress_nodejs >/dev/null 2>&1; then
    install_shieldpress_nodejs
else
    dnf install -y nodejs npm --allowerasing || warn "Node.js/npm install failed"
fi

# ------------------------------------------------
# IMAGEMAGICK
# ------------------------------------------------

msg "Installing ImageMagick..." "Cài đặt ImageMagick..."
dnf install -y ImageMagick ImageMagick-libs
ok "ImageMagick installed"

# ------------------------------------------------
# REMI REPO
# ------------------------------------------------

dnf config-manager --set-enabled crb

if [ "$ALMA_VERSION" = "9" ]; then
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
else
    dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm
fi

# ------------------------------------------------
# PHP INSTALL FUNCTION
# ------------------------------------------------

install_php() {

    VERSION=$1

    msg "Installing PHP ${VERSION}..." "Cài PHP ${VERSION}..."

    dnf install -y \
        php${VERSION} \
        php${VERSION}-php-fpm \
        php${VERSION}-php-mysqlnd \
        php${VERSION}-php-pgsql \
        php${VERSION}-php-opcache \
        php${VERSION}-php-gd \
        php${VERSION}-php-curl \
        php${VERSION}-php-zip \
        php${VERSION}-php-cli \
        php${VERSION}-php-mbstring \
        php${VERSION}-php-xml \
        php${VERSION}-php-intl \
        php${VERSION}-php-bcmath

    # Imagick package naming differs across Remi builds.
    if dnf install -y "php${VERSION}-php-pecl-imagick" --enablerepo=remi >/dev/null 2>&1; then
        ok "PHP${VERSION} imagick installed"
    elif dnf install -y "php${VERSION}-php-pecl-imagick-im6" --enablerepo=remi >/dev/null 2>&1; then
        ok "PHP${VERSION} imagick installed"
    else
        warn "PHP${VERSION} imagick not available, skipping"
    fi

    systemctl enable php${VERSION}-php-fpm

    # ----------------------------------------
    # FIX OPCACHE - bật đúng, enable JIT an toàn
    # ----------------------------------------

    OPCACHE="/etc/opt/remi/php${VERSION}/php.d/10-opcache.ini"

    if [ -f "$OPCACHE" ]; then
        # Xóa các dòng cũ để tránh duplicate
        sed -i '/^opcache\.memory_consumption/d'     "$OPCACHE"
        sed -i '/^opcache\.max_accelerated_files/d'  "$OPCACHE"
        sed -i '/^opcache\.validate_timestamps/d'    "$OPCACHE"
        sed -i '/^opcache\.revalidate_freq/d'        "$OPCACHE"
        sed -i '/^opcache\.jit_buffer_size/d'        "$OPCACHE"
        sed -i '/^opcache\.jit=/d'                   "$OPCACHE"
        sed -i '/^opcache\.enable=/d'                "$OPCACHE"

        cat >> "$OPCACHE" <<EOF
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=100000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.jit_buffer_size=128M
opcache.jit=1255
EOF
    fi

    # ----------------------------------------
    # FIX PHP-FPM POOL - pm=ondemand tránh lỗi
    # min/max_spare_servers conflict với max_children
    # ----------------------------------------

    PHP_POOL_CONF="/etc/opt/remi/php${VERSION}/php-fpm.d/www.conf"

    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    PM_MAX_CHILDREN=$((TOTAL_RAM / 50))

    # Đảm bảo tối thiểu 5, tối đa 100
    [ "$PM_MAX_CHILDREN" -lt 5  ] && PM_MAX_CHILDREN=5
    [ "$PM_MAX_CHILDREN" -gt 100 ] && PM_MAX_CHILDREN=100

    # Ghi đè toàn bộ www.conf - cách duy nhất đảm bảo không còn spare server directives
    # pm=ondemand: không cần start_servers, min/max_spare_servers
    PHP_SOCKET="/var/opt/remi/php${VERSION}/run/php-fpm/www.sock"

    mkdir -p "$(dirname $PHP_SOCKET)"

    cat > "$PHP_POOL_CONF" <<POOL
[www]
user = nginx
group = nginx
listen = ${PHP_SOCKET}
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = ondemand
pm.max_children = ${PM_MAX_CHILDREN}
pm.process_idle_timeout = 10s
pm.max_requests = 500

chdir = /
POOL

    # ----------------------------------------
    # FIX SELINUX / MPROTECT - lỗi Permission denied
    # Xuất hiện trên AlmaLinux 10 với SELinux enforcing
    # ----------------------------------------

    if command -v setsebool >/dev/null 2>&1; then
        setsebool -P httpd_execmem 1 2>/dev/null || true
    fi

    # Allow PHP JIT memory execution under SELinux (targeted booleans, not full permissive)
    if command -v setsebool >/dev/null 2>&1; then
        setsebool -P httpd_unified 1 2>/dev/null || true
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi

    # ----------------------------------------
    # ENSURE SHIELDPRESS LOG DIRS EXIST
    # ----------------------------------------
    ensure_shieldpress_dirs 2>/dev/null || true

    # ----------------------------------------
    # VALIDATE + START PHP-FPM
    # ----------------------------------------

    PHP_FPM_BIN="/opt/remi/php${VERSION}/root/usr/sbin/php-fpm"

    if "$PHP_FPM_BIN" -t 2>&1 | grep -q "ERROR"; then
        warn "PHP${VERSION} config test failed:"
        "$PHP_FPM_BIN" -t 2>&1
    else
        ok "PHP${VERSION} config OK"
    fi

    systemctl restart php${VERSION}-php-fpm && \
        ok "PHP${VERSION}-php-fpm started (pm=ondemand, max_children=$PM_MAX_CHILDREN)" || \
        warn "PHP${VERSION}-php-fpm failed - run: journalctl -xeu php${VERSION}-php-fpm"

}

# ------------------------------------------------
# INSTALL DEFAULT PHP VERSION
# ------------------------------------------------

install_php 84

# ------------------------------------------------
# COMPOSER
# ------------------------------------------------

msg "Installing Composer..." "Cai Composer..."

PHP84_BIN="/opt/remi/php84/root/usr/bin/php"

if [ -x "$PHP84_BIN" ]; then
    # Replace /usr/bin/php (system default) so PATH always resolves to PHP 8.4
    if [ -f /usr/bin/php ] && [ ! -L /usr/bin/php ]; then
        mv /usr/bin/php /usr/bin/php.old
    fi
    ln -sf "$PHP84_BIN" /usr/bin/php

    for tool in phpize php-config; do
        src="/opt/remi/php84/root/usr/bin/$tool"
        if [ -x "$src" ]; then
            [ -f "/usr/bin/$tool" ] && [ ! -L "/usr/bin/$tool" ] && mv "/usr/bin/$tool" "/usr/bin/${tool}.old"
            ln -sf "$src" "/usr/bin/$tool"
        fi
    done

    COMPOSER_SETUP="/tmp/composer-setup.php"
    EXPECTED_SIGNATURE=$(curl -fsSL https://composer.github.io/installer.sig)
    curl -fsSL https://getcomposer.org/installer -o "$COMPOSER_SETUP"
    ACTUAL_SIGNATURE=$("$PHP84_BIN" -r "echo hash_file('sha384', '$COMPOSER_SETUP');")

    if [ "$EXPECTED_SIGNATURE" = "$ACTUAL_SIGNATURE" ]; then
        "$PHP84_BIN" "$COMPOSER_SETUP" --install-dir=/usr/local/bin --filename=composer
        chmod +x /usr/local/bin/composer
        ok "Composer installed"
    else
        warn "Composer installer signature mismatch, skipping"
    fi

    rm -f "$COMPOSER_SETUP"
else
    warn "PHP 8.4 binary not found, cannot install Composer"
fi

# ------------------------------------------------
# FIREWALL
# ------------------------------------------------

systemctl enable firewalld
systemctl start firewalld


firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
open_ssh_firewall_port

ok "Firewall configured (SSH port: $SSH_PORT)"

# ------------------------------------------------
# FINAL CHECK
# ------------------------------------------------

echo ""
echo "================================================"
echo "           FINAL SERVICE STATUS"
echo "================================================"

FAILED=0

for svc in nginx mariadb valkey; do
    STATUS=$(systemctl is-active $svc 2>/dev/null)
    if [ "$STATUS" = "active" ]; then
        ok "$svc"
    else
        fail "$svc is $STATUS"
        FAILED=$((FAILED+1))
    fi
done

for v in 84; do
    STATUS=$(systemctl is-active php${v}-php-fpm 2>/dev/null)
    if [ "$STATUS" = "active" ]; then
        ok "PHP${v}-php-fpm"
    else
        warn "PHP${v}-php-fpm is $STATUS"
    fi
done

echo "================================================"

if [ "$FAILED" -eq 0 ]; then
    touch /etc/shieldpress/.stack_installed
    msg "Stack installed successfully!" "Cài đặt stack thành công!"
else
    warn "Core services failed: $FAILED. Check logs: $LOG_FILE"
    # Không exit 1 - vẫn mark installed nếu nginx+db+valkey ok
fi

# ------------------------------------------------
# WORDPRESS AUTO-RECOVERY DAEMON
# ------------------------------------------------

RECOVERY_SCRIPT="/opt/shieldpress/modules/wordpress/wp-auto-recovery.sh"
RECOVERY_SERVICE="/etc/systemd/system/shieldpress-wp-recovery.service"

if [ -f "$RECOVERY_SCRIPT" ]; then
    chmod +x "$RECOVERY_SCRIPT"

    cat > "$RECOVERY_SERVICE" <<'EOF'
[Unit]
Description=ShieldPress WordPress Auto-Recovery
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/shieldpress/modules/wordpress/wp-auto-recovery.sh --daemon
Restart=always
RestartSec=30
StandardOutput=append:/var/shieldpress/logs/wp-auto-recovery.log
StandardError=append:/var/shieldpress/logs/wp-auto-recovery.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shieldpress-wp-recovery.service >/dev/null 2>&1
    systemctl start shieldpress-wp-recovery.service >/dev/null 2>&1 || true
    ok "WordPress Auto-Recovery daemon enabled (checks every 60s)"
else
    warn "wp-auto-recovery.sh not found, skipping auto-recovery setup"
fi

# ------------------------------------------------
# TMPFILES.D - ensure ShieldPress dirs exist at boot
# (prevents PHP-FPM crash when slowlog dir is missing)
# ------------------------------------------------
cat > /etc/tmpfiles.d/shieldpress.conf <<'EOF'
d /var/shieldpress 0755 root root -
d /var/shieldpress/logs 0755 root root -
d /var/shieldpress/logs/php-slow 0755 root root -
d /var/shieldpress/logs/malware 0755 root root -
d /var/shieldpress/data 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/shieldpress.conf 2>/dev/null || true
ok "tmpfiles.d: ShieldPress directories ensured at boot"

# ------------------------------------------------
# RUN INSTALL.SH - setup commands & login banner
# ------------------------------------------------
INSTALL_SCRIPT="/opt/shieldpress/install.sh"
if [ -f "$INSTALL_SCRIPT" ]; then
    bash "$INSTALL_SCRIPT"
else
    warn "install.sh not found at $INSTALL_SCRIPT"
fi
