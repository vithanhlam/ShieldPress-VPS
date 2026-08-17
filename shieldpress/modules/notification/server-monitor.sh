#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
CONFIG_FILE="$BASE_DIR/config/telegram-notify.env"
NOTIFY="$BASE_DIR/modules/notification/telegram-notify.sh"
STATE_DIR="$LOG_DIR/notification-state"

mkdir -p "$STATE_DIR"

[ -f "$CONFIG_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SERVER_MONITOR_DISK_WARN="${SERVER_MONITOR_DISK_WARN:-85}"
SERVER_MONITOR_RAM_WARN="${SERVER_MONITOR_RAM_WARN:-90}"
SERVER_MONITOR_LOAD_WARN="${SERVER_MONITOR_LOAD_WARN:-0}"

send_once(){
    local KEY="$1"
    local CATEGORY="$2"
    local TITLE="$3"
    local BODY="$4"
    local TTL="${5:-3600}"
    local STATE_FILE="$STATE_DIR/$KEY"
    local NOW LAST
    NOW=$(date +%s)
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

    if [ $((NOW - LAST)) -ge "$TTL" ]; then
        bash "$NOTIFY" send "$CATEGORY" "$TITLE" "$BODY"
        echo "$NOW" > "$STATE_FILE"
    fi
}

clear_state_if_ok(){
    rm -f "$STATE_DIR/$1" 2>/dev/null
}

DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_PERCENT=$((RAM_USED * 100 / RAM_TOTAL))
CPU_CORES=$(nproc 2>/dev/null || echo 1)
LOAD_INT=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | awk '{printf "%d", $1}')
LOAD_WARN="$SERVER_MONITOR_LOAD_WARN"
[ "$LOAD_WARN" = "0" ] && LOAD_WARN="$CPU_CORES"

if [ "$DISK_PERCENT" -ge "$SERVER_MONITOR_DISK_WARN" ]; then
    send_once "disk_high" "server_alert" "Disk usage high" "Disk usage is ${DISK_PERCENT}% on /"
else
    clear_state_if_ok "disk_high"
fi

if [ "$RAM_PERCENT" -ge "$SERVER_MONITOR_RAM_WARN" ]; then
    send_once "ram_high" "server_alert" "RAM usage high" "RAM usage is ${RAM_PERCENT}% (${RAM_USED}MB/${RAM_TOTAL}MB)"
else
    clear_state_if_ok "ram_high"
fi

if [ "$LOAD_INT" -ge "$LOAD_WARN" ]; then
    send_once "load_high" "server_alert" "CPU load high" "Load average is above threshold. Load=$(uptime | awk -F'load average:' '{print $2}' | xargs), threshold=$LOAD_WARN"
else
    clear_state_if_ok "load_high"
fi

for SVC in nginx mariadb postgresql valkey firewalld fail2ban; do
    if systemctl list-unit-files "$SVC.service" >/dev/null 2>&1 && ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
        send_once "svc_${SVC}_down" "server_alert" "Service down: $SVC" "$SVC is not active"
    else
        clear_state_if_ok "svc_${SVC}_down"
    fi
done

if ss -tuln | grep -Eq '0\.0\.0\.0:3306|\*:3306|\[::\]:3306|:::3306|0\.0\.0\.0:5432|\*:5432|\[::\]:5432|:::5432'; then
    send_once "db_public" "security_alert" "Database port public" "MariaDB/PostgreSQL appears to be listening publicly. Check firewall and bind-address."
else
    clear_state_if_ok "db_public"
fi

if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
    BANNED=$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/ {gsub(/,/, " "); print $2}' | xargs -n1 2>/dev/null | while read -r JAIL; do
        [ -n "$JAIL" ] || continue
        fail2ban-client status "$JAIL" 2>/dev/null | awk -v jail="$JAIL" -F: '/Currently banned/ {gsub(/ /,"",$2); if ($2+0>0) print jail "=" $2}'
    done | xargs)
    if [ -n "$BANNED" ]; then
        send_once "fail2ban_bans" "security_alert" "Fail2ban active bans" "$BANNED" 1800
    else
        clear_state_if_ok "fail2ban_bans"
    fi
fi
