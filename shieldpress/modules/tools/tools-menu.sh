#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/tools.log"
source "$BASE_DIR/core/ui.sh"
mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo -e "${GREEN}[OK]${RESET} $1";       log "[OK] $1"; }
fail(){ echo -e "${RED}[FAILED]${RESET} $1";     log "[FAILED] $1"; }
warn(){ echo -e "${YELLOW}[WARNING]${RESET} $1"; log "[WARN] $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

if [ -f /opt/shieldpress/modules/helpers/nodejs-runtime.sh ]; then
    source /opt/shieldpress/modules/helpers/nodejs-runtime.sh
fi

# =================================================
# EDIT CONFIG
# =================================================

edit_file(){
    [ -f "$1" ] || { fail "File not found: $1"; return 1; }
    if command -v nano &>/dev/null; then
        nano "$1"
    elif command -v vim &>/dev/null; then
        vim "$1"
    else
        vi "$1"
    fi
}

edit_nginx(){

    # Load helper select domain
    source /opt/shieldpress/modules/domain/helpers.sh

    # ===== SELECT DOMAIN =====
    select_domain || return

    echo ""
    echo "Selected domain: $SELECTED_DOMAIN"
    echo ""

    NGINX_FILE="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

    if [ ! -f "$NGINX_FILE" ]; then
        fail "Nginx config not found: $NGINX_FILE"
        return
    fi

    echo "Opening Nginx config:"
    echo "$NGINX_FILE"
    echo ""

    # ===== OPEN EDITOR =====
    if command -v nano &>/dev/null; then
        nano "$NGINX_FILE"
    elif command -v vim &>/dev/null; then
        vim "$NGINX_FILE"
    else
        vi "$NGINX_FILE"
    fi

    echo ""
    read -p "Test & reload Nginx now? (y/n): " confirm

    if [[ "$confirm" =~ ^[yY]$ ]]; then

        if nginx -t 2>/dev/null; then
            systemctl reload nginx \
                && ok "Nginx reloaded" \
                || fail "Reload failed"
        else
            fail "Nginx config test failed!"
            nginx -t
        fi

    fi
}

edit_php(){

    # Load helper select domain
    source /opt/shieldpress/modules/domain/helpers.sh

    # ===== SELECT DOMAIN =====
    select_domain || return

    echo ""
    echo "Selected domain: $SELECTED_DOMAIN"
    echo "PHP version    : $PHP_VERSION"
    echo ""

    PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
    POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${CLEAN_DOMAIN}.conf"

    if [ ! -f "$POOL_FILE" ]; then
        fail "PHP pool config not found: $POOL_FILE"
        return
    fi

    echo "Opening PHP-FPM pool config:"
    echo "$POOL_FILE"
    echo ""

    # ===== OPEN EDITOR =====
    if command -v nano &>/dev/null; then
        nano "$POOL_FILE"
    elif command -v vim &>/dev/null; then
        vim "$POOL_FILE"
    else
        vi "$POOL_FILE"
    fi

    echo ""
    read -p "Reload PHP-FPM now? (y/n): " confirm

    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl restart php${PHP_SHORT}-php-fpm \
            && ok "PHP-FPM reloaded" \
            || fail "PHP-FPM reload failed"
    fi
}

edit_db(){ edit_file /etc/my.cnf; }

# =================================================
# SERVICE RELOAD / RESTART
# =================================================

reload_nginx(){
    if nginx -t 2>/dev/null; then
        systemctl reload nginx && ok "Nginx reloaded"
    else
        fail "Nginx config test failed:"
        nginx -t
    fi
}

reload_php(){
    for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
        systemctl list-unit-files 2>/dev/null | grep -q "$svc" || continue
        systemctl restart "$svc" 2>/dev/null && ok "$svc restarted" || warn "$svc restart failed"
    done
}

reload_db(){
    systemctl restart mariadb && ok "MariaDB restarted" || fail "MariaDB restart failed"
    systemctl restart postgresql 2>/dev/null && ok "PostgreSQL restarted" || warn "PostgreSQL not running"
}

restart_stack(){
    echo "Restarting full stack..."
    systemctl restart valkey  2>/dev/null && ok "Valkey restarted"  || warn "Valkey not running"
    systemctl restart mariadb 2>/dev/null && ok "MariaDB restarted" || fail "MariaDB failed"
    systemctl restart postgresql 2>/dev/null && ok "PostgreSQL restarted" || warn "PostgreSQL not running"
    reload_php
    reload_nginx
    ok "Stack restart complete"
}

# =================================================
# SERVICE STATUS
# =================================================

status(){
    echo ""
    echo "===================================================="
    echo "  SERVICE STATUS"
    echo "===================================================="
    for svc in nginx mariadb postgresql valkey; do
        STATE=$(systemctl is-active "$svc" 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  ${GREEN}●${RESET} $svc : $STATE"
        else
            echo -e "  ${RED}●${RESET} $svc : $STATE"
        fi
    done

    echo ""
    for php in 81 82 83 84; do
        SVC="php${php}-php-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
        STATE=$(systemctl is-active "$SVC" 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  ${GREEN}●${RESET} PHP ${php} FPM : $STATE"
        else
            echo -e "  ${RED}●${RESET} PHP ${php} FPM : $STATE"
        fi
    done
    echo "===================================================="
}

# =================================================
# VERSION INFO
# =================================================

versions(){
    echo ""
    echo "===================================================="
    echo "  VERSION INFO"
    echo "===================================================="
    echo -n "  Nginx   : "; nginx -v 2>&1 | grep -oP 'nginx/\S+'
    echo -n "  MariaDB : "; mysql -V 2>/dev/null | awk '{print $5}' | tr -d ','
    echo -n "  PostgreSQL : "; psql --version 2>/dev/null | awk '{print $3}'
    echo -n "  Valkey  : "; valkey-server --version 2>/dev/null | awk '{print $3}'
    echo -n "  Node.js : "; node -v 2>/dev/null || echo "N/A"
    echo -n "  npm     : "; npm -v 2>/dev/null || echo "N/A"
    echo -n "  Composer: "; composer --version 2>/dev/null | awk '{print $3}' || echo "N/A"

    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] || continue
        VER=$("$BIN" -v 2>/dev/null | head -1 | awk '{print $2}')
        echo "  PHP${php}   : $VER"
    done
    echo "===================================================="
}

# =================================================
# REPAIR SERVICES
# =================================================

repair(){
    echo "Checking and repairing services..."
    for svc in nginx mariadb postgresql valkey; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "$svc is stopped, restarting..."
            systemctl restart "$svc" && ok "$svc restarted" || fail "$svc failed to start"
        else
            ok "$svc is running"
        fi
    done

    for php in 81 82 83 84; do
        SVC="php${php}-php-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
        if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
            warn "$SVC stopped, restarting..."
            systemctl restart "$SVC" && ok "$SVC restarted" || fail "$SVC failed"
        fi
    done
}

# =================================================
# LEGACY SERVICE HELPERS
# =================================================

# =================================================
# RELOAD PHP / NGINX
# =================================================

reload_php_menu(){
    echo ""
    echo "========================================="
    echo "  RELOAD PHP / NGINX"
    echo "========================================="
    echo ""

    # Detect installed PHP versions
    PHP_INSTALLED=()
    for php in 81 82 83 84; do
        SVC="php${php}-php-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" && PHP_INSTALLED+=("$php")
    done

    if [ ${#PHP_INSTALLED[@]} -eq 0 ]; then
        fail "No PHP-FPM versions found"
        return 1
    fi

    echo "Installed PHP-FPM versions:"
    local INDEX=1
    declare -A PHP_MAP
    for php in "${PHP_INSTALLED[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        STATE=$(systemctl is-active "php${php}-php-fpm" 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  $INDEX) PHP ${VER_DOT}-FPM  ${GREEN}●${RESET} $STATE"
        else
            echo -e "  $INDEX) PHP ${VER_DOT}-FPM  ${RED}●${RESET} $STATE"
        fi
        PHP_MAP[$INDEX]=$php
        ((INDEX++))
    done

    echo ""
    echo "  A) Reload ALL PHP-FPM"
    echo "  N) Reload Nginx (test + reload)"
    echo "  X) Reload ALL PHP-FPM + Nginx"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " CHOICE

    case $CHOICE in
        [0-9])
            if [ "$CHOICE" = "0" ]; then
                return
            fi
            local TARGET="${PHP_MAP[$CHOICE]}"
            if [ -z "$TARGET" ]; then
                fail "Invalid selection"
                return 1
            fi
            local VER_DOT="${TARGET:0:1}.${TARGET:1}"
            echo "Reloading PHP ${VER_DOT}-FPM..."
            systemctl restart "php${TARGET}-php-fpm" 2>/dev/null \
                && ok "php${TARGET}-php-fpm restarted" \
                || fail "php${TARGET}-php-fpm restart failed"
            ;;
        [aA])
            echo "Reloading ALL PHP-FPM services..."
            for php in "${PHP_INSTALLED[@]}"; do
                VER_DOT="${php:0:1}.${php:1}"
                systemctl restart "php${php}-php-fpm" 2>/dev/null \
                    && ok "php${php}-php-fpm restarted" \
                    || warn "php${php}-php-fpm restart failed"
            done
            ;;
        [nN])
            echo "Testing Nginx config..."
            if nginx -t 2>&1; then
                echo ""
                systemctl reload nginx \
                    && ok "Nginx reloaded" \
                    || fail "Nginx reload failed"
            else
                echo ""
                fail "Nginx config test failed! Fix config before reloading."
            fi
            ;;
        [xX])
            echo "Reloading ALL PHP-FPM + Nginx..."
            echo ""
            for php in "${PHP_INSTALLED[@]}"; do
                VER_DOT="${php:0:1}.${php:1}"
                systemctl restart "php${php}-php-fpm" 2>/dev/null \
                    && ok "php${php}-php-fpm restarted" \
                    || warn "php${php}-php-fpm restart failed"
            done
            echo ""
            echo "Testing Nginx config..."
            if nginx -t 2>&1; then
                echo ""
                systemctl reload nginx \
                    && ok "Nginx reloaded" \
                    || fail "Nginx reload failed"
            else
                echo ""
                fail "Nginx config test failed! Fix config before reloading."
            fi
            ;;
        *)
            fail "Invalid option"
            ;;
    esac
}

