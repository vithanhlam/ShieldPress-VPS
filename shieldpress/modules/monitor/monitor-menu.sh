#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

DOMAINS_ROOT="/home/domains"
NGINX_LOG_ROOT="/var/log/nginx/domains"
ALERT_LOG="$LOG_DIR/monitor-alert.log"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LOG_DIR"

pause(){ echo ""; read -p "Press Enter to continue..."; }

# ===============================
# SELECT DOMAIN - fix source leak
# ===============================

select_domain_monitor(){
    local -a _FOLDERS=()
    local -a _NAMES=()

    echo ""
    echo "Available Domains:"
    echo "------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        echo "$i) $DN"
        _FOLDERS[$i]=$(basename "$d")
        _NAMES[$i]="$DN"
        ((i++))
    done

    echo "------------------------------"
    read -p "Select domain number: " choice

    DOMAIN_FOLDER="${_FOLDERS[$choice]}"
    DOMAIN_NAME="${_NAMES[$choice]}"

    [ -z "$DOMAIN_FOLDER" ] && { echo "Invalid selection!"; return 1; }

    LOG_PATH="$NGINX_LOG_ROOT/$DOMAIN_FOLDER/access.log"
    ERROR_LOG="$NGINX_LOG_ROOT/$DOMAIN_FOLDER/error.log"
    return 0
}

# ===============================
# 1. BANDWIDTH PER DOMAIN
# ===============================

bandwidth_usage(){
    select_domain_monitor || return

    [ -f "$LOG_PATH" ] || { echo "Access log not found: $LOG_PATH"; pause; return; }

    echo ""
    echo "===================================================="
    echo "  BANDWIDTH - $DOMAIN_NAME"
    echo "===================================================="

    # Nginx log: $10 là bytes_sent (column 10 trong combined format)
    # Kiểm tra log format trước
    SAMPLE=$(head -1 "$LOG_PATH" 2>/dev/null)
    COLS=$(echo "$SAMPLE" | awk '{print NF}')

    echo "Log columns detected: $COLS"
    echo ""

    # Tính bandwidth theo ngày
    echo "Daily bandwidth (last 7 days):"
    echo "------------------------------------"
    awk '{
        # Lấy ngày từ column 4: [01/Jan/2024:...
        split($4, arr, "/")

        # remove dấu [
        gsub("\\[", "", arr[1])

        day = arr[1] "/" arr[2]

        # đảm bảo $10 là số
        if ($10 ~ /^[0-9]+$/)
            bytes[day] += $10
    }
    END {
        for (k in bytes)
            printf "  %-15s : %.2f MB\n", k, bytes[k]/1024/1024
    }' "$LOG_PATH" | sort -t'/' -k2 | tail -7

    echo ""
    TOTAL=$(awk '$10 ~ /^[0-9]+$/ {s+=$10} END {printf "%.2f", s/1024/1024}' "$LOG_PATH")
    echo "Total (all time): ${TOTAL} MB"

    pause
}

# ===============================
# 2. ATTACK SPIKE DETECTION
# ===============================

detect_attack(){
    select_domain_monitor || return

    [ -f "$LOG_PATH" ] || { echo "Log not found!"; pause; return; }

    echo ""
    echo "===================================================="
    echo "  ATTACK DETECTION - $DOMAIN_NAME"
    echo "===================================================="

    # Đếm HTTP error codes trong 1000 dòng cuối
    echo "Scanning last 1000 requests..."
    echo ""

    LINES=$(tail -n 1000 "$LOG_PATH")

    C_403=$(echo "$LINES" | awk '$9==403' | wc -l)
    C_404=$(echo "$LINES" | awk '$9==404' | wc -l)
    C_429=$(echo "$LINES" | awk '$9==429' | wc -l)
    C_500=$(echo "$LINES" | awk '$9==500' | wc -l)

    printf "  403 Forbidden   : %s\n" "$C_403"
    printf "  404 Not Found   : %s\n" "$C_404"
    printf "  429 Rate Limit  : %s\n" "$C_429"
    printf "  500 Server Error: %s\n" "$C_500"

    echo ""
    echo "Top attacking IPs (403/429):"
    echo "$LINES" | awk '$9==403 || $9==429 {print $1}' | \
        sort | uniq -c | sort -nr | head -5 | \
        awk '{printf "  %-5s requests: %s\n", $1, $2}'

    TOTAL_BAD=$((C_403 + C_429))
    if [ "$TOTAL_BAD" -gt 100 ]; then
        echo ""
        echo "[WARN] Possible attack spike! ($TOTAL_BAD bad requests)"
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Attack spike on $DOMAIN_NAME: 403=$C_403 429=$C_429" >> "$ALERT_LOG"
    else
        echo ""
        echo "[OK] No significant attack detected"
    fi

    pause
}

