#!/bin/bash
# ====================================================
# ShieldPress Auto-Repair Daemon
# Chạy qua cron, tự phát hiện & sửa lỗi hệ thống
# Gửi cảnh báo Telegram khi phát hiện/sửa lỗi
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
BIN_DIR="$BASE_DIR/bin"
LOG_FILE="$LOG_DIR/auto-repair.log"
STATE_DIR="$LOG_DIR/repair-state"
SNAPSHOT_SCRIPT="$BASE_DIR/modules/repair/config-snapshot.sh"
INTEGRITY_SCRIPT="$BASE_DIR/modules/repair/system-integrity.sh"
CRON_TAG="SHIELDPRESS_AUTO_REPAIR"
SCRIPT_FILE="$BIN_DIR/shieldpress-auto-repair"
DOMAINS_ROOT="/home/domains"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$STATE_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

# ====================================================
# Send alert (with cooldown to prevent spam)
# ====================================================

send_alert(){
    local KEY="$1"
    local TITLE="$2"
    local BODY="$3"
    local COOLDOWN="${4:-3600}"  # Default 1 hour cooldown

    local STATE_FILE="$STATE_DIR/$KEY"

    # Check cooldown
    if [ -f "$STATE_FILE" ]; then
        local LAST=$(cat "$STATE_FILE" 2>/dev/null)
        local NOW=$(date +%s)
        local DIFF=$((NOW - LAST))
        [ "$DIFF" -lt "$COOLDOWN" ] && return 0
    fi

    # Send via Telegram
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "server_alert" "$TITLE" "$BODY" 2>/dev/null
    fi

    date +%s > "$STATE_FILE"
    log "ALERT: $TITLE - $BODY"
}

# Clear alert state when issue resolved
clear_alert(){
    local KEY="$1"
    rm -f "$STATE_DIR/$KEY" 2>/dev/null
}

# ====================================================
# Generate the daemon script
# ====================================================

generate_daemon(){
    cat > "$SCRIPT_FILE" <<'DAEMON_EOF'
#!/bin/bash
# ShieldPress Auto-Repair Daemon (runs via cron)

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/auto-repair.log"
STATE_DIR="$LOG_DIR/repair-state"
LOCK_FILE="/tmp/shieldpress-auto-repair.lock"
DOMAINS_ROOT="/home/domains"
HOST=$(hostname 2>/dev/null || echo "server")

mkdir -p "$STATE_DIR"

# Prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

send_alert(){
    local KEY="$1" TITLE="$2" BODY="$3" COOLDOWN="${4:-3600}"
    local STATE_FILE="$STATE_DIR/$KEY"
    if [ -f "$STATE_FILE" ]; then
        local LAST=$(cat "$STATE_FILE" 2>/dev/null) NOW=$(date +%s)
        [ $((NOW - LAST)) -lt "$COOLDOWN" ] && return 0
    fi
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "server_alert" "$TITLE" "$BODY" 2>/dev/null
    fi
    date +%s > "$STATE_FILE"
    log "ALERT: $TITLE - $BODY"
}

clear_alert(){ rm -f "$STATE_DIR/$1" 2>/dev/null; }

FIXES=""
add_fix(){ FIXES="${FIXES}\n• $1"; }

# ============================================
# 1. SERVICE HEALTH - restart if down
# ============================================

for SVC in nginx mariadb; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SVC}"; then
        if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
            log "$SVC is DOWN, attempting restart..."
            systemctl start "$SVC" 2>/dev/null
            if systemctl is-active --quiet "$SVC" 2>/dev/null; then
                add_fix "$SVC was down → restarted OK"
                log "$SVC restarted successfully"
                clear_alert "svc_${SVC}"
            else
                send_alert "svc_${SVC}" "Service Down: $SVC" "$SVC failed to restart on $HOST" 1800
                log "$SVC restart FAILED"
            fi
        else
            clear_alert "svc_${SVC}"
        fi
    fi
done