install_nodejs(){
    install_shieldpress_nodejs
}

update_core_server(){
    echo "Updating core server packages..."
    dnf clean all
    dnf makecache --refresh --setopt=skip_if_unavailable=true -y
    dnf update -y --setopt=skip_if_unavailable=true || { fail "Core package update failed"; return 1; }

    install_nodejs
    reload_php
    systemctl restart nginx mariadb postgresql valkey 2>/dev/null || true
    reload_nginx
    ok "Core server update complete"
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

# =================================================
# IONCUBE INSTALL
# =================================================

install_ioncube(){

    echo "========================================="
    echo "       IONCUBE INSTALLER (SAFE)"
    echo "========================================="
    echo ""

    [ "$EUID" -ne 0 ] && { fail "Run as root"; return 1; }

    LOCK_FILE="/tmp/shieldpress_ioncube.lock"
    [ -f "$LOCK_FILE" ] && { warn "Another process running"; return 1; }
    touch "$LOCK_FILE"

    cd /tmp || return 1

    PHP_INSTALLED=()
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] && PHP_INSTALLED+=("$php")
    done

    if [ ${#PHP_INSTALLED[@]} -eq 0 ]; then
        rm -f "$LOCK_FILE"
        fail "No PHP versions found"
        return 1
    fi

    echo "Select PHP version:"
    INDEX=1
    declare -A MAP

    for php in "${PHP_INSTALLED[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        echo "$INDEX) PHP $VER_DOT"
        MAP[$INDEX]=$php
        ((INDEX++))
    done

    echo "A) ALL | 0) Cancel"
    read -p "Select: " CHOICE

    TARGETS=()

    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        [ "$CHOICE" = "0" ] && { rm -f "$LOCK_FILE"; return; }
        TARGETS=("${MAP[$CHOICE]}")
    elif [[ "$CHOICE" =~ ^[aA]$ ]]; then
        TARGETS=("${PHP_INSTALLED[@]}")
    else
        rm -f "$LOCK_FILE"
        fail "Invalid selection"
        return 1
    fi

    echo "Downloading ionCube..."
    wget -q https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz -O ioncube.tar.gz \
        || { fail "Download failed"; rm -f "$LOCK_FILE"; return 1; }

    tar -xzf ioncube.tar.gz || {
        fail "Extract failed"
        rm -f "$LOCK_FILE"
        return 1
    }

    IONCUBE_DIR="/tmp/ioncube"

    for php in "${TARGETS[@]}"; do

        PHP_BIN="/opt/remi/php${php}/root/usr/bin/php"
        PHP_FPM="/opt/remi/php${php}/root/usr/sbin/php-fpm"
        VER_DOT="${php:0:1}.${php:1}"

        SO_FILE="${IONCUBE_DIR}/ioncube_loader_lin_${VER_DOT}.so"
        INI_DIR="/etc/opt/remi/php${php}/php.d"
        INI_FILE="${INI_DIR}/00-ioncube.ini"

        [ ! -f "$SO_FILE" ] && { warn "Loader missing for PHP ${VER_DOT}"; continue; }
        mkdir -p "$INI_DIR"

        EXT_DIR=$($PHP_BIN -r "echo ini_get('extension_dir');")

        [ ! -d "$EXT_DIR" ] && {
            fail "extension_dir not found"
            continue
        }

        echo "Installing for PHP $VER_DOT..."

        # backup nếu đã tồn tại
        [ -f "$INI_FILE" ] && cp "$INI_FILE" "${INI_FILE}.bak"

        cp "$SO_FILE" "$EXT_DIR/" || {
            fail "Copy failed"
            continue
        }

        cat > "$INI_FILE" <<EOF
zend_extension=${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so
EOF

        # 🔥 Disable JIT auto
        JIT_FILE="${INI_DIR}/99-ioncube-jit-disable.ini"
        cat > "$JIT_FILE" <<EOF
opcache.jit=0
opcache.jit_buffer_size=0
EOF

        # TEST CONFIG
        $PHP_FPM -t >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            fail "Config fail → rollback"

            rm -f "$INI_FILE"
            rm -f "$JIT_FILE"
            rm -f "${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so"

            [ -f "${INI_FILE}.bak" ] && mv "${INI_FILE}.bak" "$INI_FILE"
            continue
        fi

        systemctl restart php${php}-php-fpm

        if $PHP_BIN -m | grep -qi ionCube; then
            ok "ionCube OK for PHP ${VER_DOT}"
        else
            warn "Installed but not loaded"
        fi
    done

    rm -rf /tmp/ioncube*
    rm -f "$LOCK_FILE"

    ok "ionCube installation complete"
}

remove_ioncube(){

    echo "========================================="
    echo "       REMOVE IONCUBE"
    echo "========================================="
    echo ""

    [ "$EUID" -ne 0 ] && { fail "Run as root"; return 1; }

    for php in 81 82 83 84; do

        PHP_BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ ! -x "$PHP_BIN" ] && continue

        VER_DOT="${php:0:1}.${php:1}"
        EXT_DIR=$($PHP_BIN -r "echo ini_get('extension_dir');")

        INI_DIR="/etc/opt/remi/php${php}/php.d"
        INI_FILE="${INI_DIR}/00-ioncube.ini"
        JIT_FILE="${INI_DIR}/99-ioncube-jit-disable.ini"

        echo "Removing from PHP $VER_DOT..."

        rm -f "$INI_FILE"
        rm -f "$JIT_FILE"
        rm -f "${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so"

        systemctl restart php${php}-php-fpm

        if ! $PHP_BIN -m | grep -qi ionCube; then
            ok "Removed ionCube PHP ${VER_DOT}"
        else
            warn "Still detected ionCube in PHP ${VER_DOT}"
        fi
    done

    ok "ionCube removed completely"
}

# =================================================
# VIEW LOGS
# =================================================

view_logs(){
    echo "Select log to view:"
    echo "1) Nginx access log"
    echo "2) Nginx error log"
    echo "3) PHP-FPM error log"
    echo "4) MariaDB log"
    echo "5) ShieldPress tools log"
    echo "6) Domain-specific Nginx log"
    read -p "Choose: " c

    case $c in
        1) tail -f /var/log/nginx/access.log ;;
        2) tail -f /var/log/nginx/error.log ;;
        3)
            # Tìm PHP log từ version đang active
            for php in 84 83 82 81; do
                LOG="/var/opt/remi/php${php}/log/php-fpm/error.log"
                if [ -f "$LOG" ]; then
                    echo "Showing PHP${php} log: $LOG"
                    tail -f "$LOG"
                    break
                fi
            done
            ;;
        4) tail -f /var/log/mariadb/mariadb.log 2>/dev/null || \
           tail -f /var/lib/mysql/*.err 2>/dev/null || \
           warn "MariaDB log not found" ;;
        5) tail -f "$LOG_FILE" ;;
        6)
            DOMAINS_ROOT="/home/domains"
            echo ""
            echo "Available domains:"
            i=1
            declare -a DLIST
            for d in "$DOMAINS_ROOT"/*/; do
                [ -d "$d" ] || continue
                DN=$(grep "^DOMAIN=" "$d/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
                [ -z "$DN" ] && continue
                echo "$i) $DN"
                DLIST[$i]=$(basename "$d")
                ((i++))
            done
            read -p "Select: " DC
            DF="${DLIST[$DC]}"
            [ -z "$DF" ] && { warn "Invalid"; return; }
            LOG_DIR="/var/log/nginx/domains/$DF"
            echo "1) access.log  2) error.log"
            read -p "Choose: " LC
            case $LC in
                1) tail -f "$LOG_DIR/access.log" ;;
                2) tail -f "$LOG_DIR/error.log" ;;
            esac
            ;;
        *) warn "Invalid option" ;;
    esac
}

