#!/bin/bash
# ============================================================
#  ShieldPress Monitor
#  Send system metrics, file changes, and login activity
#  to ShieldPress.net monitoring dashboard
#  Compatible with ShieldPress VPS Agent v1.0
# ============================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

CONFIG_DIR="$DATA_DIR"
CONFIG_FILE="$CONFIG_DIR/shieldpress-monitor.env"
LOG_FILE="$LOG_DIR/shieldpress-monitor.log"
LOCK_FILE="/tmp/shieldpress-monitor.lock"
SERVICE_FILE="/etc/systemd/system/shieldpress-monitor.service"
TIMER_FILE="/etc/systemd/system/shieldpress-monitor.timer"
SNAPSHOT_DIR="$DATA_DIR/monitor-snapshots"
DOMAINS_ROOT="/home/domains"
AGENT_VERSION="1.0.0"

source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BLUE="\e[34m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

MAX_LOG_SIZE=10485760  # 10MB in bytes

# Truncate a single log file if it exceeds MAX_LOG_SIZE
truncate_if_oversized(){
    local file="$1"
    if [ -f "$file" ]; then
        local size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        if [ "$size" -ge "$MAX_LOG_SIZE" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') | [LOG-ROTATE] Truncated $(basename "$file") (was ${size} bytes)" > "$file"
            return 0
        fi
    fi
    return 1
}

# Rotate ShieldPress monitor log only (called on every log write)
rotate_log(){
    truncate_if_oversized "$LOG_FILE"
}

# Rotate ALL logs: ShieldPress, Nginx, PHP-FPM, website logs
rotate_all_logs(){
    local rotated=0

    # --- ShieldPress internal logs ---
    for f in "$LOG_DIR"/*.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # ShieldPress PHP slow logs
    for f in "$LOG_DIR_PHP_SLOW"/*.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # ShieldPress malware scan logs
    for f in "$LOG_DIR_MALWARE"/*.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # --- Nginx logs (per domain) ---
    for f in /var/log/nginx/domains/*/*.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # Nginx main logs
    for f in /var/log/nginx/access.log /var/log/nginx/error.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # --- PHP-FPM logs (Remi PHP 8.0–8.4) ---
    for ver in 80 81 82 83 84; do
        for f in /var/opt/remi/php${ver}/log/php-fpm/*.log; do
            [ -f "$f" ] || continue
            truncate_if_oversized "$f" && rotated=$((rotated + 1))
        done
    done

    # --- MariaDB / MySQL logs ---
    for f in /var/log/mariadb/mariadb.log /var/lib/mysql/*.err; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # --- Website application logs (Laravel, etc.) ---
    for f in "$DOMAINS_ROOT"/*/public_html/storage/logs/*.log; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # --- Mail service logs ---
    for f in /var/log/dovecot.log /var/log/dovecot-info.log /var/log/maillog; do
        [ -f "$f" ] || continue
        truncate_if_oversized "$f" && rotated=$((rotated + 1))
    done

    # --- Delete old compressed nginx logs (older than 7 days) ---
    find /var/log/nginx -name "*.log.*.gz" -mtime +7 -delete 2>/dev/null || true

    if [ "$rotated" -gt 0 ]; then
        log "[LOG-ROTATE] Rotated $rotated oversized log file(s) (limit: 10MB)"
    fi
}

log(){
    rotate_log
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}
ok(){   echo -e "${GREEN}[OK]${RESET} $1";       log "[OK] $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1";       log "[FAIL] $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1";    log "[WARN] $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

mkdir -p "$CONFIG_DIR" "$SNAPSHOT_DIR" "$LOG_DIR"

# =================================================
# LOAD CONFIG
# =================================================

load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

save_config(){
    cat > "$CONFIG_FILE" <<EOF
# ShieldPress Agent Config — do not edit manually
SHIELDPRESS_API_URL="${SHIELDPRESS_API_URL}"
SHIELDPRESS_VPS_SECRET="${SHIELDPRESS_VPS_SECRET}"
SHIELDPRESS_INTERVAL=${SHIELDPRESS_INTERVAL}
CONFIGURED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$CONFIG_FILE"
}

# =================================================
# 1. CONNECT / SETUP
# =================================================

setup_connection(){
    echo ""
    echo "========================================="
    echo "  CONNECT TO SHIELDPRESS MONITOR"
    echo "========================================="
    echo ""

    # Load existing config if available
    if load_config && [ -n "$SHIELDPRESS_VPS_SECRET" ]; then
        echo -e "  Current status: ${GREEN}Connected${RESET}"
        echo "  API URL : $SHIELDPRESS_API_URL"
        echo "  Key     : ${SHIELDPRESS_VPS_SECRET:0:12}..."
        echo "  Interval: ${SHIELDPRESS_INTERVAL}s"
        echo ""
        read -p "Reconfigure? [y/N]: " RECONF
        [[ "$RECONF" =~ ^[Yy]$ ]] || return 0
        echo ""
    fi

    SHIELDPRESS_API_URL="https://api.shieldpress.net/api/vps/metrics"

    # --- Show QR code with VPS info ---
    local VPS_NAME=$(hostname 2>/dev/null || echo "unknown")
    local VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
    local QR_CONTENT="VPS: ${VPS_NAME} | IP: ${VPS_IP}"

    if ! command -v qrencode >/dev/null 2>&1; then
        if command -v yum >/dev/null 2>&1; then
            yum install -y qrencode >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y qrencode >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get install -y qrencode >/dev/null 2>&1
        fi
    fi

    echo -e "  ${BOLD}VPS Name :${RESET} ${CYAN}${VPS_NAME}${RESET}"
    echo -e "  ${BOLD}Public IP:${RESET} ${CYAN}${VPS_IP}${RESET}"
    echo ""

    if command -v qrencode >/dev/null 2>&1; then
        echo "  Scan this QR code on the ShieldPress app:"
        echo ""
        qrencode -t ANSIUTF8 "$QR_CONTENT"
        echo ""
    else
        warn "qrencode not available. Install: yum install qrencode"
        echo ""
    fi

    # Step 1/2: Enter key & verify connection
    echo "Step 1/2 — Enter your VPS Secret Key"
    echo "  (Open ShieldPress app > VPS > Connect to get the key)"
    echo ""
    while true; do
        read -rp "  Key: " INPUT_KEY
        if [ -z "$INPUT_KEY" ]; then
            echo "  [!] Key cannot be empty."
            continue
        elif [[ ! "$INPUT_KEY" =~ ^spvps_ ]]; then
            echo "  [!] Key must start with spvps_"
            continue
        fi

        # Test connection with the API
        echo ""
        echo "  Verifying key..."
        HTTP_CODE=$(curl -s -o /tmp/sp-monitor-test.json -w "%{http_code}" \
            --connect-timeout 10 --max-time 15 \
            -X POST "$SHIELDPRESS_API_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $INPUT_KEY" \
            -d '{"shieldpress_version":"'"${AGENT_VERSION}"'","ping":true}' 2>/dev/null)

        RESPONSE=$(cat /tmp/sp-monitor-test.json 2>/dev/null)
        rm -f /tmp/sp-monitor-test.json

        if [ "$HTTP_CODE" = "200" ]; then
            ok "Connection successful!"
            SHIELDPRESS_VPS_SECRET="$INPUT_KEY"
            break
        elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
            echo "  [!] Invalid key. Please check and try again."
            echo ""
        elif [ "$HTTP_CODE" = "000" ]; then
            echo "  [!] Cannot connect to api.shieldpress.net. Check your network and try again."
            echo ""
        else
            echo "  [!] Server error (HTTP ${HTTP_CODE}): ${RESPONSE}"
            echo "  [!] Please try again."
            echo ""
        fi
    done

    # Step 2: Choose interval
    echo ""
    echo "Step 2/2 — Cron interval"
    echo ""
    echo "  [1] Every 1 minute  (recommended)"
    echo "  [2] Every 5 minutes"
    echo "  [3] Every 10 minutes"
    echo ""
    read -rp "  Choose [1/2/3] (default: 1): " INTERVAL_CHOICE

    case $INTERVAL_CHOICE in
        2) SHIELDPRESS_INTERVAL=300 ;;
        3) SHIELDPRESS_INTERVAL=600 ;;
        *) SHIELDPRESS_INTERVAL=60 ;;
    esac

    save_config
    ok "Configuration saved"
    echo ""
    echo "  API URL  : $SHIELDPRESS_API_URL"
    echo "  Key      : ${SHIELDPRESS_VPS_SECRET:0:12}..."
    echo "  Interval : ${SHIELDPRESS_INTERVAL}s"
}

# =================================================
# 2. COLLECT METRICS
# =================================================

collect_system_metrics(){
    # ——— Hostname ———
    local HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown")

    # ——— Uptime ———
    local UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)

    # ——— CPU ———
    local CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    local LOAD_1M=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    local LOAD_5M=$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo 0)
    local LOAD_15M=$(awk '{print $3}' /proc/loadavg 2>/dev/null || echo 0)

    # CPU percent from /proc/stat (1 second sample)
    local CPU_PERCENT
    local cpu1 cpu2
    cpu1=$(grep '^cpu ' /proc/stat 2>/dev/null)
    sleep 1
    cpu2=$(grep '^cpu ' /proc/stat 2>/dev/null)

    if [ -z "$cpu1" ] || [ -z "$cpu2" ]; then
        CPU_PERCENT=$(echo "$LOAD_1M" "$CPU_CORES" | awk '{v=($1/$2)*100; if(v>100) v=100; printf "%.1f", v}')
    else
        CPU_PERCENT=$(printf '%s\n%s\n' "$cpu1" "$cpu2" | awk '
            NR==1 { u1=$2; n1=$3; s1=$4; i1=$5; w1=$6; q1=$7; sq1=$8; st1=$9 }
            NR==2 {
                u2=$2; n2=$3; s2=$4; i2=$5; w2=$6; q2=$7; sq2=$8; st2=$9
                total1=u1+n1+s1+i1+w1+q1+sq1+st1
                total2=u2+n2+s2+i2+w2+q2+sq2+st2
                idle1=i1+w1
                idle2=i2+w2
                dt=total2-total1
                di=idle2-idle1
                if(dt>0) printf "%.1f", (1-di/dt)*100
                else print "0.0"
            }')
    fi

    # ——— Memory ———
    local MEM_TOTAL_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 0)
    local MEM_USED_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $3}' || echo 0)
    local MEM_AVAILABLE_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}' || echo 0)
    local SWAP_TOTAL_MB=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}' || echo 0)
    local SWAP_USED_MB=$(free -m 2>/dev/null | awk '/^Swap:/ {print $3}' || echo 0)

    # ——— Disk ———
    local DISK_TOTAL_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $2}' || echo 0)
    local DISK_USED_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $3}' || echo 0)
    local DISK_PERCENT=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo 0)

    # ——— Network + Disk I/O (combined 1s sample) ———
    local NET_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")

    local disk_dev=$(lsblk -ndo NAME 2>/dev/null | head -1)
    [ -z "$disk_dev" ] && disk_dev="sda"

    local rx1 tx1 rx2 tx2 dr1 dw1 dr2 dw2
    rx1=$(cat /sys/class/net/$NET_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/$NET_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    dr1=$(awk -v dev="$disk_dev" '$3==dev {print $6}' /proc/diskstats 2>/dev/null || echo 0)
    dw1=$(awk -v dev="$disk_dev" '$3==dev {print $10}' /proc/diskstats 2>/dev/null || echo 0)
    sleep 1
    rx2=$(cat /sys/class/net/$NET_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/$NET_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
    dr2=$(awk -v dev="$disk_dev" '$3==dev {print $6}' /proc/diskstats 2>/dev/null || echo 0)
    dw2=$(awk -v dev="$disk_dev" '$3==dev {print $10}' /proc/diskstats 2>/dev/null || echo 0)
    local NET_RX_KBPS=$(( (rx2 - rx1) / 1024 ))
    local NET_TX_KBPS=$(( (tx2 - tx1) / 1024 ))
    local DISK_READ_KBPS=$(( (dr2 - dr1) / 2 ))
    local DISK_WRITE_KBPS=$(( (dw2 - dw1) / 2 ))
    [ "$DISK_READ_KBPS" -lt 0 ] 2>/dev/null && DISK_READ_KBPS=0
    [ "$DISK_WRITE_KBPS" -lt 0 ] 2>/dev/null && DISK_WRITE_KBPS=0

    local TCP_CONNECTIONS=$(ss -t state established 2>/dev/null | tail -n +2 | wc -l || echo 0)

    # ——— Public IP ———
    local PUBLIC_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    local PRIVATE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

    # ——— Services ———
    check_service() {
        if systemctl is-active --quiet "$1" 2>/dev/null; then
            echo "running"
        elif pgrep -x "$1" >/dev/null 2>&1; then
            echo "running"
        else
            echo "stopped"
        fi
    }

    local SVC_NGINX=$(check_service nginx)
    local SVC_APACHE=$(check_service apache2)
    [ "$SVC_APACHE" = "stopped" ] && SVC_APACHE=$(check_service httpd)
    local SVC_MYSQL=$(check_service mysql)
    [ "$SVC_MYSQL" = "stopped" ] && SVC_MYSQL=$(check_service mysqld)
    [ "$SVC_MYSQL" = "stopped" ] && SVC_MYSQL=$(check_service mariadb)
    local SVC_POSTGRESQL=$(check_service postgresql)
    local SVC_REDIS=$(check_service redis-server)
    [ "$SVC_REDIS" = "stopped" ] && SVC_REDIS=$(check_service redis)
    local SVC_DOCKER=$(check_service docker)
    local SVC_SSHD=$(check_service sshd)

    # ——— OS Info ———
    local OS_NAME OS_VERSION OS_KERNEL OS_ARCH
    if [ -f /etc/os-release ]; then
        OS_NAME=$(. /etc/os-release && echo "$NAME")
        OS_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    elif [ -f /etc/redhat-release ]; then
        OS_NAME=$(cat /etc/redhat-release)
        OS_VERSION=""
    else
        OS_NAME="unknown"
        OS_VERSION=""
    fi
    OS_KERNEL=$(uname -r 2>/dev/null || echo "")
    OS_ARCH=$(uname -m 2>/dev/null || echo "")

    # ——— CPU Model ———
    local CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ ]*//' || echo "")

    # ——— Valkey/Redis service detection ———
    [ "$SVC_REDIS" = "stopped" ] && SVC_REDIS=$(check_service valkey)
    [ "$SVC_REDIS" = "stopped" ] && SVC_REDIS=$(check_service valkey-server)

    # Export variables for JSON builder
    echo "$HOSTNAME_VAL|$UPTIME_SECONDS|$CPU_CORES|$LOAD_1M|$LOAD_5M|$LOAD_15M|$CPU_PERCENT|$MEM_TOTAL_MB|$MEM_USED_MB|$MEM_AVAILABLE_MB|$SWAP_TOTAL_MB|$SWAP_USED_MB|$DISK_TOTAL_KB|$DISK_USED_KB|$DISK_PERCENT|$TCP_CONNECTIONS|$NET_RX_KBPS|$NET_TX_KBPS|$PUBLIC_IP|$PRIVATE_IP|$SVC_NGINX|$SVC_APACHE|$SVC_MYSQL|$SVC_POSTGRESQL|$SVC_REDIS|$SVC_DOCKER|$SVC_SSHD|$OS_NAME|$OS_VERSION|$OS_KERNEL|$OS_ARCH|$CPU_MODEL|$DISK_READ_KBPS|$DISK_WRITE_KBPS"
}

# =================================================
# 2b. COLLECT SOFTWARE VERSIONS
# =================================================

collect_versions_json(){
    local ver_json='{'
    local first=true

    _add_ver(){
        local key="$1" val="$2"
        [ -z "$val" ] && return
        $first && first=false || ver_json+=','
        ver_json+="\"$key\":\"$val\""
    }

    _add_ver "nginx" "$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    _add_ver "apache" "$(apache2 -v 2>/dev/null | grep -oE 'Apache/[0-9.]+' | head -1 | sed 's/Apache\///' || httpd -v 2>/dev/null | grep -oE 'Apache/[0-9.]+' | head -1 | sed 's/Apache\///')"
    _add_ver "litespeed" "$([ -x /usr/local/lsws/bin/lshttpd ] && /usr/local/lsws/bin/lshttpd -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    _add_ver "mysql" "$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    _add_ver "mariadb" "$(mariadb --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    _add_ver "postgresql" "$(psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    _add_ver "redis" "$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | sed 's/v=//' || valkey-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | sed 's/v=//')"
    _add_ver "nodejs" "$(node --version 2>/dev/null | sed 's/^v//')"
    _add_ver "python" "$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    _add_ver "docker" "$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    _add_ver "composer" "$(composer --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    _add_ver "npm" "$(npm --version 2>/dev/null | head -1)"
    _add_ver "git" "$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    _add_ver "openssl" "$(openssl version 2>/dev/null | awk '{print $2}')"
    _add_ver "curl" "$(curl --version 2>/dev/null | head -1 | awk '{print $2}')"

    # PHP-FPM versions
    local php_arr='['
    local pfirst=true
    for ver in 84 83 82 81 80 74; do
        local dot_ver="${ver:0:1}.${ver:1}"
        local status="stopped"
        for svc in "php${ver}-php-fpm" "php${dot_ver}-fpm" "php-fpm"; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                status="running"; break
            fi
        done
        # Only include versions that have a binary installed
        if [ -x "/opt/remi/php${ver}/root/usr/bin/php" ]; then
            $pfirst && pfirst=false || php_arr+=','
            php_arr+="{\"version\":\"$dot_ver\",\"status\":\"$status\"}"
        fi
    done
    php_arr+=']'

    ver_json+=",\"php_versions\":$php_arr}"
    echo "$ver_json"
}

# =================================================
# 2c. COLLECT SECURITY CONFIG
# =================================================

collect_security_config_json(){
    local fw_type="none" fw_status="inactive"
    if command -v ufw >/dev/null 2>&1; then
        fw_type="ufw"
        ufw status 2>/dev/null | grep -qi "active" && fw_status="active" || fw_status="inactive"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        fw_type="firewalld"
        firewall-cmd --state 2>/dev/null | grep -qi "running" && fw_status="active" || fw_status="inactive"
    elif command -v iptables >/dev/null 2>&1; then
        fw_type="iptables"
        local rule_count=$(iptables -L -n 2>/dev/null | wc -l)
        [ "$rule_count" -gt 8 ] 2>/dev/null && fw_status="active" || fw_status="minimal"
    fi

    local selinux="disabled"
    command -v getenforce >/dev/null 2>&1 && selinux=$(getenforce 2>/dev/null || echo "disabled")

    local apparmor="not_installed"
    if command -v aa-status >/dev/null 2>&1; then
        aa-status 2>/dev/null | grep -q "profiles are loaded" && apparmor="enabled" || apparmor="disabled"
    elif [ -d /sys/module/apparmor ]; then
        apparmor="loaded"
    fi

    local open_files=$(ulimit -n 2>/dev/null || echo 0)
    local max_procs=$(ulimit -u 2>/dev/null || echo 0)
    local ntp_synced="unknown"
    command -v timedatectl >/dev/null 2>&1 && timedatectl 2>/dev/null | grep -qi "synchronized: yes" && ntp_synced="yes" || ntp_synced="no"
    local tz=$(date +%Z 2>/dev/null || echo "UTC")

    echo "{\"firewall_type\":\"$fw_type\",\"firewall_status\":\"$fw_status\",\"selinux\":\"$selinux\",\"apparmor\":\"$apparmor\",\"open_files_limit\":$open_files,\"max_processes\":$max_procs,\"ntp_synced\":\"$ntp_synced\",\"timezone\":\"$tz\"}"
}

# =================================================
# 2d. COLLECT TOP PROCESSES
# =================================================

collect_top_processes_json(){
    local arr='['
    local first=true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local user cpu mem pid cmd
        read -r user pid cpu mem _ _ _ _ _ _ cmd <<< "$line"
        [ -z "$pid" ] && continue
        # JSON-escape command
        cmd=$(echo "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g' | head -c 200)
        $first && first=false || arr+=','
        arr+="{\"pid\":$pid,\"user\":\"$user\",\"cpu\":$cpu,\"mem\":$mem,\"cmd\":\"$cmd\"}"
    done < <(ps aux --sort=-%cpu 2>/dev/null | head -16 | tail -15)
    arr+=']'
    echo "$arr"
}

# =================================================
# 2e. COLLECT LISTENING PORTS
# =================================================

collect_listening_ports_json(){
    local arr='['
    local first=true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local port=$(echo "$line" | awk '{print $4}' | grep -oE '[0-9]+$')
        local proc=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        [ -z "$port" ] && continue
        $first && first=false || arr+=','
        arr+="{\"port\":$port,\"process\":\"${proc:-unknown}\"}"
    done < <(ss -tlnp 2>/dev/null | tail -n +2 | head -30)
    arr+=']'
    echo "$arr"
}

# =================================================
# 2f. COLLECT DOCKER CONTAINERS
# =================================================

collect_docker_containers_json(){
    local arr='['
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local first=true
        while IFS='|' read -r name image status ports; do
            [ -z "$name" ] && continue
            $first && first=false || arr+=','
            arr+="{\"name\":\"$name\",\"image\":\"$image\",\"status\":\"$status\",\"ports\":\"$ports\"}"
        done < <(docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null | head -20)
    fi
    arr+=']'
    echo "$arr"
}

# =================================================
# 2g. COLLECT EXTENDED LOGINS
# =================================================

collect_current_users_json(){
    local arr='['
    local first=true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local user tty login_time from
        user=$(echo "$line" | awk '{print $1}')
        tty=$(echo "$line" | awk '{print $2}')
        login_time=$(echo "$line" | awk '{print $3, $4}')
        from=$(echo "$line" | awk '{print $5}' | tr -d '()')
        $first && first=false || arr+=','
        arr+="{\"user\":\"$user\",\"tty\":\"$tty\",\"login_time\":\"$login_time\",\"from\":\"$from\"}"
    done < <(who 2>/dev/null | head -10)
    arr+=']'
    echo "$arr"
}

collect_recent_logins_json(){
    local arr='['
    local first=true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | grep -qiE "reboot|wtmp begins" && continue
        local user ip date_str active
        user=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $3}')
        date_str=$(echo "$line" | awk '{print $4, $5, $6, $7}')
        active=$(echo "$line" | awk '{for(i=8;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        $first && first=false || arr+=','
        arr+="{\"user\":\"$user\",\"ip\":\"$ip\",\"date\":\"$date_str\",\"active\":\"$active\"}"
    done < <(last -10 2>/dev/null)
    arr+=']'
    echo "$arr"
}

# =================================================
# 2h. COLLECT SERVER LOGS (last 50 lines each)
# =================================================

_read_log(){
    local result=""
    for f in "$@"; do
        if [ -f "$f" ] && [ -r "$f" ]; then
            result=$(tail -50 "$f" 2>/dev/null)
            break
        fi
    done
    echo "$result"
}

_read_journalctl_log(){
    local unit="$1"
    journalctl -u "$unit" -n 50 --no-pager 2>/dev/null || true
}

collect_logs_json(){
    # Collect raw log text, then let python3 JSON-encode them safely
    local nginx_err=$(_read_log /var/log/nginx/error.log /var/log/nginx/error.log.1)
    local nginx_acc=$(_read_log /var/log/nginx/access.log /var/log/nginx/access.log.1)
    local apache_err=$(_read_log /var/log/apache2/error.log /var/log/httpd/error_log)
    local apache_acc=$(_read_log /var/log/apache2/access.log /var/log/httpd/access_log)
    local mysql_log=$(_read_log /var/log/mysql/error.log /var/log/mysqld.log /var/log/mariadb/mariadb.log)
    local mysql_slow=$(_read_log /var/log/mysql/mysql-slow.log /var/log/mysql/slow.log /var/log/mysqld-slow.log /var/log/mariadb/slow.log)
    local redis_log=$(_read_log /var/log/redis/redis-server.log /var/log/redis.log /var/log/redis/redis.log)
    [ -z "$redis_log" ] && redis_log=$(_read_journalctl_log redis-server)
    [ -z "$redis_log" ] && redis_log=$(_read_journalctl_log redis)
    local fail2ban_log=$(_read_log /var/log/fail2ban.log /var/log/fail2ban.log.1)
    [ -z "$fail2ban_log" ] && fail2ban_log=$(_read_journalctl_log fail2ban)
    local syslog_log=""
    if command -v journalctl >/dev/null 2>&1; then
        syslog_log=$(journalctl --no-pager -n 50 2>/dev/null)
    else
        syslog_log=$(_read_log /var/log/syslog /var/log/messages)
    fi

    # PHP-FPM log: try versioned first, then generic
    local php_fpm_log=""
    for ver in 84 83 82 81 80 74; do
        local dot_ver="${ver:0:1}.${ver:1}"
        php_fpm_log=$(_read_log "/var/opt/remi/php${ver}/log/php-fpm/error.log" "/var/log/php${dot_ver}-fpm.log" "/var/log/php-fpm-${dot_ver}.log")
        [ -n "$php_fpm_log" ] && break
    done
    [ -z "$php_fpm_log" ] && php_fpm_log=$(_read_log /var/log/php-fpm/error.log /var/log/php-fpm.log /var/log/php_errors.log)

    # Export for python to pick up as env-like variables
    export _LOG_NGINX_ERR="$nginx_err"
    export _LOG_NGINX_ACC="$nginx_acc"
    export _LOG_APACHE_ERR="$apache_err"
    export _LOG_APACHE_ACC="$apache_acc"
    export _LOG_MYSQL="$mysql_log"
    export _LOG_MYSQL_SLOW="$mysql_slow"
    export _LOG_REDIS="$redis_log"
    export _LOG_FAIL2BAN="$fail2ban_log"
    export _LOG_SYSLOG="$syslog_log"
    export _LOG_PHP_FPM="$php_fpm_log"

    python3 -c "
import json, os
def to_arr(env_key):
    val = os.environ.get(env_key, '')
    if not val.strip():
        return []
    return val.strip().split('\n')
logs = {
    'nginx_error': to_arr('_LOG_NGINX_ERR'),
    'nginx_access': to_arr('_LOG_NGINX_ACC'),
    'apache_error': to_arr('_LOG_APACHE_ERR'),
    'apache_access': to_arr('_LOG_APACHE_ACC'),
    'mysql': to_arr('_LOG_MYSQL'),
    'mysql_slow': to_arr('_LOG_MYSQL_SLOW'),
    'redis': to_arr('_LOG_REDIS'),
    'php_fpm': to_arr('_LOG_PHP_FPM'),
    'fail2ban': to_arr('_LOG_FAIL2BAN'),
    'syslog': to_arr('_LOG_SYSLOG')
}
print(json.dumps(logs))
" 2>/dev/null || echo '{}'

    # Cleanup env
    unset _LOG_NGINX_ERR _LOG_NGINX_ACC _LOG_APACHE_ERR _LOG_APACHE_ACC _LOG_MYSQL _LOG_MYSQL_SLOW _LOG_REDIS _LOG_FAIL2BAN _LOG_SYSLOG _LOG_PHP_FPM
}

# =================================================
# 3. FILE CHANGE TRACKING
# =================================================

# Detect sensitive files modified in last hour
detect_file_changes(){
    local FILE_CHANGE_LINES=""
    if command -v find >/dev/null 2>&1; then
        FILE_CHANGE_LINES=$(find /etc /var/www "$DOMAINS_ROOT" -maxdepth 3 -type f \( -name "*.php" -o -name ".env" -o -name ".htaccess" -o -name "*.conf" \) -mmin -60 2>/dev/null | head -20 || true)
    fi
    echo "$FILE_CHANGE_LINES"
}

# =================================================
# 4. LOGIN TRACKING
# =================================================

# Detect failed SSH logins (last 1 hour)
detect_failed_logins(){
    local LOGIN_LINES=""
    if command -v journalctl >/dev/null 2>&1; then
        LOGIN_LINES=$(journalctl -u sshd --since "1 hour ago" --no-pager 2>/dev/null | grep -i "Failed password" | tail -10 || true)
    elif [ -f /var/log/auth.log ]; then
        LOGIN_LINES=$(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -10 || true)
    elif [ -f /var/log/secure ]; then
        LOGIN_LINES=$(grep "Failed password" /var/log/secure 2>/dev/null | tail -10 || true)
    fi
    echo "$LOGIN_LINES"
}

# =================================================
# 5. SEND DATA TO API
# =================================================

send_metrics(){
    load_config || {
        log "Config not found, skipping send"
        return 1
    }

    [ -z "$SHIELDPRESS_VPS_SECRET" ] && {
        log "No secret key configured"
        return 1
    }

    # Rotate all oversized logs before collecting metrics
    rotate_all_logs

    # Collect system metrics (pipe-delimited string)
    local METRICS_RAW=$(collect_system_metrics)

    IFS='|' read -r HOSTNAME_VAL UPTIME_SECONDS CPU_CORES LOAD_1M LOAD_5M LOAD_15M CPU_PERCENT \
        MEM_TOTAL_MB MEM_USED_MB MEM_AVAILABLE_MB SWAP_TOTAL_MB SWAP_USED_MB \
        DISK_TOTAL_KB DISK_USED_KB DISK_PERCENT TCP_CONNECTIONS NET_RX_KBPS NET_TX_KBPS \
        PUBLIC_IP PRIVATE_IP SVC_NGINX SVC_APACHE SVC_MYSQL SVC_POSTGRESQL SVC_REDIS SVC_DOCKER SVC_SSHD \
        OS_NAME OS_VERSION OS_KERNEL OS_ARCH CPU_MODEL DISK_READ_KBPS DISK_WRITE_KBPS \
        <<< "$METRICS_RAW"

    # Collect extended data
    local VERSIONS_JSON=$(collect_versions_json)
    local SECURITY_JSON=$(collect_security_config_json)
    local TOP_PROCS_JSON=$(collect_top_processes_json)
    local LISTEN_PORTS_JSON=$(collect_listening_ports_json)
    local DOCKER_JSON=$(collect_docker_containers_json)
    local CURRENT_USERS_JSON=$(collect_current_users_json)
    local RECENT_LOGINS_JSON=$(collect_recent_logins_json)
    local LOGS_JSON=$(collect_logs_json)

    # Collect failed logins
    local LOGIN_LINES=$(detect_failed_logins)

    # Collect file changes
    local FILE_CHANGE_LINES=$(detect_file_changes)

    # Collect all site health (HTTP status codes)
    local SITE_HEALTH=""
    for env_file in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env_file" ] || continue
        local domain=$(grep "^DOMAIN=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$domain" ] && continue
        local clean_dir=$(dirname "$(dirname "$env_file")")
        local docroot="$clean_dir/public_html"
        local site_type="static"
        [ -f "$docroot/wp-config.php" ] && site_type="wordpress"
        [ -f "$docroot/artisan" ] && site_type="laravel"
        local site_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 3 --max-time 5 \
            -H "User-Agent: ShieldPress-Monitor/1.0" \
            "https://${domain}/" 2>/dev/null)
        [ "$site_code" = "000" ] && site_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 3 --max-time 5 \
            -H "User-Agent: ShieldPress-Monitor/1.0" \
            "http://${domain}/" 2>/dev/null)
        SITE_HEALTH="${SITE_HEALTH}${domain}:${site_code}:${site_type}\n"
    done

    # Build JSON with Python3 (safe, no escaping issues)
    local PAYLOAD_FILE="/tmp/shieldpress_payload_$$.json"

    python3 -c "
import json, sys

# Parse failed logins
logins = []
for line in '''${LOGIN_LINES}'''.strip().split('\n'):
    line = line.strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) >= 11:
        logins.append({'user': parts[8], 'ip': parts[10], 'time': ' '.join(parts[:3])})

# Parse file changes
changes = []
for path in '''${FILE_CHANGE_LINES}'''.strip().split('\n'):
    path = path.strip()
    if not path:
        continue
    ext = path.rsplit('.', 1)[-1] if '.' in path else ''
    changes.append({'path': path, 'ext': ext, 'type': 'modified'})

# Parse site health
sites = []
for line in '''$(echo -e "$SITE_HEALTH")'''.strip().split('\n'):
    line = line.strip()
    if not line or ':' not in line:
        continue
    parts = line.split(':')
    if len(parts) >= 3:
        domain, code, site_type = parts[0], parts[1], parts[2]
    elif len(parts) == 2:
        domain, code, site_type = parts[0], parts[1], 'unknown'
    else:
        continue
    try:
        code = int(code)
    except ValueError:
        code = 0
    sites.append({'domain': domain, 'http_status': code, 'type': site_type, 'healthy': 200 <= code < 400})

# Parse pre-built JSON data from bash helpers
import json as _json
try:
    versions_data = _json.loads('''${VERSIONS_JSON}''')
except:
    versions_data = {}
try:
    security_data = _json.loads('''${SECURITY_JSON}''')
except:
    security_data = {}
try:
    top_procs_data = _json.loads('''${TOP_PROCS_JSON}''')
except:
    top_procs_data = []
try:
    listen_ports_data = _json.loads('''${LISTEN_PORTS_JSON}''')
except:
    listen_ports_data = []
try:
    docker_data = _json.loads('''${DOCKER_JSON}''')
except:
    docker_data = []
try:
    current_users_data = _json.loads('''${CURRENT_USERS_JSON}''')
except:
    current_users_data = []
try:
    recent_logins_data = _json.loads('''${RECENT_LOGINS_JSON}''')
except:
    recent_logins_data = []
try:
    logs_data = _json.loads('''${LOGS_JSON}''')
except:
    logs_data = {}

payload = {
    'shieldpress_version': '${AGENT_VERSION}',
    'metrics': {
        'hostname': '${HOSTNAME_VAL}',
        'timestamp': '$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")',
        'uptime_seconds': ${UPTIME_SECONDS:-0},
        'publicIp': '${PUBLIC_IP}',
        'privateIp': '${PRIVATE_IP}',
        'os': {
            'name': '${OS_NAME}',
            'version': '${OS_VERSION}',
            'kernel': '${OS_KERNEL}',
            'arch': '${OS_ARCH}'
        },
        'cpu': {
            'cores': ${CPU_CORES:-1},
            'model': '${CPU_MODEL}',
            'load_1m': ${LOAD_1M:-0},
            'load_5m': ${LOAD_5M:-0},
            'load_15m': ${LOAD_15M:-0},
            'percent': ${CPU_PERCENT:-0}
        },
        'cpuPercent': ${CPU_PERCENT:-0},
        'memory': {
            'total_mb': ${MEM_TOTAL_MB:-0},
            'used_mb': ${MEM_USED_MB:-0},
            'available_mb': ${MEM_AVAILABLE_MB:-0},
            'swap_total_mb': ${SWAP_TOTAL_MB:-0},
            'swap_used_mb': ${SWAP_USED_MB:-0}
        },
        'disk': {
            'total_kb': ${DISK_TOTAL_KB:-0},
            'used_kb': ${DISK_USED_KB:-0},
            'percent': ${DISK_PERCENT:-0},
            'read_kbps': ${DISK_READ_KBPS:-0},
            'write_kbps': ${DISK_WRITE_KBPS:-0}
        },
        'network': {
            'tcp_connections': ${TCP_CONNECTIONS:-0}
        },
        'networkRxKbps': ${NET_RX_KBPS:-0},
        'networkTxKbps': ${NET_TX_KBPS:-0},
        'services': {
            'nginx': '${SVC_NGINX:-stopped}',
            'apache': '${SVC_APACHE:-stopped}',
            'mysql': '${SVC_MYSQL:-stopped}',
            'postgresql': '${SVC_POSTGRESQL:-stopped}',
            'redis': '${SVC_REDIS:-stopped}',
            'docker': '${SVC_DOCKER:-stopped}',
            'sshd': '${SVC_SSHD:-stopped}'
        },
        'versions': versions_data,
        'security_config': security_data,
        'top_processes': top_procs_data,
        'listening_ports': listen_ports_data,
        'docker_containers': docker_data
    },
    'logins': {
        'failed_logins': logins,
        'current_users': current_users_data,
        'recent_logins': recent_logins_data
    },
    'file_changes': changes,
    'site_health': sites,
    'logs': logs_data
}

with open('${PAYLOAD_FILE}', 'w') as f:
    json.dump(payload, f)
" 2>/dev/null

    if [ ! -f "$PAYLOAD_FILE" ]; then
        log "ERROR: Failed to build JSON payload"
        return 1
    fi

    # Send to ShieldPress
    log "Sending metrics to ${SHIELDPRESS_API_URL}..."

    local RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 \
        -X POST "${SHIELDPRESS_API_URL}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${SHIELDPRESS_VPS_SECRET}" \
        -d @"${PAYLOAD_FILE}" 2>&1)

    rm -f "$PAYLOAD_FILE"

    local HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    local BODY=$(echo "$RESPONSE" | head -n -1)

    if [ "$HTTP_CODE" = "200" ]; then
        log "Metrics sent OK — ${BODY}"
        return 0
    else
        log "Metrics send failed (HTTP ${HTTP_CODE}) — ${BODY}"
        return 1
    fi
}

