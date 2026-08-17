#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

reload_php(){
    for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
        systemctl list-unit-files 2>/dev/null | grep -q "$svc" || continue
        systemctl restart "$svc" 2>/dev/null && ok "$svc restarted" || warn "$svc restart failed"
    done
}

restart_stack(){
    systemctl restart nginx 2>/dev/null && ok "Nginx restarted" || fail "Nginx restart failed"
    systemctl restart mariadb 2>/dev/null && ok "MariaDB restarted" || warn "MariaDB not running"
    systemctl restart postgresql 2>/dev/null && ok "PostgreSQL restarted" || warn "PostgreSQL not running"
    systemctl restart valkey 2>/dev/null && ok "Valkey restarted" || warn "Valkey not running"
    reload_php
}

service_status(){
    echo ""
    echo "Core Services:"
    echo "--------------------------------"
    for svc in nginx mariadb postgresql valkey firewalld fail2ban; do
        state=$(systemctl is-active "$svc" 2>/dev/null)
        if [ "$state" = "active" ]; then
            echo -e "${GREEN}OK${RESET}   $svc"
        else
            echo -e "${RED}WARN${RESET} $svc: ${state:-not-found}"
        fi
    done

    for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
        systemctl list-unit-files 2>/dev/null | grep -q "$svc" || continue
        state=$(systemctl is-active "$svc" 2>/dev/null)
        echo "$svc: $state"
    done
}

show_versions(){
    echo ""
    echo "Versions:"
    echo "--------------------------------"
    echo "ShieldPress VPS : $(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo unknown)"
    echo "Nginx      : $(nginx -v 2>&1 | grep -o 'nginx/[^ ]*')"
    echo "MariaDB    : $(mysql -V 2>/dev/null | awk '{print $5}' | tr -d ',')"
    echo "PostgreSQL : $(psql --version 2>/dev/null | awk '{print $3}')"
    echo "Valkey     : $(valkey-server --version 2>/dev/null | awk '{print $3}')"
    echo "Node.js    : $(node -v 2>/dev/null || echo N/A)"
    echo "npm        : $(npm -v 2>/dev/null || echo N/A)"
    echo "Composer   : $(composer --version 2>/dev/null | awk '{print $3}' || echo N/A)"
}

update_core_packages(){
    read -p "Update OS/core packages now? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return; }

    dnf clean all
    dnf makecache --refresh --setopt=skip_if_unavailable=true -y
    dnf update -y --setopt=skip_if_unavailable=true || return 1
    restart_stack
    ok "Core packages updated"
}

update_shieldpress(){
    bash "$BASE_DIR/modules/update/update-menu.sh"
}

optimize_databases(){
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')

    MYSQL_BUFFER=$((TOTAL_RAM * 35 / 100))
    [ "$MYSQL_BUFFER" -lt 128 ] && MYSQL_BUFFER=128
    [ "$MYSQL_BUFFER" -gt 4096 ] && MYSQL_BUFFER=4096

    cat > /etc/my.cnf.d/shieldpress-tuning.cnf <<EOF
[mysqld]
innodb_buffer_pool_size=${MYSQL_BUFFER}M
innodb_log_file_size=256M
innodb_flush_method=O_DIRECT
innodb_flush_log_at_trx_commit=2
max_connections=200
tmp_table_size=64M
max_heap_table_size=64M
EOF

    if [ -f /var/lib/pgsql/data/postgresql.conf ]; then
        PG_SHARED=$((TOTAL_RAM * 20 / 100))
        PG_CACHE=$((TOTAL_RAM * 50 / 100))
        PG_WORK=$((TOTAL_RAM / 256))
        PG_MAINT=$((TOTAL_RAM / 16))

        [ "$PG_SHARED" -lt 128 ] && PG_SHARED=128
        [ "$PG_SHARED" -gt 2048 ] && PG_SHARED=2048
        [ "$PG_CACHE" -lt 512 ] && PG_CACHE=512
        [ "$PG_CACHE" -gt 8192 ] && PG_CACHE=8192
        [ "$PG_WORK" -lt 4 ] && PG_WORK=4
        [ "$PG_WORK" -gt 32 ] && PG_WORK=32
        [ "$PG_MAINT" -lt 64 ] && PG_MAINT=64
        [ "$PG_MAINT" -gt 512 ] && PG_MAINT=512

        sed -i '/^# SHIELDPRESS PostgreSQL tuning/,$d' /var/lib/pgsql/data/postgresql.conf
        cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# SHIELDPRESS PostgreSQL tuning
shared_buffers = ${PG_SHARED}MB
effective_cache_size = ${PG_CACHE}MB
work_mem = ${PG_WORK}MB
maintenance_work_mem = ${PG_MAINT}MB
max_connections = 100
checkpoint_completion_target = 0.9
wal_buffers = 16MB
random_page_cost = 1.1
EOF
    fi

    systemctl restart mariadb 2>/dev/null && ok "MariaDB tuned (${MYSQL_BUFFER}MB buffer pool)" || warn "MariaDB restart failed"
    systemctl restart postgresql 2>/dev/null && ok "PostgreSQL tuned" || warn "PostgreSQL restart failed"
}

view_core_logs(){
    echo "1) Nginx error"
    echo "2) PHP-FPM latest"
    echo "3) MariaDB"
    echo "4) PostgreSQL"
    echo "5) ShieldPress VPS update"
    read -p "Select: " opt

    case "$opt" in
        1) tail -f /var/log/nginx/error.log ;;
        2)
            found_log=0
            for php in 84 83 82 81; do
                log="/var/opt/remi/php${php}/log/php-fpm/error.log"
                if [ -f "$log" ]; then
                    found_log=1
                    tail -f "$log"
                    break
                fi
            done
            [ "$found_log" = "0" ] && warn "PHP-FPM log not found"
            ;;
        3) tail -f /var/log/mariadb/mariadb.log 2>/dev/null || tail -f /var/lib/mysql/*.err ;;
        4) journalctl -u postgresql -f ;;
        5) tail -f "$LOG_DIR/update.log" ;;
        *) warn "Invalid option" ;;
    esac
}

while true; do
    clear
    sp_header "Core Server" "Services, versions, logs"
    sp_menu_grid \
        "1|Service Status|cyan" \
        "2|Restart Stack|yellow" \
        "3|Show Versions|blue" \
        "4|Update ShieldPress VPS|yellow" \
        "5|Update OS/Core Packages|yellow" \
        "6|Optimize Databases|green" \
        "7|System Information|cyan" \
        "8|View Core Logs|magenta" \
        "0|Back|white"
    sp_prompt opt

    case "$opt" in
        1) service_status ;;
        2) restart_stack ;;
        3) show_versions ;;
        4) update_shieldpress ;;
        5) update_core_packages ;;
        6) optimize_databases ;;
        7) bash "$BASE_DIR/modules/helpers/system-check.sh" ;;
        8) view_core_logs ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