# Optional services
for SVC in postgresql valkey firewalld fail2ban; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SVC}"; then
        if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
            systemctl start "$SVC" 2>/dev/null
            if systemctl is-active --quiet "$SVC" 2>/dev/null; then
                add_fix "$SVC was down → restarted OK"
                clear_alert "svc_${SVC}"
            else
                send_alert "svc_${SVC}" "Service Down: $SVC" "$SVC failed to restart on $HOST" 3600
            fi
        else
            clear_alert "svc_${SVC}"
        fi
    fi
done

# PHP-FPM
for v in 81 82 83 84; do
    SVC="php${v}-php-fpm"
    systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
    if ! systemctl is-active --quiet "$SVC" 2>/dev/null; then
        log "PHP $SVC DOWN, restarting..."
        systemctl start "$SVC" 2>/dev/null
        if systemctl is-active --quiet "$SVC"; then
            add_fix "PHP ${v:0:1}.${v:1} FPM was down → restarted"
            clear_alert "svc_php${v}"
        else
            send_alert "svc_php${v}" "PHP FPM Down" "php${v}-php-fpm failed to restart on $HOST" 1800
        fi
    else
        clear_alert "svc_php${v}"
    fi
done

# ============================================
# 2. NGINX CONFIG VALIDATION
# ============================================