# ===============================
# 3. SERVER RESOURCES
# ===============================

check_resources(){
    echo ""
    echo "===================================================="
    echo "  SERVER RESOURCES"
    echo "===================================================="

    RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    RAM_USED=$(free -m  | awk '/Mem:/ {print $3}')
    RAM_FREE=$(free -m  | awk '/Mem:/ {print $4+$6+$7}')
    RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))

    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -m  | awk '/Swap:/ {print $3}')

    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    CPU_CORES=$(nproc)

    DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

    echo "  RAM  : ${RAM_USED}MB / ${RAM_TOTAL}MB (${RAM_PCT}%)"
    echo "  Free : ${RAM_FREE}MB"
    echo "  Swap : ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
    echo "  CPU  : Load $CPU_LOAD (${CPU_CORES} cores)"
    echo "  Disk : $DISK_USED / $DISK_TOTAL ($DISK_PCT%)"

    # Cảnh báo
    [ "$RAM_PCT"  -gt 90 ] && echo "" && echo "[WARN] RAM critical: ${RAM_PCT}%" && \
        echo "$(date '+%Y-%m-%d %H:%M:%S') | RAM critical: ${RAM_PCT}%" >> "$ALERT_LOG"
    [ "$DISK_PCT" -gt 85 ] && echo "" && echo "[WARN] Disk usage high: ${DISK_PCT}%" && \
        echo "$(date '+%Y-%m-%d %H:%M:%S') | Disk critical: ${DISK_PCT}%" >> "$ALERT_LOG"

    echo ""
    echo "  Top 5 RAM processes:"
    echo "  ----------------------------------------"
    ps -eo pid,user,comm,%mem,%cpu --sort=-%mem | head -6 | \
        awk 'NR==1{next} {printf "  %-8s %-12s %-20s %5s%% %5s%%\n", $1,$2,$3,$4,$5}'

    echo ""
    echo "  Top 5 CPU processes:"
    echo "  ----------------------------------------"
    ps -eo pid,user,comm,%mem,%cpu --sort=-%cpu | head -6 | \
        awk 'NR==1{next} {printf "  %-8s %-12s %-20s %5s%% %5s%%\n", $1,$2,$3,$4,$5}'

    pause
}

# ===============================
# 4. LOG ANALYZER
# ===============================

log_analyzer(){
    select_domain_monitor || return

    [ -f "$LOG_PATH" ] || { echo "Log not found!"; pause; return; }

    echo ""
    echo "===================================================="
    echo "  LOG ANALYZER - $DOMAIN_NAME"
    echo "===================================================="

    TOTAL=$(wc -l < "$LOG_PATH")
    C_200=$(grep -c " 200 " "$LOG_PATH" 2>/dev/null || echo 0)
    C_301=$(grep -c " 301 " "$LOG_PATH" 2>/dev/null || echo 0)
    C_302=$(grep -c " 302 " "$LOG_PATH" 2>/dev/null || echo 0)
    C_404=$(grep -c " 404 " "$LOG_PATH" 2>/dev/null || echo 0)
    C_500=$(grep -c " 500 " "$LOG_PATH" 2>/dev/null || echo 0)
    C_502=$(grep -c " 502 " "$LOG_PATH" 2>/dev/null || echo 0)

    echo "  Total requests : $TOTAL"
    echo ""
    echo "  200 OK         : $C_200"
    echo "  301/302 Redir  : $((C_301 + C_302))"
    echo "  404 Not Found  : $C_404"
    echo "  500 Server Err : $C_500"
    echo "  502 Bad Gateway: $C_502"

    if [ "$C_404" -gt 0 ]; then
        echo ""
        echo "  Top 10 - 404 URLs:"
        grep " 404 " "$LOG_PATH" | awk '{print $7}' | \
            sort | uniq -c | sort -nr | head -10 | \
            awk '{printf "    %-5s %s\n", $1, $2}'
    fi

    if [ "$C_500" -gt 0 ] || [ "$C_502" -gt 0 ]; then
        echo ""
        echo "  Recent 500/502 errors:"
        grep -E " 50[02] " "$LOG_PATH" | tail -5 | \
            awk '{printf "    [%s %s] %s -> %s\n", $4,$5,$1,$7}'
    fi

    pause
}