# =================================================
# 6. REMOTE COMMANDS (pull model — VPS polls API)
# =================================================
# Security:
#   - VPS initiates all connections (no inbound ports)
#   - Strict command whitelist (no arbitrary shell)
#   - Each command has ID + HMAC signature
#   - Results reported back to API
#   - All actions logged locally

COMMANDS_URL="https://api.shieldpress.net/api/vps/commands"

# ── Whitelisted commands ──────────────────────────
# Only these actions can be executed remotely.
# Format: action → handler function

execute_remote_command(){
    local action="$1"
    local domain="$2"     # optional, for domain-scoped actions
    local params="$3"     # optional JSON params

    case "$action" in

        # ─── Service management ───
        restart_nginx)
            nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null \
                && echo "Nginx restarted" || echo "FAIL: Nginx restart failed"
            ;;
        reload_nginx)
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null \
                && echo "Nginx reloaded" || echo "FAIL: Nginx reload failed"
            ;;
        restart_php_fpm)
            _cmd_restart_php_fpm "$domain"
            ;;
        restart_mariadb)
            systemctl restart mariadb 2>/dev/null \
                && echo "MariaDB restarted" || echo "FAIL: MariaDB restart failed"
            ;;
        restart_redis)
            local svc=""
            for _s in valkey valkey-server redis redis-server; do
                if systemctl is-active --quiet "$_s" 2>/dev/null; then
                    svc="$_s"; break
                fi
            done
            if [ -z "$svc" ]; then
                # Not active, try to find an installed unit
                for _s in valkey valkey-server redis redis-server; do
                    if systemctl list-unit-files "${_s}.service" 2>/dev/null | grep -q "$_s"; then
                        svc="$_s"; break
                    fi
                done
            fi
            [ -z "$svc" ] && { echo "FAIL: No Redis/Valkey service found"; break; }
            systemctl restart "$svc" 2>/dev/null \
                && echo "$svc restarted" || echo "FAIL: $svc restart failed"
            ;;

        # ─── Cache management ───
        clear_opcache)
            _cmd_clear_opcache "$domain"
            ;;
        clear_file_cache)
            _cmd_clear_file_cache "$domain"
            ;;
        clear_redis)
            local cli=""
            command -v valkey-cli >/dev/null 2>&1 && cli="valkey-cli"
            [ -z "$cli" ] && command -v redis-cli >/dev/null 2>&1 && cli="redis-cli"
            if [ -n "$cli" ]; then
                local redis_pass=""
                [ -f "$DATA_DIR/.valkey_auth" ] && redis_pass=$(grep "^VALKEY_PASS=" "$DATA_DIR/.valkey_auth" | cut -d= -f2)
                if [ -n "$redis_pass" ]; then
                    $cli -a "$redis_pass" FLUSHALL 2>/dev/null && echo "Redis/Valkey flushed" || echo "FAIL: flush failed"
                else
                    $cli FLUSHALL 2>/dev/null && echo "Redis/Valkey flushed" || echo "FAIL: flush failed"
                fi
            else
                echo "SKIP: valkey-cli/redis-cli not found"
            fi
            ;;
        clear_nginx_cache)
            if [ -d /var/cache/nginx ]; then
                if [ -n "$domain" ]; then
                    local clean_d=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
                    if [ -d "/var/cache/nginx/${clean_d}" ]; then
                        find "/var/cache/nginx/${clean_d}" -type f -delete 2>/dev/null
                        echo "Nginx cache cleared for $domain"
                    else
                        echo "SKIP: No cache directory for $domain"
                    fi
                else
                    find /var/cache/nginx -type f -delete 2>/dev/null
                    echo "Nginx cache cleared (all domains)"
                fi
            else
                echo "SKIP: No Nginx cache directory"
            fi
            ;;
        clear_all_cache)
            local results=""
            results+="$(_cmd_clear_opcache "$domain"); "
            results+="$(_cmd_clear_file_cache "$domain"); "
            results+="$(execute_remote_command clear_redis); "
            results+="$(execute_remote_command clear_nginx_cache); "
            echo "$results"
            ;;

        # ─── WordPress management ───
        wp_maintenance_on)
            _cmd_wp_maintenance "$domain" "on"
            ;;
        wp_maintenance_off)
            _cmd_wp_maintenance "$domain" "off"
            ;;
        wp_update_core)
            _cmd_wp_cli "$domain" "core update"
            ;;
        wp_update_plugins)
            _cmd_wp_cli "$domain" "plugin update --all"
            ;;
        wp_update_themes)
            _cmd_wp_cli "$domain" "theme update --all"
            ;;
        wp_clear_transients)
            _cmd_wp_cli "$domain" "transient delete --all"
            ;;

        # ─── Recovery ───
        auto_recovery)
            if [ -x /opt/shieldpress/modules/wordpress/wp-auto-recovery.sh ]; then
                bash /opt/shieldpress/modules/wordpress/wp-auto-recovery.sh --scan 2>&1 | tail -5
            else
                echo "FAIL: auto-recovery script not found"
            fi
            ;;

        *)
            echo "REJECTED: Unknown command '$action'"
            return 1
            ;;
    esac
}

