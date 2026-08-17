#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG="$LOG_DIR/ram-auto-optimize.log"
mkdir -p "$LOG_DIR"

log(){
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

ok()   { echo "[OK] $1"; log "[OK] $1"; }
warn() { echo "[WARN] $1"; log "[WARN] $1"; }

clear
echo "===================================================="
echo "              SHIELDPRESS RAM AUTO OPTIMIZER"
echo "===================================================="

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)

echo "Detected RAM : ${TOTAL_RAM}MB"
echo "CPU Cores    : ${CPU_CORES}"

# ==============================
# RAM PROFILE
# ==============================

if [ "$TOTAL_RAM" -le 2048 ]; then
    PROFILE="2GB"
    ZRAM_SIZE="512M"
    CACHE_MEM="128mb"
    DB_BUFFER="256M"
    PHP_CHILD=8

elif [ "$TOTAL_RAM" -le 4096 ]; then
    PROFILE="4GB"
    ZRAM_SIZE="1G"
    CACHE_MEM="512mb"
    DB_BUFFER="512M"
    PHP_CHILD=15

elif [ "$TOTAL_RAM" -le 8192 ]; then
    PROFILE="8GB"
    ZRAM_SIZE="2G"
    CACHE_MEM="1gb"
    DB_BUFFER="1G"
    PHP_CHILD=30

elif [ "$TOTAL_RAM" -le 16384 ]; then
    PROFILE="16GB"
    ZRAM_SIZE="4G"
    CACHE_MEM="2gb"
    DB_BUFFER="4G"
    PHP_CHILD=60

else
    PROFILE="32GB+"
    ZRAM_SIZE="8G"
    CACHE_MEM="4gb"
    DB_BUFFER="10G"
    PHP_CHILD=120
fi

echo ""
echo "RAM Profile  : $PROFILE"
echo "ZRAM         : $ZRAM_SIZE"
echo "Cache Memory : $CACHE_MEM"
echo "DB Buffer    : $DB_BUFFER"
echo "PHP Children : $PHP_CHILD"
echo ""

# ==============================
# CONFIGURE ZRAM
# ==============================

echo "Configuring ZRAM..."

if dnf install -y zram-generator >/dev/null 2>&1; then

    cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

    systemctl daemon-reexec
    systemctl restart systemd-zram-setup@zram0 2>/dev/null || true
    ok "ZRAM configured ($ZRAM_SIZE)"

else
    warn "zram-generator not available, skipping"
fi

# ==============================
# OPTIMIZE VALKEY (ưu tiên) / REDIS
# ==============================

echo "Optimizing cache server..."

VALKEY_CONF="/etc/valkey/valkey.conf"
REDIS_CONF="/etc/redis.conf"

if [ -f "$VALKEY_CONF" ]; then

    sed -i '/^maxmemory /d'        "$VALKEY_CONF"
    sed -i '/^maxmemory-policy /d' "$VALKEY_CONF"
    echo "maxmemory $CACHE_MEM"         >> "$VALKEY_CONF"
    echo "maxmemory-policy allkeys-lru" >> "$VALKEY_CONF"

    systemctl restart valkey 2>/dev/null && \
        ok "Valkey optimized ($CACHE_MEM)" || \
        warn "Valkey restart failed"

elif [ -f "$REDIS_CONF" ]; then

    sed -i '/^maxmemory /d'        "$REDIS_CONF"
    sed -i '/^maxmemory-policy /d' "$REDIS_CONF"
    echo "maxmemory $CACHE_MEM"         >> "$REDIS_CONF"
    echo "maxmemory-policy allkeys-lru" >> "$REDIS_CONF"

    systemctl restart redis 2>/dev/null && \
        ok "Redis optimized ($CACHE_MEM)" || \
        warn "Redis restart failed"

else
    warn "No Valkey/Redis config found, skipping"
fi

# ==============================
# OPTIMIZE MARIADB
# ==============================

echo "Optimizing MariaDB..."

MYCNF="/etc/my.cnf.d/shieldpress-ram-auto.cnf"

cat > "$MYCNF" <<EOF
[mysqld]
innodb_buffer_pool_size=$DB_BUFFER
innodb_log_file_size=256M
innodb_flush_method=O_DIRECT
innodb_flush_log_at_trx_commit=2
tmp_table_size=64M
max_heap_table_size=64M
max_connections=200
EOF

systemctl restart mariadb 2>/dev/null && \
    ok "MariaDB optimized (buffer: $DB_BUFFER)" || \
    warn "MariaDB restart failed"

# ==============================
# OPTIMIZE PHP-FPM
# Ghi đè toàn bộ www.conf với pm=ondemand
# Tránh lỗi min/max_spare_servers conflict
# ==============================

echo "Optimizing PHP-FPM..."

for v in 81 82 83 84; do

    CONF="/etc/opt/remi/php${v}/php-fpm.d/www.conf"
    PHP_FPM_SVC="php${v}-php-fpm"

    # Skip nếu service không tồn tại
    if ! systemctl list-unit-files 2>/dev/null | grep -q "${PHP_FPM_SVC}"; then
        continue
    fi

    [ -f "$CONF" ] || continue

    PHP_SOCKET="/var/opt/remi/php${v}/run/php-fpm/www.sock"
    mkdir -p "$(dirname $PHP_SOCKET)"

    cat > "$CONF" <<POOL
[www]
user = apache
group = apache
listen = $PHP_SOCKET
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = ondemand
pm.max_children = $PHP_CHILD
pm.process_idle_timeout = 10s
pm.max_requests = 500

chdir = /
POOL

    systemctl restart "$PHP_FPM_SVC" 2>/dev/null && \
        ok "PHP${v}-FPM optimized (ondemand, max_children=$PHP_CHILD)" || \
        warn "PHP${v}-FPM restart failed"

done

# ==============================
# CLEAR RAM CACHE
# ==============================

echo "Cleaning RAM cache..."
sync
echo 3 > /proc/sys/vm/drop_caches
ok "RAM page cache cleared"

# ==============================
# RESULT
# ==============================

echo ""
echo "===================================================="
echo "              OPTIMIZATION COMPLETE"
echo "===================================================="
echo "Profile      : $PROFILE"
echo "ZRAM         : $ZRAM_SIZE"
echo "Cache Memory : $CACHE_MEM"
echo "MariaDB Buff : $DB_BUFFER"
echo "PHP Children : $PHP_CHILD (pm=ondemand)"
echo ""
free -h
echo ""
echo "Log: $LOG"
echo ""
read -p "Press Enter to continue..."