# ===============================
# 5. TOP IP ACCESS
# ===============================

top_ip(){
    select_domain_monitor || return

    [ -f "$LOG_PATH" ] || { echo "Log not found!"; pause; return; }

    echo ""
    echo "===================================================="
    echo "  TOP IP ACCESS - $DOMAIN_NAME"
    echo "===================================================="

    echo "  Top 10 IPs (all requests):"
    awk '{print $1}' "$LOG_PATH" | sort | uniq -c | sort -nr | head -10 | \
        awk '{printf "    %-8s requests: %s\n", $1, $2}'

    echo ""
    echo "  Top 10 IPs (404 only):"
    grep " 404 " "$LOG_PATH" | awk '{print $1}' | sort | uniq -c | sort -nr | head -5 | \
        awk '{printf "    %-8s requests: %s\n", $1, $2}'

    pause
}

# ===============================
# 6. LIVE LOG TAIL
# ===============================

live_log(){
    select_domain_monitor || return

    echo ""
    echo "1) Access log"
    echo "2) Error log"
    read -p "Choose: " LC

    case $LC in
        1)
            [ -f "$LOG_PATH" ] || { echo "Access log not found"; pause; return; }
            echo "Live access log (Ctrl+C to stop)..."
            echo ""
            tail -f "$LOG_PATH"
            ;;
        2)
            [ -f "$ERROR_LOG" ] || { echo "Error log not found"; pause; return; }
            echo "Live error log (Ctrl+C to stop)..."
            echo ""
            tail -f "$ERROR_LOG"
            ;;
        *) echo "Invalid" ;;
    esac
    pause
}

# ===============================
# 7. LOG VIEWER (multi-type, multi-domain)
# ===============================

