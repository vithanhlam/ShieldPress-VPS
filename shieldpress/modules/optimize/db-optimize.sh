#!/bin/bash

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU=$(nproc)

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

echo "===================================================="
echo "            MARIADB OPTIMIZER"
echo "===================================================="
echo "RAM : ${TOTAL_RAM}MB | CPU : ${CPU} cores"
echo ""

# ================================================
# Tính toán thông số theo RAM
# ================================================

BUFFER=$((TOTAL_RAM * 30 / 100))
[ "$BUFFER" -gt 4096 ] && BUFFER=4096
[ "$BUFFER" -lt 128  ] && BUFFER=128

# tmp_table & heap theo RAM
if [ "$TOTAL_RAM" -ge 4096 ]; then
    TMP_TABLE=256
    MAX_CONN=300
    TABLE_CACHE=2000
    TABLE_DEF_CACHE=1000
    IO_CAPACITY=2000
    IO_CAPACITY_MAX=4000
elif [ "$TOTAL_RAM" -ge 2048 ]; then
    TMP_TABLE=128
    MAX_CONN=200
    TABLE_CACHE=1000
    TABLE_DEF_CACHE=500
    IO_CAPACITY=1000
    IO_CAPACITY_MAX=2000
else
    TMP_TABLE=64
    MAX_CONN=150
    TABLE_CACHE=400
    TABLE_DEF_CACHE=256
    IO_CAPACITY=500
    IO_CAPACITY_MAX=1000
fi

# I/O threads theo CPU
IO_THREADS=$((CPU > 8 ? 8 : CPU))
[ "$IO_THREADS" -lt 2 ] && IO_THREADS=2

# sort/join buffer (per-connection, không nên quá lớn)
if [ "$TOTAL_RAM" -ge 4096 ]; then
    SORT_BUFFER=4
    JOIN_BUFFER=4
    READ_BUFFER=2
else
    SORT_BUFFER=2
    JOIN_BUFFER=2
    READ_BUFFER=1
fi

echo "Buffer pool       : ${BUFFER}MB"
echo "Max connections   : ${MAX_CONN}"
echo "Table cache       : ${TABLE_CACHE}"
echo "I/O threads       : ${IO_THREADS}"
echo "I/O capacity      : ${IO_CAPACITY}"
echo ""

# ================================================
# Xóa config cũ (tránh conflict)
# ================================================

rm -f /etc/my.cnf.d/shieldpress-optimize.cnf
rm -f /etc/my.cnf.d/shieldpress-ram-auto.cnf

# ================================================
# Ghi config mới
# ================================================

cat > /etc/my.cnf.d/shieldpress-optimize.cnf <<DBEOF
[mysqld]
# === InnoDB Core ===
innodb_buffer_pool_size    = ${BUFFER}M
innodb_log_file_size       = 256M
innodb_flush_method        = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table      = 1

# === InnoDB I/O (SSD optimized) ===
innodb_io_capacity         = ${IO_CAPACITY}
innodb_io_capacity_max     = ${IO_CAPACITY_MAX}
innodb_read_io_threads     = ${IO_THREADS}
innodb_write_io_threads    = ${IO_THREADS}

# === Connection & Table Cache ===
max_connections            = ${MAX_CONN}
table_open_cache           = ${TABLE_CACHE}
table_definition_cache     = ${TABLE_DEF_CACHE}

# === Per-Connection Buffers ===
# Cẩn thận: giá trị này nhân với max_connections
sort_buffer_size           = ${SORT_BUFFER}M
join_buffer_size           = ${JOIN_BUFFER}M
read_buffer_size           = ${READ_BUFFER}M
read_rnd_buffer_size       = ${READ_BUFFER}M

# === Temp Tables ===
tmp_table_size             = ${TMP_TABLE}M
max_heap_table_size        = ${TMP_TABLE}M

# === Query Optimization ===
query_cache_type           = 0
query_cache_size           = 0

# === Slow Query Log ===
slow_query_log             = 1
slow_query_log_file        = /var/log/mariadb/slow-query.log
long_query_time            = 2
log_queries_not_using_indexes = 0

# === Safety ===
max_allowed_packet         = 256M
interactive_timeout        = 300
wait_timeout               = 300
DBEOF

# Tạo thư mục log
mkdir -p /var/log/mariadb
chown mysql:mysql /var/log/mariadb

# ================================================
# Restart & Verify
# ================================================

if systemctl restart mariadb 2>/dev/null; then
    ok "MariaDB optimized"
    echo ""
    echo "Key settings applied:"
    mysql -e "SHOW VARIABLES WHERE Variable_name IN (
        'innodb_buffer_pool_size',
        'innodb_io_capacity',
        'innodb_read_io_threads',
        'max_connections',
        'table_open_cache',
        'slow_query_log'
    );" 2>/dev/null
else
    warn "MariaDB restart failed! Check config:"
    echo "  journalctl -xeu mariadb"
    echo ""
    echo "Rolling back..."
    rm -f /etc/my.cnf.d/shieldpress-optimize.cnf
    systemctl restart mariadb 2>/dev/null
fi

echo ""
echo "Slow query log: /var/log/mariadb/slow-query.log"
echo "  View: tail -50 /var/log/mariadb/slow-query.log"
read -p "Press Enter..."