# =================================================
# SHOW PHP MODULES
# =================================================

show_php_modules(){
    echo "Select PHP version:"
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] && echo "$((php-80))) PHP 8.${php:1}"
    done
    read -p "Choose: " v
    case $v in
        1) BIN="/opt/remi/php81/root/usr/bin/php" ;;
        2) BIN="/opt/remi/php82/root/usr/bin/php" ;;
        3) BIN="/opt/remi/php83/root/usr/bin/php" ;;
        4) BIN="/opt/remi/php84/root/usr/bin/php" ;;
        *) warn "Invalid"; return ;;
    esac
    [ -x "$BIN" ] && "$BIN" -m || fail "PHP binary not found"
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "Tools & Utilities" "Editors, logs, runtime helpers"
    sp_menu_grid \
        "1|Edit Database Config|yellow" \
        "2|View Logs|magenta" \
        "3|Meilisearch Setup|blue" \
        "4|Auto-Reload MariaDB|green" \
        "5|Service Status|cyan" \
        "6|Version Info|cyan" \
        "7|Repair Services|yellow" \
        "8|Restart Full Stack|yellow" \
        "9|Server Migration|magenta" \
        "10|Migrate Paths|green" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1)  edit_db ;;
        2)  view_logs ;;
        3)  bash "$BASE_DIR/modules/tools/meilisearch.sh" ;;
        4)  bash "$BASE_DIR/modules/tools/auto-reload-db.sh" ;;
        5)  status ;;
        6)  versions ;;
        7)  repair ;;
        8)  restart_stack ;;
        9)  bash "$BASE_DIR/modules/tools/migrate.sh" ;;
        10) bash "$BASE_DIR/modules/tools/migrate-paths.sh" ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac

    pause
done