log_viewer(){
    echo ""
    echo "===================================================="
    echo "  LOG VIEWER"
    echo "===================================================="

    # Step 1: Choose log type
    echo ""
    echo "  Log type:"
    echo "  1) Nginx Access Log (per domain)"
    echo "  2) Nginx Error Log (per domain)"
    echo "  3) PHP-FPM Error Log"
    echo "  4) PHP Slow Log (per domain)"
    echo "  5) MariaDB / MySQL Log"
    echo "  6) PostgreSQL Log"
    echo "  7) Nginx Global Error Log"
    echo "  0) Cancel"
    echo ""
    read -p "Select log type: " LOG_TYPE

    [ "$LOG_TYPE" = "0" ] && return

    local TARGET_LOG=""
    local LOG_LABEL=""

    case "$LOG_TYPE" in
        1)
            select_domain_monitor || return
            TARGET_LOG="$LOG_PATH"
            LOG_LABEL="Access — $DOMAIN_NAME"
            ;;
        2)
            select_domain_monitor || return
            TARGET_LOG="$ERROR_LOG"
            LOG_LABEL="Error — $DOMAIN_NAME"
            ;;
        3)
            # Find installed PHP versions, let user pick
            local PHP_LOGS=()
            local pi=1
            echo ""
            for v in 81 82 83 84; do
                local FPMLOG="/var/opt/remi/php${v}/log/php-fpm/error.log"
                if [ -f "$FPMLOG" ]; then
                    echo "  $pi) PHP ${v:0:1}.${v:1} FPM error log"
                    PHP_LOGS[$pi]="$FPMLOG"
                    ((pi++))
                fi
            done
            [ $pi -eq 1 ] && { echo "  No PHP-FPM error logs found."; pause; return; }
            echo ""
            read -p "Select: " pchoice
            TARGET_LOG="${PHP_LOGS[$pchoice]}"
            [ -z "$TARGET_LOG" ] && { echo "Invalid selection"; pause; return; }
            LOG_LABEL="PHP-FPM Error ($(basename "$(dirname "$(dirname "$TARGET_LOG")")"))"
            ;;
        4)
            select_domain_monitor || return
            TARGET_LOG="$LOG_DIR_PHP_SLOW/${DOMAIN_FOLDER}-slow.log"
            LOG_LABEL="PHP Slow — $DOMAIN_NAME"
            ;;
        5)
            if [ -f "/var/log/mariadb/mariadb.log" ]; then
                TARGET_LOG="/var/log/mariadb/mariadb.log"
            elif [ -f "/var/log/mysql/mysqld.log" ]; then
                TARGET_LOG="/var/log/mysql/mysqld.log"
            else
                # Try datadir
                local ERRLOG=$(find /var/lib/mysql/ -maxdepth 1 -name "*.err" 2>/dev/null | head -1)
                TARGET_LOG="$ERRLOG"
            fi
            LOG_LABEL="MariaDB / MySQL"
            ;;
        6)
            # PostgreSQL logs via journalctl or log file
            local PG_LOG=$(find /var/lib/pgsql/data/log/ -type f -name "*.log" 2>/dev/null | sort | tail -1)
            if [ -n "$PG_LOG" ] && [ -f "$PG_LOG" ]; then
                TARGET_LOG="$PG_LOG"
            else
                # Fallback: journalctl
                echo ""
                echo "  PostgreSQL Log (journalctl):"
                echo "  1) Last 50 lines"
                echo "  2) Last 100 lines"
                echo "  3) Realtime (follow)"
                echo ""
                read -p "Select: " jchoice
                case "$jchoice" in
                    1) journalctl -u postgresql --no-pager -n 50 ;;
                    2) journalctl -u postgresql --no-pager -n 100 ;;
                    3) echo "(Ctrl+C to stop)"; journalctl -u postgresql -f ;;
                    *) echo "Invalid" ;;
                esac
                pause
                return
            fi
            LOG_LABEL="PostgreSQL"
            ;;
        7)
            TARGET_LOG="/var/log/nginx/error.log"
            LOG_LABEL="Nginx Global Error"
            ;;
        *)
            echo "Invalid selection"
            pause
            return
            ;;
    esac

    if [ -z "$TARGET_LOG" ] || [ ! -f "$TARGET_LOG" ]; then
        echo ""
        echo "[WARN] Log file not found: ${TARGET_LOG:-unknown}"
        pause
        return
    fi

    local FILE_SIZE=$(du -h "$TARGET_LOG" 2>/dev/null | awk '{print $1}')
    local LINE_COUNT=$(wc -l < "$TARGET_LOG" 2>/dev/null)

    echo ""
    echo "===================================================="
    echo "  $LOG_LABEL"
    echo "  File: $TARGET_LOG"
    echo "  Size: $FILE_SIZE | Lines: $LINE_COUNT"
    echo "===================================================="
    echo ""
    echo "  1) Last 50 lines"
    echo "  2) Last 100 lines"
    echo "  3) Realtime (tail -f)"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " VIEW_MODE

    case "$VIEW_MODE" in
        1)
            echo ""
            tail -n 50 "$TARGET_LOG"
            ;;
        2)
            echo ""
            tail -n 100 "$TARGET_LOG"
            ;;
        3)
            echo ""
            echo "(Ctrl+C to stop)"
            echo ""
            tail -f "$TARGET_LOG"
            ;;
        0) return ;;
        *) echo "Invalid" ;;
    esac

    pause
}

# ===============================
# 8. SERVICE STATUS DASHBOARD
# ===============================