# ── Helper: Restart PHP-FPM for a domain ──────────
_cmd_restart_php_fpm(){
    local domain="$1"
    local php_ver=""

    if [ -n "$domain" ]; then
        local clean=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
        local env_file="$DOMAINS_ROOT/$clean/config/domain.env"
        [ -f "$env_file" ] && php_ver=$(grep "^PHP_VERSION=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:]')
    fi

    if [ -z "$php_ver" ]; then
        # Restart all active PHP-FPM services
        local restarted=""
        for svc in $(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | grep "php.*fpm" | awk '{print $1}'); do
            systemctl restart "$svc" 2>/dev/null && restarted="${restarted}${svc} "
        done
        [ -n "$restarted" ] && echo "Restarted: $restarted" || echo "FAIL: No PHP-FPM services found"
        return
    fi

    local short=$(echo "$php_ver" | tr -d '.')
    for svc in "php${short}-php-fpm" "php${php_ver}-fpm" "php-fpm"; do
        if systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc"; then
            systemctl restart "$svc" 2>/dev/null && echo "$svc restarted" && return
        fi
    done
    echo "FAIL: PHP-FPM service not found for $php_ver"
}

# ── Helper: Clear OPcache ─────────────────────────
# NOTE: opcache_reset() from CLI only resets the CLI process's cache, NOT PHP-FPM's.
# Must reload/restart PHP-FPM to actually clear the web OPcache.
_cmd_clear_opcache(){
    local domain="$1"
    local restarted=""

    if [ -n "$domain" ]; then
        local clean=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
        local env_file="$DOMAINS_ROOT/$clean/config/domain.env"
        if [ -f "$env_file" ]; then
            local ver=$(grep "^PHP_VERSION=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:].')
            for svc in "php${ver}-php-fpm" "php${ver}-fpm"; do
                if systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc"; then
                    systemctl reload "$svc" 2>/dev/null && restarted="$svc" && break
                fi
            done
        fi
    fi

    if [ -z "$restarted" ]; then
        # Reload all running PHP-FPM services
        for ver in 84 83 82 81 80 74; do
            local svc="php${ver}-php-fpm"
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                systemctl reload "$svc" 2>/dev/null && restarted+="$svc "
            fi
        done
    fi

    [ -n "$restarted" ] && echo "OPcache cleared (reloaded: $restarted)" || echo "SKIP: No PHP-FPM service found to reload"
}

# ── Helper: Clear file cache ─────────────────────
_cmd_clear_file_cache(){
    local domain="$1"

    if [ -z "$domain" ]; then
        # Clear cache for all domains
        local count=0
        for cache_dir in "$DOMAINS_ROOT"/*/public_html/wp-content/cache; do
            [ -d "$cache_dir" ] || continue
            find "$cache_dir" -type f \( -name "*.php" -o -name "*.html" -o -name "*.gz" -o -name "*.json" \) -delete 2>/dev/null
            count=$((count + 1))
        done
        echo "File cache cleared for $count site(s)"
        return
    fi

    local clean=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
    local cache_dir="$DOMAINS_ROOT/$clean/public_html/wp-content/cache"
    if [ -d "$cache_dir" ]; then
        find "$cache_dir" -type f \( -name "*.php" -o -name "*.html" -o -name "*.gz" -o -name "*.json" \) -delete 2>/dev/null
        echo "File cache cleared for $domain"
    else
        echo "SKIP: No cache directory for $domain"
    fi
}

# ── Helper: WP maintenance mode ───────────────────
_cmd_wp_maintenance(){
    local domain="$1"
    local mode="$2"

    [ -z "$domain" ] && echo "FAIL: Domain required" && return 1

    local clean=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
    local docroot="$DOMAINS_ROOT/$clean/public_html"

    if [ "$mode" = "on" ]; then
        cat > "$docroot/.maintenance" <<'MAINT'
<?php $upgrading = time(); ?>
MAINT
        echo "Maintenance mode ON for $domain"
    else
        rm -f "$docroot/.maintenance"
        echo "Maintenance mode OFF for $domain"
    fi
}

# ── Helper: Run WP-CLI command (safe subset) ──────
_cmd_wp_cli(){
    local domain="$1"
    local wp_args="$2"

    [ -z "$domain" ] && echo "FAIL: Domain required" && return 1

    local clean=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')
    local env_file="$DOMAINS_ROOT/$clean/config/domain.env"
    local docroot="$DOMAINS_ROOT/$clean/public_html"

    [ ! -f "$docroot/wp-config.php" ] && echo "FAIL: Not a WordPress site" && return 1

    local sys_user="$clean"
    local php_ver=""
    if [ -f "$env_file" ]; then
        sys_user=$(grep "^SYSTEM_USER=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:]')
        php_ver=$(grep "^PHP_VERSION=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:]')
    fi
    [ -z "$sys_user" ] && sys_user="$clean"

    local php_short=$(echo "$php_ver" | tr -d '.')
    local php_bin="/opt/remi/php${php_short}/root/usr/bin/php"
    [ ! -x "$php_bin" ] && php_bin=$(command -v php 2>/dev/null || echo "php")

    if [ -x /usr/local/bin/wp ]; then
        sudo -u "$sys_user" "$php_bin" /usr/local/bin/wp $wp_args --path="$docroot" --quiet 2>&1 | tail -5
        echo "WP-CLI: $wp_args completed for $domain"
    else
        echo "FAIL: WP-CLI not installed"
    fi
}

# ── Poll and execute pending commands ─────────────
poll_remote_commands(){
    [ -z "$SHIELDPRESS_VPS_SECRET" ] && return

    # Fetch pending commands from API
    local RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 10 \
        -H "Authorization: Bearer ${SHIELDPRESS_VPS_SECRET}" \
        -H "Accept: application/json" \
        "${COMMANDS_URL}/pending" 2>/dev/null)

    local HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    local BODY=$(echo "$RESPONSE" | head -n -1)

    # Only process 200 responses
    [ "$HTTP_CODE" != "200" ] && return

    # Parse commands with Python (safe JSON handling)
    local CMD_FILE="/tmp/shieldpress_commands_$$.json"
    echo "$BODY" > "$CMD_FILE"

    local CMD_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('${CMD_FILE}'))
    cmds = data.get('commands', [])
    print(len(cmds))
except:
    print(0)
" 2>/dev/null)

    [ "$CMD_COUNT" = "0" ] && rm -f "$CMD_FILE" && return

    log "Received $CMD_COUNT remote command(s)"

    # Process each command
    python3 -c "
import json
data = json.load(open('${CMD_FILE}'))
for cmd in data.get('commands', []):
    cid = cmd.get('id', '')
    action = cmd.get('action', '')
    domain = cmd.get('domain', '')
    params = json.dumps(cmd.get('params', {}))
    sig = cmd.get('signature', '')
    print(f'{cid}|{action}|{domain}|{params}|{sig}')
" 2>/dev/null | while IFS='|' read -r cmd_id cmd_action cmd_domain cmd_params cmd_sig; do

        [ -z "$cmd_id" ] || [ -z "$cmd_action" ] && continue

        # Verify signature: sha256(id + action + sha256(secret))
        # API signs with secretHash = sha256(raw_secret), so VPS must hash its secret first
        local secret_hash=$(echo -n "${SHIELDPRESS_VPS_SECRET}" | sha256sum | awk '{print $1}')
        local expected_sig=$(echo -n "${cmd_id}${cmd_action}${secret_hash}" | sha256sum | awk '{print $1}')
        if [ "$cmd_sig" != "$expected_sig" ]; then
            log "[CMD] REJECTED $cmd_id ($cmd_action) — invalid signature"
            # Report rejection
            curl -s --max-time 10 \
                -X POST "${COMMANDS_URL}/${cmd_id}/result" \
                -H "Authorization: Bearer ${SHIELDPRESS_VPS_SECRET}" \
                -H "Content-Type: application/json" \
                -d "{\"status\":\"rejected\",\"output\":\"Invalid signature\"}" \
                >/dev/null 2>&1
            continue
        fi

        log "[CMD] Executing $cmd_id: $cmd_action (domain: ${cmd_domain:-all})"

        # Execute and capture output
        local output=$(execute_remote_command "$cmd_action" "$cmd_domain" "$cmd_params" 2>&1)
        local exit_code=$?
        local status="completed"
        [ $exit_code -ne 0 ] && status="failed"

        log "[CMD] Result $cmd_id: $status — $output"

        # Report result back to API — use curl (consistent with metrics/rejection calls)
        local result_file="/tmp/sp_cmd_result_${cmd_id}.json"
        python3 -c "
import json
print(json.dumps({'status': '${status}', 'output': '''${output}'''[:500]}))
" 2>/dev/null > "$result_file"

        if [ -s "$result_file" ]; then
            local http_code="000"
            local retry=0
            while [ "$http_code" != "200" ] && [ $retry -lt 4 ]; do
                [ $retry -gt 0 ] && sleep 3
                http_code=$(curl -s -w "%{http_code}" -o /dev/null --max-time 10 \
                    -X POST "${COMMANDS_URL}/${cmd_id}/result" \
                    -H "Authorization: Bearer ${SHIELDPRESS_VPS_SECRET}" \
                    -H "Content-Type: application/json" \
                    -d "@${result_file}" 2>/dev/null)
                retry=$((retry + 1))
            done
            [ "$http_code" = "200" ] \
                && log "[CMD] Reported $cmd_id → $status (HTTP 200)" \
                || log "[CMD] WARN: Result report for $cmd_id failed after $retry attempts (HTTP ${http_code:-000})"
        else
            log "[CMD] WARN: Failed to build result JSON for $cmd_id"
        fi
        rm -f "$result_file"

    done

    rm -f "$CMD_FILE"
}

# =================================================
# 7. DAEMON MODE (called by systemd)
# =================================================

run_daemon(){
    log "ShieldPress Monitor daemon started (PID: $$)"

    load_config || {
        log "Config not found, daemon exit"
        exit 1
    }

    local COMMAND_POLL_INTERVAL=15   # Poll commands every 15s (well within 60s app timeout)
    local last_metrics_send=0

    while true; do
        local now=$(date +%s)

        # Send metrics on the configured interval
        if [ $((now - last_metrics_send)) -ge "${SHIELDPRESS_INTERVAL:-60}" ]; then
            send_metrics
            last_metrics_send=$(date +%s)
        fi

        # Always poll commands every 15 seconds (independent of metrics interval)
        poll_remote_commands

        sleep "$COMMAND_POLL_INTERVAL"
    done
}

# =================================================
# 7. SYSTEMD SERVICE
# =================================================

install_service(){
    load_config || {
        fail "Configure connection first (menu option 1)"
        return 1
    }

    echo ""
    echo "Installing ShieldPress Monitor service..."

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=ShieldPress VPS Monitor Service
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/shieldpress/modules/shieldpress/shieldpress-monitor.sh --daemon
Restart=always
RestartSec=30
StandardOutput=append:/var/shieldpress/logs/shieldpress-monitor.log
StandardError=append:/var/shieldpress/logs/shieldpress-monitor.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shieldpress-monitor.service >/dev/null 2>&1
    systemctl restart shieldpress-monitor.service

    sleep 2

    if systemctl is-active --quiet shieldpress-monitor.service; then
        ok "ShieldPress Monitor service installed and running"
        echo "  Interval : ${SHIELDPRESS_INTERVAL}s"
        log "Monitor service installed"
    else
        fail "Service failed to start"
        echo "  Check: journalctl -u shieldpress-monitor.service"
    fi
}

remove_service(){
    echo ""
    echo "Removing ShieldPress Monitor service..."

    systemctl stop shieldpress-monitor.service 2>/dev/null || true
    systemctl disable shieldpress-monitor.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    ok "Service removed"
    log "Monitor service removed"
}

service_status(){
    echo ""
    echo "========================================="
    echo "  SHIELDPRESS MONITOR STATUS"
    echo "========================================="
    echo ""

    # Config status
    if load_config && [ -n "$SHIELDPRESS_VPS_SECRET" ]; then
        echo -e "  Config     : ${GREEN}Configured${RESET}"
        echo "  API URL    : $SHIELDPRESS_API_URL"
        echo "  Key        : ${SHIELDPRESS_VPS_SECRET:0:12}..."
        echo "  Interval   : ${SHIELDPRESS_INTERVAL}s"
    else
        echo -e "  Config     : ${RED}Not configured${RESET}"
    fi

    echo ""

    # Service status
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "  Service    : ${GREEN}Installed${RESET}"

        if systemctl is-enabled --quiet shieldpress-monitor.service 2>/dev/null; then
            echo -e "  Auto-start : ${GREEN}Enabled${RESET}"
        else
            echo -e "  Auto-start : ${YELLOW}Disabled${RESET}"
        fi

        local STATE=$(systemctl is-active shieldpress-monitor.service 2>/dev/null || echo "inactive")
        if [ "$STATE" = "active" ]; then
            echo -e "  Running    : ${GREEN}Active${RESET}"
            local PID=$(systemctl show -p MainPID shieldpress-monitor.service 2>/dev/null | cut -d= -f2)
            echo "  PID        : $PID"
        else
            echo -e "  Running    : ${RED}Stopped${RESET}"
        fi
    else
        echo -e "  Service    : ${RED}Not installed${RESET}"
    fi

    # Recent logs
    echo ""
    echo "  Recent activity:"
    echo "  ─────────────────────────────────────"
    tail -n 10 "$LOG_FILE" 2>/dev/null | while read line; do
        echo "  $line"
    done
    [ ! -f "$LOG_FILE" ] && echo "  No logs yet"
}

# =================================================
# 8. SEND NOW (manual trigger)
# =================================================

send_now(){
    load_config || {
        fail "Configure connection first"
        return 1
    }

    echo ""
    echo "Sending metrics to ShieldPress..."
    echo ""

    if send_metrics; then
        ok "Metrics sent successfully"
    else
        fail "Failed to send metrics"
    fi
}

# =================================================
# 9. VIEW FILE CHANGES (local preview)
# =================================================

view_file_changes(){
    echo ""
    echo "========================================="
    echo "  FILE CHANGE DETECTION (Last 60 min)"
    echo "========================================="
    echo ""

    echo "Scanning for sensitive files modified in the last hour..."
    echo "  Paths: /etc, /var/www, $DOMAINS_ROOT"
    echo "  Types: *.php, .env, .htaccess, *.conf"
    echo ""

    local CHANGED_FILES=$(detect_file_changes)
    local COUNT=$(echo "$CHANGED_FILES" | grep -c . 2>/dev/null || echo 0)
    [ -z "$CHANGED_FILES" ] && COUNT=0

    if [ "$COUNT" -gt 0 ]; then
        echo -e "  ${YELLOW}MODIFIED FILES ($COUNT):${RESET}"
        echo "$CHANGED_FILES" | while read -r f; do
            [ -z "$f" ] && continue
            local SIZE=$(stat -c '%s' "$f" 2>/dev/null || echo "?")
            local MOD_TIME=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
            local EXT="${f##*.}"
            echo -e "    ${YELLOW}~${RESET} $f ($SIZE bytes, $MOD_TIME)"
        done
    else
        ok "No sensitive file changes detected in the last hour"
    fi
}

# =================================================
# 10. VIEW LOGIN ACTIVITY (local preview)
# =================================================

view_login_activity(){
    echo ""
    echo "========================================="
    echo "  VPS LOGIN ACTIVITY"
    echo "========================================="

    # Currently logged in
    echo ""
    echo -e "  ${BOLD}Currently Logged In:${RESET}"
    echo "  ─────────────────────────────────────"
    local ONLINE=$(who 2>/dev/null)
    if [ -n "$ONLINE" ]; then
        echo "$ONLINE" | while read line; do
            echo "  $line"
        done
    else
        echo "  No active sessions"
    fi

    # Failed SSH login attempts (last 1 hour)
    echo ""
    echo -e "  ${BOLD}Failed SSH Logins (last 1 hour):${RESET}"
    echo "  ─────────────────────────────────────"

    local LOGIN_LINES=$(detect_failed_logins)

    if [ -n "$LOGIN_LINES" ]; then
        printf "  ${DIM}%-12s %-16s %s${RESET}\n" "User" "IP Address" "Time"
        echo "  ─────────────────────────────────────"
        echo "$LOGIN_LINES" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            local parts=($line)
            local FAIL_TIME="${parts[0]} ${parts[1]} ${parts[2]}"
            local FAIL_USER=""
            local FAIL_IP=""

            # Extract user and IP from "Failed password for [invalid user] USER from IP"
            FAIL_USER=$(echo "$line" | grep -oP 'for (?:invalid user )?\K\S+' || echo "unknown")
            FAIL_IP=$(echo "$line" | grep -oP 'from \K[0-9.]+' || echo "unknown")

            printf "  ${RED}%-12s${RESET} %-16s %s\n" "$FAIL_USER" "$FAIL_IP" "$FAIL_TIME"
        done
    else
        ok "No failed login attempts in the last hour"
    fi

    # SSH authorized keys
    echo ""
    echo -e "  ${BOLD}SSH Authorized Keys:${RESET}"
    echo "  ─────────────────────────────────────"
    for user_home in /root /home/*; do
        local username=$(basename "$user_home")
        local auth_file="$user_home/.ssh/authorized_keys"
        if [ -f "$auth_file" ]; then
            local key_count=$(grep -c "^ssh-" "$auth_file" 2>/dev/null || echo 0)
            echo "  $username: $key_count key(s)"
        fi
    done
}

# =================================================
# 11. CHANGE INTERVAL
# =================================================

change_interval(){
    load_config || {
        fail "Configure connection first"
        return 1
    }

    echo ""
    echo "Current interval: ${SHIELDPRESS_INTERVAL}s"
    echo ""
    echo "  [1] Every 1 minute  (recommended)"
    echo "  [2] Every 5 minutes"
    echo "  [3] Every 10 minutes"
    echo ""
    read -rp "  Choose [1/2/3] (default: 1): " CHOICE

    case $CHOICE in
        2) SHIELDPRESS_INTERVAL=300 ;;
        3) SHIELDPRESS_INTERVAL=600 ;;
        *) SHIELDPRESS_INTERVAL=60 ;;
    esac

    save_config
    ok "Interval updated to ${SHIELDPRESS_INTERVAL}s"

    # Restart service if running
    if systemctl is-active --quiet shieldpress-monitor.service 2>/dev/null; then
        systemctl restart shieldpress-monitor.service
        ok "Service restarted with new interval"
    fi
}

# =================================================
# VIEW LOGS
# =================================================

view_logs(){
    echo ""
    echo "ShieldPress Monitor Log (tail -f):"
    echo "Press Ctrl+C to stop"
    echo "─────────────────────────────────────"
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        fail "Log file not found"
    fi
}

# =================================================
# ARGUMENT HANDLING (daemon mode)
# =================================================

if [ "$1" = "--daemon" ]; then
    run_daemon
    exit 0
fi

if [ "$1" = "--send" ]; then
    send_metrics
    exit $?
fi

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "ShieldPress Monitor" "Remote monitoring & alerts"

    # Show connection status in header
    if load_config && [ -n "$SHIELDPRESS_VPS_SECRET" ]; then
        SVC_STATE=$(systemctl is-active shieldpress-monitor.service 2>/dev/null || echo "inactive")
        if [ "$SVC_STATE" = "active" ]; then
            echo -e "  Status: ${GREEN}Connected & Running${RESET} | Interval: ${SHIELDPRESS_INTERVAL}s"
        else
            echo -e "  Status: ${YELLOW}Configured but Stopped${RESET}"
        fi
    else
        echo -e "  Status: ${RED}Not Connected${RESET}"
    fi
    sp_hr

    sp_menu_grid \
        "1|Connect / Setup|green" \
        "2|Change Interval|yellow" \
        "3|Start Service|green" \
        "4|Stop Service|red" \
        "5|Monitor Status|cyan" \
        "6|Send Now|blue" \
        "7|View File Changes|magenta" \
        "8|View Login Activity|magenta" \
        "9|View Logs|cyan" \
        "10|Remove Service|red" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1)  setup_connection ;;
        2)  change_interval ;;
        3)  install_service ;;
        4)
            systemctl stop shieldpress-monitor.service 2>/dev/null \
                && ok "Service stopped" \
                || warn "Service not running"
            ;;
        5)  service_status ;;
        6)  send_now ;;
        7)  view_file_changes ;;
        8)  view_login_activity ;;
        9)  view_logs ;;
        10) remove_service ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac

    pause
done