if ! nginx -t 2>/dev/null; then
    log "Nginx config BROKEN, attempting to identify bad config..."

    BROKEN_CONF=""
    for conf in /etc/nginx/conf.d/*.conf; do
        [ -f "$conf" ] || continue
        # Test by temporarily disabling
        mv "$conf" "${conf}.broken" 2>/dev/null
        if nginx -t 2>/dev/null; then
            BROKEN_CONF="$conf"
            # Keep it disabled so nginx can reload
            add_fix "Disabled broken nginx config: $(basename "$conf")"
            log "DISABLED broken config: $conf"
            break
        else
            # Restore and try next
            mv "${conf}.broken" "$conf" 2>/dev/null
        fi
    done

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null
        send_alert "nginx_config" "Nginx Config Fixed" \
            "Broken config disabled: ${BROKEN_CONF:-unknown}\nNginx reloaded on $HOST" 1800
    else
        send_alert "nginx_config" "Nginx Config Broken" \
            "Cannot identify broken config. Manual intervention needed on $HOST" 1800
    fi
else
    clear_alert "nginx_config"
fi

# ============================================
# 3. PHP-FPM CONFIG VALIDATION
# ============================================

for v in 81 82 83 84; do
    FPM="/opt/remi/php${v}/root/usr/sbin/php-fpm"
    [ -x "$FPM" ] || continue

    if ! $FPM -t 2>/dev/null; then
        log "PHP ${v} FPM config broken, checking pools..."

        # Try to find broken pool
        POOL_DIR="/etc/opt/remi/php${v}/php-fpm.d"
        for pool in "$POOL_DIR"/*.conf; do
            [ -f "$pool" ] || continue
            [ "$(basename "$pool")" = "www.conf" ] && continue

            mv "$pool" "${pool}.broken" 2>/dev/null
            if $FPM -t 2>/dev/null; then
                add_fix "Disabled broken PHP ${v:0:1}.${v:1} pool: $(basename "$pool")"
                log "DISABLED broken pool: $pool"
                systemctl restart "php${v}-php-fpm" 2>/dev/null
                send_alert "php${v}_config" "PHP Config Fixed" \
                    "Broken pool disabled: $(basename "$pool") on $HOST" 3600
                break
            else
                mv "${pool}.broken" "$pool" 2>/dev/null
            fi
        done
    else
        clear_alert "php${v}_config"
    fi
done

# ============================================
# 4. MISSING CRITICAL FILES
# ============================================

# Check domain configs still have their nginx vhost
for d in "$DOMAINS_ROOT"/*/config/domain.env; do
    [ -f "$d" ] || continue
    DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    [ -z "$DN" ] && continue
    CLEAN=$(echo "$DN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN}.conf"

    if [ ! -f "$NGINX_CONF" ]; then
        send_alert "missing_nginx_${CLEAN}" "Missing Config: $DN" \
            "Nginx config missing for $DN on $HOST.\nFile: $NGINX_CONF\nPossible attack or accidental deletion." 3600
    else
        clear_alert "missing_nginx_${CLEAN}"
    fi
done

# Check domain document roots
for d in "$DOMAINS_ROOT"/*/config/domain.env; do
    [ -f "$d" ] || continue
    DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    SYSUSER=$(grep "^SYSTEM_USER=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    WEBROOT=$(dirname "$d")/../public_html

    if [ ! -d "$WEBROOT" ]; then
        mkdir -p "$WEBROOT" 2>/dev/null
        [ -n "$SYSUSER" ] && chown "$SYSUSER:$SYSUSER" "$WEBROOT" 2>/dev/null
        add_fix "Restored missing document root for $DN"
    fi
done

# ============================================
# 5. DISK SPACE CHECK
# ============================================

DISK_USAGE=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
if [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -gt 95 ]; then
    # Emergency cleanup
    log "DISK CRITICAL: ${DISK_USAGE}% - cleaning up..."

    # Clean old logs
    find "$LOG_DIR" -name "*.log" -size +50M -exec truncate -s 10M {} \; 2>/dev/null
    find /var/log/nginx -name "*.log.*.gz" -mtime +7 -delete 2>/dev/null
    find /tmp -type f -mtime +3 -delete 2>/dev/null

    # Clean old nginx cache if exists
    find /var/cache/nginx -type f -mtime +7 -delete 2>/dev/null

    NEW_USAGE=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    add_fix "Disk was ${DISK_USAGE}% → cleaned to ${NEW_USAGE}%"
    send_alert "disk_critical" "Disk Space Critical" \
        "Was ${DISK_USAGE}%, cleaned to ${NEW_USAGE}% on $HOST" 3600

elif [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -gt 90 ]; then
    send_alert "disk_warn" "Disk Space Warning" \
        "Disk usage at ${DISK_USAGE}% on $HOST" 7200
else
    clear_alert "disk_critical"
    clear_alert "disk_warn"
fi

# ============================================
# 6. PERMISSION CHECK (critical paths)
# ============================================

# Nginx must be able to access configs
if [ -d /etc/nginx/conf.d ]; then
    find /etc/nginx/conf.d -name "*.conf" ! -readable -exec chmod 644 {} \; 2>/dev/null
fi

# PHP socket dirs must exist
for v in 81 82 83 84; do
    SOCK_DIR="/var/opt/remi/php${v}/run/php-fpm"
    if systemctl list-unit-files 2>/dev/null | grep -q "php${v}-php-fpm"; then
        [ -d "$SOCK_DIR" ] || mkdir -p "$SOCK_DIR" 2>/dev/null
    fi
done

# ============================================
# 7. AUTO SNAPSHOT (daily at 3AM)
# ============================================

HOUR=$(date +%H)
SNAP_STATE="$STATE_DIR/daily_snapshot"
TODAY=$(date +%Y%m%d)

if [ "$HOUR" = "03" ]; then
    LAST_SNAP=$(cat "$SNAP_STATE" 2>/dev/null)
    if [ "$LAST_SNAP" != "$TODAY" ]; then
        if [ -f "$BASE_DIR/modules/repair/config-snapshot.sh" ]; then
            bash "$BASE_DIR/modules/repair/config-snapshot.sh" auto "daily" 2>/dev/null
            echo "$TODAY" > "$SNAP_STATE"
            log "Daily auto-snapshot created"
        fi
    fi
fi

# ============================================
# SUMMARY
# ============================================

if [ -n "$FIXES" ]; then
    log "AUTO-REPAIR: fixes applied:$FIXES"
    send_alert "auto_repair_summary" "Auto-Repair Applied" \
        "The following issues were fixed on $HOST:$(echo -e "$FIXES")" 300
fi

rm -f "$LOCK_FILE"
DAEMON_EOF

    chmod +x "$SCRIPT_FILE"
}

# ====================================================
# Enable/disable cron
# ====================================================

enable_daemon(){
    echo ""
    echo "Auto-Repair Daemon schedule:"
    echo "  1) Every 2 minutes  (aggressive)"
    echo "  2) Every 5 minutes  (recommended)"
    echo "  3) Every 10 minutes (light)"
    echo "  4) Every 30 minutes"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " interval

    case "$interval" in
        1) CRON="*/2 * * * *" ;;
        2) CRON="*/5 * * * *" ;;
        3) CRON="*/10 * * * *" ;;
        4) CRON="*/30 * * * *" ;;
        0) return ;;
        *) warn "Invalid"; return ;;
    esac

    generate_daemon

    # Add to crontab (replace existing)
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON $SCRIPT_FILE >/dev/null 2>&1 # $CRON_TAG") | crontab -

    ok "Auto-Repair enabled ($CRON)"
    log "Auto-Repair daemon enabled: $CRON"

    # Create initial snapshot
    echo ""
    read -p "Create config snapshot now? (y/n): " snap_confirm
    if [[ "$snap_confirm" =~ ^[yY]$ ]]; then
        bash "$SNAPSHOT_SCRIPT" auto "initial" 2>/dev/null
        ok "Initial snapshot created"
    fi
}