service_status(){
    echo ""
    echo "===================================================="
    echo "  SERVICE STATUS DASHBOARD"
    echo "===================================================="
    echo ""

    # Helper: check and print status
    _svc_check(){
        local NAME="$1"
        local SVC="$2"

        if systemctl list-unit-files 2>/dev/null | grep -q "^${SVC}"; then
            if systemctl is-active --quiet "$SVC"; then
                local MEM=$(systemctl show "$SVC" --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
                if [ -n "$MEM" ] && [ "$MEM" != "[not set]" ] && [ "$MEM" -gt 0 ] 2>/dev/null; then
                    MEM="$(( MEM / 1024 / 1024 ))MB"
                else
                    MEM=""
                fi
                printf "  \e[32m●\e[0m %-28s running %s\n" "$NAME" "$MEM"
            else
                printf "  \e[31m●\e[0m %-28s stopped\n" "$NAME"
            fi
        fi
    }

    # Nginx
    _svc_check "Nginx" "nginx"

    # PHP-FPM versions
    for v in 81 82 83 84; do
        local SVC="php${v}-php-fpm"
        if systemctl list-unit-files 2>/dev/null | grep -q "^${SVC}"; then
            local VER_DOT="${v:0:1}.${v:1}"
            # Count domains using this version
            local DCOUNT=0
            for d in "$DOMAINS_ROOT"/*/config/domain.env; do
                [ -f "$d" ] || continue
                local DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
                [ "$DPHP" = "$v" ] && ((DCOUNT++))
            done
            _svc_check "PHP-FPM $VER_DOT ($DCOUNT domains)" "$SVC"
        fi
    done

    # MariaDB
    _svc_check "MariaDB" "mariadb"

    # PostgreSQL
    _svc_check "PostgreSQL" "postgresql"

    # Valkey / Redis
    _svc_check "Valkey" "valkey"
    _svc_check "Redis" "redis"

    # Node.js / PM2
    if command -v node &>/dev/null; then
        local NODE_VER=$(node -v 2>/dev/null)
        printf "  \e[32m●\e[0m %-28s %s\n" "Node.js" "$NODE_VER"
    fi
    if command -v pm2 &>/dev/null; then
        local PM2_APPS=$(pm2 jlist 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{sum(1 for a in d if a[\"pm2_env\"][\"status\"]==\"online\")}/{len(d)}')" 2>/dev/null || echo "?")
        printf "  \e[36m●\e[0m %-28s %s apps online\n" "PM2" "$PM2_APPS"
    fi

    # Firewalld
    _svc_check "Firewalld" "firewalld"

    # Fail2Ban
    _svc_check "Fail2Ban" "fail2ban"

    # Crond
    _svc_check "Cron (crond)" "crond"

    # sshd
    _svc_check "SSH (sshd)" "sshd"

    echo ""
    echo "----------------------------------------------------"

    # Uptime
    echo "  Uptime: $(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1, $2}')"

    pause
}

# ===============================
# 9. DOMAIN HEALTH CHECK
# ===============================

domain_health_check(){
    echo ""
    echo "===================================================="
    echo "  DOMAIN HEALTH CHECK"
    echo "===================================================="
    echo ""

    local TOTAL=0
    local OK_COUNT=0
    local FAIL_COUNT=0
    local FAILED_LIST=()

    printf "  %-35s %-8s %-8s %s\n" "DOMAIN" "HTTP" "HTTPS" "TIME"
    echo "  -------------------------------------------------------------------"

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        local DN
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue

        ((TOTAL++))

        # Check HTTP via localhost with Host header (bypass DNS)
        local HTTP_CODE
        HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
            -H "Host: $DN" "http://127.0.0.1/" 2>/dev/null || echo "000")

        # Check HTTPS
        local HTTPS_CODE RESP_TIME
        local CURL_OUT
        CURL_OUT=$(curl -so /dev/null -w "%{http_code} %{time_total}" --connect-timeout 5 --max-time 10 \
            -H "Host: $DN" --resolve "${DN}:443:127.0.0.1" "https://${DN}/" -k 2>/dev/null || echo "000 0")
        HTTPS_CODE=$(echo "$CURL_OUT" | awk '{print $1}')
        RESP_TIME=$(echo "$CURL_OUT" | awk '{printf "%.2fs", $2}')

        # Determine status color
        local HTTP_COLOR HTTPS_COLOR
        case "$HTTP_CODE" in
            2*|3*) HTTP_COLOR="\e[32m" ;;  # green
            *) HTTP_COLOR="\e[31m" ;;       # red
        esac
        case "$HTTPS_CODE" in
            2*|3*) HTTPS_COLOR="\e[32m"; ((OK_COUNT++)) ;;
            *)     HTTPS_COLOR="\e[31m"; ((FAIL_COUNT++)); FAILED_LIST+=("$DN ($HTTPS_CODE)") ;;
        esac

        printf "  %-35s ${HTTP_COLOR}%-8s\e[0m ${HTTPS_COLOR}%-8s\e[0m %s\n" \
            "$DN" "$HTTP_CODE" "$HTTPS_CODE" "$RESP_TIME"
    done

    echo ""
    echo "  -------------------------------------------------------------------"
    echo "  Total: $TOTAL | OK: $OK_COUNT | Failed: $FAIL_COUNT"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo ""
        echo "  Failed domains:"
        for f in "${FAILED_LIST[@]}"; do
            echo "    ✗ $f"
        done
    fi

    pause
}

# ===============================
# 10. MYSQL SLOW QUERY LOG
# ===============================

mysql_slow_log_viewer(){
    echo ""
    echo "===================================================="
    echo "  MYSQL / MARIADB SLOW QUERY LOG"
    echo "===================================================="
    echo ""

    if ! systemctl is-active --quiet mariadb 2>/dev/null && ! systemctl is-active --quiet mysql 2>/dev/null; then
        echo "[WARN] MariaDB/MySQL is not running"
        pause; return
    fi

    # Kiểm tra slow query log có bật không
    local SLOW_LOG_ENABLED SLOW_LOG_FILE LONG_QUERY_TIME
    SLOW_LOG_ENABLED=$(mysql -N -e "SHOW VARIABLES LIKE 'slow_query_log';" 2>/dev/null | awk '{print $2}')
    SLOW_LOG_FILE=$(mysql -N -e "SHOW VARIABLES LIKE 'slow_query_log_file';" 2>/dev/null | awk '{print $2}')
    LONG_QUERY_TIME=$(mysql -N -e "SHOW VARIABLES LIKE 'long_query_time';" 2>/dev/null | awk '{print $2}')

    echo "  Slow Query Log  : ${SLOW_LOG_ENABLED:-OFF}"
    echo "  Log file        : ${SLOW_LOG_FILE:-(not set)}"
    echo "  Long Query Time : ${LONG_QUERY_TIME:-2}s"
    echo ""

    if [ "$SLOW_LOG_ENABLED" != "ON" ]; then
        echo "  [!] Slow query log is NOT enabled"
        echo ""
        read -p "  Enable slow query log now? (y/n): " ENABLE_SLOW
        if [[ "$ENABLE_SLOW" =~ ^[Yy]$ ]]; then
            read -p "  Log queries slower than (seconds) [2]: " LQT
            LQT="${LQT:-2}"
            mysql -e "
                SET GLOBAL slow_query_log = 'ON';
                SET GLOBAL long_query_time = ${LQT};
                SET GLOBAL log_queries_not_using_indexes = 'ON';
            " 2>/dev/null

            # Ghi vào my.cnf để persist sau restart
            local MYCNF="/etc/my.cnf.d/shieldpress-slow.cnf"
            cat > "$MYCNF" <<EOF
[mysqld]
slow_query_log        = 1
long_query_time       = ${LQT}
log_queries_not_using_indexes = 1
slow_query_log_file   = /var/log/mariadb/slow.log
EOF
            echo "[OK] Slow query log enabled (>= ${LQT}s)"
            SLOW_LOG_FILE="/var/log/mariadb/slow.log"
        else
            pause; return
        fi
    fi

    # Fallback file path
    [ -z "$SLOW_LOG_FILE" ] && SLOW_LOG_FILE="/var/log/mariadb/slow.log"

    if [ ! -f "$SLOW_LOG_FILE" ]; then
        echo "  [WARN] Slow query log file not found: $SLOW_LOG_FILE"
        echo "  (Log will populate when slow queries occur)"
        pause; return
    fi

    local LINE_COUNT
    LINE_COUNT=$(wc -l < "$SLOW_LOG_FILE" 2>/dev/null || echo 0)
    echo "  Log file: $SLOW_LOG_FILE ($LINE_COUNT lines)"
    echo ""
    echo "  1) Top 10 slowest queries (mysqldumpslow)"
    echo "  2) Top 10 most frequent slow queries"
    echo "  3) Last 50 lines (raw)"
    echo "  4) Last 100 lines (raw)"
    echo "  5) Query stats summary"
    echo "  6) Disable slow query log"
    echo "  0) Cancel"
    echo ""
    read -p "  Select: " VIEW_OPT

    case "$VIEW_OPT" in
        1)
            echo ""
            echo "--- TOP 10 SLOWEST QUERIES ---"
            if command -v mysqldumpslow >/dev/null 2>&1; then
                mysqldumpslow -s t -t 10 "$SLOW_LOG_FILE" 2>/dev/null
            else
                # Fallback: manual parse
                grep -A2 "Query_time" "$SLOW_LOG_FILE" 2>/dev/null | \
                    grep "Query_time" | \
                    sort -t: -k2 -rn | head -10
            fi
            ;;
        2)
            echo ""
            echo "--- TOP 10 MOST FREQUENT SLOW QUERIES ---"
            if command -v mysqldumpslow >/dev/null 2>&1; then
                mysqldumpslow -s c -t 10 "$SLOW_LOG_FILE" 2>/dev/null
            else
                grep "^SELECT\|^UPDATE\|^DELETE\|^INSERT" "$SLOW_LOG_FILE" 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -10
            fi
            ;;
        3)
            echo ""
            tail -50 "$SLOW_LOG_FILE"
            ;;
        4)
            echo ""
            tail -100 "$SLOW_LOG_FILE"
            ;;
        5)
            echo ""
            echo "--- SLOW QUERY SUMMARY ---"
            local TOTAL_SLOW
            TOTAL_SLOW=$(grep -c "# Query_time" "$SLOW_LOG_FILE" 2>/dev/null || echo 0)
            local AVG_TIME
            AVG_TIME=$(grep "Query_time:" "$SLOW_LOG_FILE" 2>/dev/null | \
                awk -F'Query_time: ' '{print $2}' | awk '{print $1}' | \
                awk '{s+=$1; n++} END{if(n>0) printf "%.2f", s/n; else print "0"}')
            local MAX_TIME
            MAX_TIME=$(grep "Query_time:" "$SLOW_LOG_FILE" 2>/dev/null | \
                awk -F'Query_time: ' '{print $2}' | awk '{print $1}' | \
                sort -rn | head -1)

            echo "  Total slow queries : $TOTAL_SLOW"
            echo "  Average query time : ${AVG_TIME:-0}s"
            echo "  Max query time     : ${MAX_TIME:-0}s"
            echo "  Log file size      : $(du -h "$SLOW_LOG_FILE" | awk '{print $1}')"
            echo ""
            echo "  Top databases with slow queries:"
            grep "^use " "$SLOW_LOG_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | \
                awk '{printf "  %-6s %s\n", $1, $2}'
            ;;
        6)
            mysql -e "SET GLOBAL slow_query_log = 'OFF';" 2>/dev/null
            rm -f "/etc/my.cnf.d/shieldpress-slow.cnf" 2>/dev/null
            echo "[OK] Slow query log disabled"
            ;;
        0) return ;;
    esac

    pause
}

# ===============================
# 10b. PHP SLOW LOG ANALYZER
# ===============================

php_slow_log_analyzer(){
    echo ""
    echo "===================================================="
    echo "  PHP SLOW LOG ANALYZER"
    echo "===================================================="

    select_domain_monitor || return

    local SLOW_LOG="$LOG_DIR_PHP_SLOW/${DOMAIN_FOLDER}-slow.log"

    if [ ! -f "$SLOW_LOG" ] || [ ! -s "$SLOW_LOG" ]; then
        echo ""
        echo "  [WARN] No PHP slow log found: $SLOW_LOG"
        echo "  PHP slow log is enabled automatically when domain is created."
        echo "  Slow requests (> 5s) will appear here."
        pause; return
    fi

    local LINE_COUNT
    LINE_COUNT=$(wc -l < "$SLOW_LOG" 2>/dev/null || echo 0)
    local ENTRY_COUNT
    ENTRY_COUNT=$(grep -c "\[pool" "$SLOW_LOG" 2>/dev/null || echo 0)

    echo ""
    echo "  Domain  : $DOMAIN_NAME"
    echo "  Log file: $SLOW_LOG"
    echo "  Entries : $ENTRY_COUNT slow requests"
    echo ""
    echo "  1) Top 10 slowest scripts"
    echo "  2) Summary stats"
    echo "  3) Last 30 entries (raw)"
    echo "  0) Cancel"
    echo ""
    read -p "  Select: " OPT

    case "$OPT" in
        1)
            echo ""
            echo "--- TOP 10 SLOWEST PHP SCRIPTS ---"
            grep "script_filename" "$SLOW_LOG" 2>/dev/null | \
                awk -F'= ' '{print $2}' | sort | uniq -c | sort -rn | head -10 | \
                awk '{printf "  %-6s %s\n", $1, $2}'
            echo ""
            echo "--- TOP 10 BY EXECUTION TIME ---"
            grep -B1 "script_filename" "$SLOW_LOG" 2>/dev/null | \
                grep "pool" | \
                awk -F'seconds, ' '{print $1}' | \
                awk '{print $NF}' | sort -rn | head -10 | \
                awk '{printf "  %.2fs\n", $1}'
            ;;
        2)
            echo ""
            echo "--- PHP SLOW LOG SUMMARY ---"
            local TOTAL MAX_TIME AVG_TIME
            TOTAL=$(grep -c "\[pool" "$SLOW_LOG" 2>/dev/null || echo 0)
            MAX_TIME=$(grep -oP '\d+\.\d+ seconds' "$SLOW_LOG" 2>/dev/null | \
                awk '{print $1}' | sort -rn | head -1)
            AVG_TIME=$(grep -oP '\d+\.\d+ seconds' "$SLOW_LOG" 2>/dev/null | \
                awk '{s+=$1; n++} END{if(n>0) printf "%.2f", s/n; else print "0"}')

            echo "  Total slow requests : $TOTAL"
            echo "  Max execution time  : ${MAX_TIME:-0}s"
            echo "  Avg execution time  : ${AVG_TIME:-0}s"
            echo ""
            echo "  Top scripts causing slowness:"
            grep "script_filename" "$SLOW_LOG" 2>/dev/null | \
                awk -F'= ' '{print $2}' | \
                sed 's|.*/public_html/||' | \
                sort | uniq -c | sort -rn | head -5 | \
                awk '{printf "  %-4s %s\n", $1, $2}'
            ;;
        3)
            echo ""
            tail -100 "$SLOW_LOG" | grep -A5 "\[pool" | head -90
            ;;
        0) return ;;
    esac

    pause
}

