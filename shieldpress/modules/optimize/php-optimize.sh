#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
CPU=$(nproc)
DOMAINS_ROOT="/home/domains"

ok()   { echo "[OK] $1"; }
warn() { echo "[WARN] $1"; }

echo "===================================================="
echo "              PHP-FPM OPTIMIZER"
echo "===================================================="
echo "RAM : ${TOTAL_RAM}MB | CPU : ${CPU} cores"
echo ""

# ================================================
# Tính pm.max_children theo RAM
# ================================================

PM_MAX=$((TOTAL_RAM / 40))
[ "$PM_MAX" -lt 5   ] && PM_MAX=5
[ "$PM_MAX" -gt 100 ] && PM_MAX=100

# ================================================
# Optimize www.conf (global pool)
# ================================================

optimize_version() {
    VERSION=$1
    CONF="/etc/opt/remi/php${VERSION}/php-fpm.d/www.conf"
    SVC="php${VERSION}-php-fpm"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "${SVC}"; then
        return
    fi
    [ -f "$CONF" ] || return

    PHP_SOCKET="/var/opt/remi/php${VERSION}/run/php-fpm/www.sock"
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
pm.max_children = $PM_MAX
pm.process_idle_timeout = 10s
pm.max_requests = 500

; Kill process treo sau 300s - tránh zombie ăn RAM
request_terminate_timeout = 300

chdir = /
POOL

    systemctl restart "$SVC" 2>/dev/null && \
        ok "PHP${VERSION}-FPM www.conf optimized (max_children=$PM_MAX)" || \
        warn "PHP${VERSION}-FPM restart failed"
}

optimize_version 81
optimize_version 82
optimize_version 83
optimize_version 84

# ================================================
# Optimize domain pools (per-domain)
# ================================================

echo ""
echo "Optimizing per-domain pools..."

for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue

    DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    SYSUSER=$(grep "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    PHP_VER=$(grep "^PHP_VERSION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

    [ -z "$DN" ] || [ -z "$PHP_VER" ] && continue

    PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
    POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSUSER}.conf"

    [ -f "$POOL_FILE" ] || continue

    CHANGED=0

    # Thêm request_terminate_timeout nếu chưa có
    if ! grep -q "request_terminate_timeout" "$POOL_FILE"; then
        echo "" >> "$POOL_FILE"
        echo "; Auto-added by optimizer" >> "$POOL_FILE"
        echo "request_terminate_timeout = 300" >> "$POOL_FILE"
        CHANGED=1
    fi

    # Thêm realpath_cache nếu chưa có
    if ! grep -q "realpath_cache_size" "$POOL_FILE"; then
        echo "php_admin_value[realpath_cache_size] = 4096K" >> "$POOL_FILE"
        echo "php_admin_value[realpath_cache_ttl]  = 600" >> "$POOL_FILE"
        CHANGED=1
    fi

    # Thêm slowlog cho debug (chỉ log request > 5s)
    if ! grep -q "slowlog" "$POOL_FILE"; then
        SLOW_DIR="$LOG_DIR_PHP_SLOW"
        mkdir -p "$SLOW_DIR"
        echo "slowlog = ${SLOW_DIR}/${SYSUSER}-slow.log" >> "$POOL_FILE"
        echo "request_slowlog_timeout = 5" >> "$POOL_FILE"
        CHANGED=1
    fi

    [ "$CHANGED" -eq 1 ] && ok "$DN - pool tuned" || echo "  $DN - already optimized"
done

# ================================================
# PHP-FPM global config - emergency restart
# ================================================

echo ""
echo "Applying PHP-FPM emergency restart protection..."

for v in 81 82 83 84; do
    FPM_CONF="/etc/opt/remi/php${v}/php-fpm.conf"
    SVC="php${v}-php-fpm"

    [ -f "$FPM_CONF" ] || continue
    if ! systemctl list-unit-files 2>/dev/null | grep -q "${SVC}"; then
        continue
    fi

    # emergency_restart: nếu nhiều child chết trong thời gian ngắn -> restart FPM
    if ! grep -q "emergency_restart_threshold" "$FPM_CONF"; then
        cat >> "$FPM_CONF" <<EMEOF

; Auto-added by optimizer - emergency restart protection
emergency_restart_threshold = 10
emergency_restart_interval  = 1m
process_control_timeout     = 10s
EMEOF
        ok "PHP${v} emergency restart protection added"
    fi
done

# ================================================
# Restart all PHP-FPM
# ================================================

echo ""
echo "Restarting all PHP-FPM services..."

for v in 81 82 83 84; do
    SVC="php${v}-php-fpm"
    if ! systemctl list-unit-files 2>/dev/null | grep -q "${SVC}"; then
        continue
    fi
    systemctl restart "$SVC" 2>/dev/null && ok "$SVC restarted" || warn "$SVC restart failed"
done

echo ""
echo "===================================================="
echo "PHP-FPM Optimization complete!"
echo "===================================================="
echo "  max_children            : $PM_MAX (global www)"
echo "  request_terminate_timeout: 300s"
echo "  realpath_cache_size     : 4096K"
echo "  slowlog timeout         : 5s"
echo "  emergency_restart       : 10 failures/1min"
echo ""
echo "Slow logs: $LOG_DIR_PHP_SLOW/"
read -p "Press Enter..."