disable_daemon(){
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    ok "Auto-Repair daemon disabled"
    log "Auto-Repair daemon disabled"
}

show_status(){
    echo ""
    echo -e "${BOLD}Auto-Repair Status${RESET}"
    echo "===================================================="

    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        local SCHEDULE=$(crontab -l 2>/dev/null | grep "$CRON_TAG" | awk '{print $1,$2,$3,$4,$5}')
        echo -e "  Status   : ${GREEN}Enabled${RESET}"
        echo "  Schedule : $SCHEDULE"
    else
        echo -e "  Status   : ${RED}Disabled${RESET}"
    fi

    echo ""

    # Script exists?
    if [ -f "$SCRIPT_FILE" ]; then
        echo -e "  Script   : ${GREEN}Installed${RESET} ($SCRIPT_FILE)"
    else
        echo -e "  Script   : ${RED}Not installed${RESET}"
    fi

    echo ""

    # Recent activity
    echo -e "${BOLD}Recent Activity${RESET}"
    echo "----------------------------------------------------"
    if [ -f "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  No activity yet"
    fi

    echo ""

    # Active alerts
    local ALERT_COUNT=$(ls "$STATE_DIR" 2>/dev/null | grep -v daily_snapshot | wc -l)
    if [ "$ALERT_COUNT" -gt 0 ]; then
        echo -e "${BOLD}Active Alerts ($ALERT_COUNT)${RESET}"
        echo "----------------------------------------------------"
        for f in "$STATE_DIR"/*; do
            [ -f "$f" ] || continue
            local NAME=$(basename "$f")
            [ "$NAME" = "daily_snapshot" ] && continue
            local TS=$(cat "$f" 2>/dev/null)
            local AGO=""
            if [ -n "$TS" ]; then
                local DIFF=$(( $(date +%s) - TS ))
                if [ "$DIFF" -lt 3600 ]; then
                    AGO="$((DIFF/60))m ago"
                else
                    AGO="$((DIFF/3600))h ago"
                fi
            fi
            echo "  - $NAME ($AGO)"
        done
    else
        echo -e "  ${GREEN}No active alerts${RESET}"
    fi
}

run_now(){
    echo ""
    echo "Running auto-repair check now..."
    echo ""

    generate_daemon
    bash "$SCRIPT_FILE"

    echo ""
    ok "Auto-repair check completed"
    echo ""
    echo "Log output:"
    echo "----------------------------------------------------"
    tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
}

view_log(){
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        warn "No log file yet"
    fi
}

clear_alerts(){
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        local NAME=$(basename "$f")
        [ "$NAME" = "daily_snapshot" ] && continue
        rm -f "$f"
    done
    ok "All alert states cleared"
}

# ====================================================
# MENU
# ====================================================

while true; do
    clear
    echo "===================================================="
    echo "          AUTO-REPAIR DAEMON"
    echo "===================================================="
    echo ""
    echo "  1) Show Status"
    echo "  2) Enable Auto-Repair"
    echo "  3) Disable Auto-Repair"
    echo "  4) Run Check Now"
    echo "  5) View Log"
    echo "  6) Clear Alert States"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) enable_daemon ;;
        3) disable_daemon ;;
        4) run_now ;;
        5) view_log ;;
        6) clear_alerts ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