# ===============================
# 10. LOG ROTATE
# ===============================

rotate_logs(){
    cat > /etc/logrotate.d/shieldpress-domains << 'EOF'
/var/log/nginx/domains/*/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
}
EOF
    echo "[OK] Log rotation configured (30 days, daily, compressed)"
    pause
}

# ===============================
# 11. CLEANUP OLD LOGS
# ===============================

cleanup_logs(){
    echo ""
    read -p "Delete logs older than how many days? (default 30): " DAYS
    DAYS=${DAYS:-30}
    COUNT=$(find /var/log/nginx/domains -type f -mtime +"$DAYS" | wc -l)
    echo "Found $COUNT files older than $DAYS days"

    [ "$COUNT" -eq 0 ] && { echo "Nothing to delete."; pause; return; }

    read -p "Delete $COUNT files? (y/n): " CONFIRM
    [ "$CONFIRM" = "y" ] || { echo "Cancelled."; pause; return; }

    find /var/log/nginx/domains -type f -mtime +"$DAYS" -delete
    echo "[OK] Deleted $COUNT old log files"
    pause
}

# ===============================
# MENU
# ===============================

while true; do
    clear
    sp_header "Monitoring Center" "Traffic, logs, resources"
    sp_menu_grid \
        "1|Bandwidth per Domain|cyan" \
        "2|Attack Spike Detection|red" \
        "3|Server Resources|green" \
        "4|Log Analyzer|blue" \
        "5|Top IP Access|yellow" \
        "6|Live Log Tail|magenta" \
        "7|Log Viewer|blue" \
        "8|Service Status|green" \
        "9|Domain Health Check|cyan" \
        "10|MySQL Slow Query Log|yellow" \
        "11|PHP Slow Log Analyzer|yellow" \
        "12|Enable Log Rotation|green" \
        "13|Cleanup Old Logs|red" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1)  bandwidth_usage ;;
        2)  detect_attack ;;
        3)  check_resources ;;
        4)  log_analyzer ;;
        5)  top_ip ;;
        6)  live_log ;;
        7)  log_viewer ;;
        8)  service_status ;;
        9)  domain_health_check ;;
        10) mysql_slow_log_viewer ;;
        11) php_slow_log_analyzer ;;
        12) rotate_logs ;;
        13) cleanup_logs ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac
done
