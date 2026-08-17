#!/bin/bash
# ============================================================
#  WordPress Auto-Recovery
#  Detect 500/502/503/504 errors and auto-fix WordPress sites
#  using domain diagnostics and cache clearing. Shared PHP-FPM
#  is restarted only when the service or domain socket is down.
#
#  Usage:
#    Interactive:  bash wp-auto-recovery.sh
#    Scan all:     bash wp-auto-recovery.sh --scan
#    Daemon:       bash wp-auto-recovery.sh --daemon
# ============================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/wp-auto-recovery.log"
COOLDOWN_DIR="/tmp/shieldpress_recovery"
COOLDOWN_SECONDS=300   # 5 min between recovery per domain
DAEMON_INTERVAL=60     # Check every 60 seconds in daemon mode
SERVICE_FILE="/etc/systemd/system/shieldpress-wp-recovery.service"

# Source safely - daemon mode may not have all files
[ -f "$BASE_DIR/core/ui.sh" ] && source "$BASE_DIR/core/ui.sh" || {
    # Minimal fallback for daemon mode
    sp_header(){ echo "=== $1 ==="; }
    sp_hr(){ echo "──────────────────────────────"; }
    sp_menu_grid(){ for item in "$@"; do echo "  $item"; done; }
    sp_prompt(){ read -p "Select: " "$1"; }
    sp_invalid(){ echo "Invalid"; }
}
[ -f "$BASE_DIR/modules/helpers/domain-utils.sh" ] && source "$BASE_DIR/modules/helpers/domain-utils.sh" || {
    domain_to_clean(){ echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30; }
}

mkdir -p "$COOLDOWN_DIR" "$LOG_DIR"

# ─── Logging ───────────────────────────────────────────────

log(){
    echo "$(date '+%F %T') | $1" >> "$LOG_FILE"
}

# ─── PHP-FPM Detection ────────────────────────────────────

# Read PHP version from domain config
get_domain_php_version(){
    local domain="$1"
    local clean=$(domain_to_clean "$domain")
    local env_file="$DOMAINS_ROOT/$clean/config/domain.env"

    if [ -f "$env_file" ]; then
        local ver=$(grep "^PHP_VERSION=" "$env_file" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -n "$ver" ] && echo "$ver" && return
    fi

    # Fallback: parse from Nginx config
    local conf="/etc/nginx/conf.d/${clean}.conf"
    if [ -f "$conf" ]; then
        local sock=$(grep -oP 'php\K[0-9]+(?=-php-fpm)' "$conf" 2>/dev/null | head -1)
        if [ -n "$sock" ]; then
            echo "${sock:0:1}.${sock:1}"
            return
        fi
    fi

    echo "8.2"
}

# Get PHP-FPM service name (Remi-style: php82-php-fpm)
get_php_fpm_service(){
    local ver="$1"
    local short=$(echo "$ver" | tr -d '.')

    # Remi (CentOS/RHEL): php82-php-fpm
    local svc="php${short}-php-fpm"
    systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc" && echo "$svc" && return

    # Debian/Ubuntu: php8.2-fpm
    svc="php${ver}-fpm"
    systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc" && echo "$svc" && return

    # Generic
    systemctl list-units --type=service --all 2>/dev/null | grep -q "php-fpm" && echo "php-fpm" && return

    echo ""
}

# Resolve the Unix socket configured for this domain's Nginx vhost.
get_domain_php_socket(){
    local domain="$1"
    local php_ver="$2"
    local clean=$(domain_to_clean "$domain")
    local conf="/etc/nginx/conf.d/${clean}.conf"
    local socket=""

    if [ -f "$conf" ]; then
        socket=$(grep -hoE 'fastcgi_pass[[:space:]]+unix:[^;]+' "$conf" 2>/dev/null \
            | head -1 | sed -E 's/.*unix:([^;]+).*/\1/' | tr -d '[:space:]')
    fi

    [ -z "$socket" ] && socket="/var/opt/remi/php$(echo "$php_ver" | tr -d '.')/run/php-fpm/${clean}.sock"
    echo "$socket"
}

log_php_fpm_diagnostics(){
    local domain="$1"
    local service="$2"
    local socket="$3"
    local fpm_log="$4"
    local state=$(systemctl is-active "$service" 2>/dev/null)
    [ -z "$state" ] && state="unknown"
    local socket_ok="no"
    [ -S "$socket" ] && socket_ok="yes"

    log "[$domain] PHP-FPM service=$service active=$state socket=$socket socket_ok=$socket_ok"
    if [ -f "$fpm_log" ]; then
        tail -5 "$fpm_log" 2>/dev/null | while IFS= read -r line; do
            log "[$domain] PHP-FPM log: $line"
        done
    else
        journalctl -u "$service" -n 5 --no-pager 2>/dev/null | while IFS= read -r line; do
            log "[$domain] PHP-FPM journal: $line"
        done
    fi
}

# ─── Cache Clearing ───────────────────────────────────────

clear_wp_caches(){
    local docroot="$1"
    local domain="$2"
    local php_ver="$3"
    local cleared=""

    # 1. OPcache reset via domain's PHP version
    local php_short=$(echo "$php_ver" | tr -d '.')
    local php_bin="/opt/remi/php${php_short}/root/usr/bin/php"
    [ ! -x "$php_bin" ] && php_bin=$(command -v php 2>/dev/null || echo "")

    if [ -n "$php_bin" ]; then
        $php_bin -r 'if(function_exists("opcache_reset")){opcache_reset();}' 2>/dev/null && cleared="${cleared}opcache,"
    fi

    # 2. File-based page cache
    for cache_dir in "$docroot/wp-content/cache" "$docroot/wp-content/et-cache"; do
        if [ -d "$cache_dir" ]; then
            find "$cache_dir" -type f \( -name "*.php" -o -name "*.html" -o -name "*.gz" -o -name "*.json" \) -delete 2>/dev/null
            cleared="${cleared}file-cache,"
            break
        fi
    done

    # 3. WP transients via WP-CLI
    local clean=$(domain_to_clean "$domain")
    local sys_user=$(grep "^SYSTEM_USER=" "$DOMAINS_ROOT/$clean/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    [ -z "$sys_user" ] && sys_user="$clean"

    if [ -x "$php_bin" ] && [ -f /usr/local/bin/wp ]; then
        sudo -u "$sys_user" "$php_bin" /usr/local/bin/wp transient delete --all --path="$docroot" --quiet 2>/dev/null && cleared="${cleared}transients,"
    fi

    # 4. Redis
    if command -v redis-cli >/dev/null 2>&1; then
        if systemctl is-active --quiet redis 2>/dev/null || systemctl is-active --quiet redis-server 2>/dev/null; then
            redis-cli FLUSHALL 2>/dev/null && cleared="${cleared}redis,"
        fi
    fi

    # 5. Memcached
    if systemctl is-active --quiet memcached 2>/dev/null; then
        echo "flush_all" | nc -q1 localhost 11211 2>/dev/null && cleared="${cleared}memcached,"
    fi

    # 6. Nginx proxy/fastcgi cache
    if [ -d /var/cache/nginx ]; then
        find /var/cache/nginx -type f -delete 2>/dev/null && cleared="${cleared}nginx-cache,"
    fi

    echo "${cleared%,}"
}

# ─── Service Restart ──────────────────────────────────────

restart_php_fpm(){
    local php_ver="$1"
    local service=$(get_php_fpm_service "$php_ver")

    if [ -z "$service" ]; then
        log "WARN: No PHP-FPM service found for $php_ver"
        return 1
    fi

    systemctl restart "$service" 2>/dev/null
    if [ $? -eq 0 ]; then
        log "Restarted $service"
        return 0
    else
        log "FAIL: Could not restart $service"
        return 1
    fi
}

reload_nginx(){
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        return 1
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null
        log "Nginx reloaded"
        return 0
    else
        log "FAIL: Nginx config test failed, skipping reload"
        return 1
    fi
}

# ─── Cooldown ─────────────────────────────────────────────

is_on_cooldown(){
    local domain="$1"
    local file="$COOLDOWN_DIR/$domain"
    if [ -f "$file" ]; then
        local last=$(cat "$file" 2>/dev/null || echo 0)
        local now=$(date +%s)
        [ $(( now - last )) -lt $COOLDOWN_SECONDS ] && return 0
    fi
    return 1
}

set_cooldown(){
    local domain="$1"
    date +%s > "$COOLDOWN_DIR/$domain"
}

# ─── HTTP Health Check ────────────────────────────────────

check_site_http(){
    local domain="$1"
    local code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "User-Agent: ShieldPress-Recovery/1.0" \
        "https://${domain}/" 2>/dev/null)

    # Fallback HTTP if HTTPS connection fails entirely
    [ "$code" = "000" ] && code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "User-Agent: ShieldPress-Recovery/1.0" \
        "http://${domain}/" 2>/dev/null)

    echo "$code"
}

is_server_error(){
    [[ "$1" =~ ^50[0-4]$ ]]
}

is_healthy(){
    [[ "$1" =~ ^(200|301|302|304)$ ]]
}

# ─── Telegram Notification ────────────────────────────────

notify(){
    local title="$1"
    local body="$2"
    local notify_script="$BASE_DIR/modules/notification/telegram-notify.sh"

    if [ -x "$notify_script" ]; then
        bash "$notify_script" send "server_alert" "$title" "$body" 2>/dev/null
    fi
}

# ─── Recovery for a Single Domain ─────────────────────────

recover_domain(){
    local domain="$1"
    local clean=$(domain_to_clean "$domain")
    local docroot="$DOMAINS_ROOT/$clean/public_html"
    local http_code="$2"
    local php_ver=$(get_domain_php_version "$domain")
    local php_short=$(echo "$php_ver" | tr -d '.')
    local service=$(get_php_fpm_service "$php_ver")
    local socket=$(get_domain_php_socket "$domain" "$php_ver")
    local fpm_log="/var/opt/remi/php${php_short}/log/php-fpm/error.log"
    local fpm_restarted="no"

    log "[$domain] HTTP $http_code detected — starting recovery (PHP $php_ver)"

    # Step 1: Diagnose PHP-FPM and this domain's socket. Restarting this shared
    # service interrupts requests for every site using the same PHP version.
    if [ -z "$service" ]; then
        log "[$domain] WARN: No PHP-FPM service found for PHP $php_ver"
    else
        log_php_fpm_diagnostics "$domain" "$service" "$socket" "$fpm_log"
        if ! systemctl is-active --quiet "$service" 2>/dev/null; then
            log "[$domain] PHP-FPM service is down; restart is required"
            restart_php_fpm "$php_ver" && fpm_restarted="yes(service-down)"
        elif [ ! -S "$socket" ]; then
            log "[$domain] PHP-FPM domain socket is missing; restart is required: $socket"
            restart_php_fpm "$php_ver" && fpm_restarted="yes(socket-missing)"
        else
            log "[$domain] PHP-FPM and domain socket are healthy; shared service restart skipped"
        fi
    fi

    # Step 2: Clear caches and WordPress transients.
    local cleared=$(clear_wp_caches "$docroot" "$domain" "$php_ver")
    [ -n "$cleared" ] && log "[$domain] Cleared: $cleared"

    # Step 3: Re-check without touching healthy shared services.
    sleep 3
    local new_code=$(check_site_http "$domain")

    # Set cooldown
    set_cooldown "$domain"

    if is_healthy "$new_code"; then
        log "[$domain] RECOVERED — was $http_code, now $new_code (cleared: $cleared)"
        notify "✅ $domain Recovered" "Was HTTP $http_code → now $new_code\nCleared: $cleared\nPHP: $php_ver"
        return 0
    else
        log "[$domain] STILL DOWN — was $http_code, now $new_code — manual check needed"
        notify "❌ $domain Still Down" "Was HTTP $http_code → now $new_code\nRecovery failed, manual check needed\nCleared: $cleared"
        return 1
    fi
}

# ─── Scan All Sites ───────────────────────────────────────

scan_all_sites(){
    local silent="${1:-}"  # "silent" for daemon mode (no echo)
    local sites_checked=0
    local sites_error=0
    local sites_recovered=0

    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue

        local domain=$(grep "^DOMAIN=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$domain" ] && continue

        local clean=$(domain_to_clean "$domain")
        local docroot="$DOMAINS_ROOT/$clean/public_html"
        [ -f "$docroot/wp-config.php" ] || continue

        sites_checked=$((sites_checked + 1))
        local http_code=$(check_site_http "$domain")

        if is_server_error "$http_code"; then
            sites_error=$((sites_error + 1))

            if is_on_cooldown "$domain"; then
                [ -z "$silent" ] && echo -e "  \e[33m[HTTP $http_code]\e[0m $domain — on cooldown, skipped"
                continue
            fi

            [ -z "$silent" ] && echo -e "  \e[31m[HTTP $http_code]\e[0m $domain — \e[33mrecovering...\e[0m"

            if recover_domain "$domain" "$http_code"; then
                sites_recovered=$((sites_recovered + 1))
                [ -z "$silent" ] && echo -e "    \e[32m✓ RECOVERED\e[0m"
            else
                [ -z "$silent" ] && echo -e "    \e[31m✗ STILL DOWN\e[0m — manual check needed"
            fi
        else
            [ -z "$silent" ] && echo -e "  \e[32m[HTTP $http_code]\e[0m $domain — OK"
        fi
    done

    [ -z "$silent" ] && echo "" && echo "  Checked: $sites_checked | Errors: $sites_error | Recovered: $sites_recovered"
    log "Scan complete: checked=$sites_checked errors=$sites_error recovered=$sites_recovered"
}

# ─── Daemon Mode ──────────────────────────────────────────

run_daemon(){
    log "Auto-recovery daemon started (PID: $$)"

    while true; do
        scan_all_sites "silent"
        sleep "$DAEMON_INTERVAL"
    done
}

# ─── Systemd Service ─────────────────────────────────────

install_daemon(){
    echo ""
    echo "Installing WordPress Auto-Recovery daemon..."

    # Ensure script is executable
    chmod +x "$BASE_DIR/modules/wordpress/wp-auto-recovery.sh"

    cat > "$SERVICE_FILE" <<'SVCEOF'
[Unit]
Description=ShieldPress WordPress Auto-Recovery
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /opt/shieldpress/modules/wordpress/wp-auto-recovery.sh --daemon
Restart=always
RestartSec=30
StandardOutput=append:/var/shieldpress/logs/wp-auto-recovery.log
StandardError=append:/var/shieldpress/logs/wp-auto-recovery.log
User=root
WorkingDirectory=/opt/shieldpress

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable shieldpress-wp-recovery.service >/dev/null 2>&1
    systemctl restart shieldpress-wp-recovery.service

    sleep 2

    if systemctl is-active --quiet shieldpress-wp-recovery.service; then
        echo -e "  \e[32m[OK]\e[0m Auto-recovery daemon installed and running"
        echo "  Interval: every ${DAEMON_INTERVAL}s"
        log "Auto-recovery daemon installed"
    else
        echo -e "  \e[31m[FAIL]\e[0m Daemon failed to start"
        echo ""
        echo "  Error details:"
        journalctl -u shieldpress-wp-recovery.service -n 10 --no-pager 2>/dev/null || echo "  (journalctl not available)"
        echo ""
        echo "  Debug manually:"
        echo "    journalctl -u shieldpress-wp-recovery.service -f"
        echo "    bash /opt/shieldpress/modules/wordpress/wp-auto-recovery.sh --scan"
    fi
}

remove_daemon(){
    systemctl stop shieldpress-wp-recovery.service 2>/dev/null || true
    systemctl disable shieldpress-wp-recovery.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo -e "  \e[32m[OK]\e[0m Auto-recovery daemon removed"
    log "Auto-recovery daemon removed"
}

daemon_status(){
    echo ""
    if [ -f "$SERVICE_FILE" ]; then
        state=$(systemctl is-active shieldpress-wp-recovery.service 2>/dev/null || echo "inactive")
        if [ "$state" = "active" ]; then
            echo -e "  Daemon: \e[32mRunning\e[0m (every ${DAEMON_INTERVAL}s)"
            local pid=$(systemctl show -p MainPID shieldpress-wp-recovery.service 2>/dev/null | cut -d= -f2)
            echo "  PID   : $pid"
        else
            echo -e "  Daemon: \e[31mStopped\e[0m"
        fi
    else
        echo -e "  Daemon: \e[33mNot installed\e[0m"
    fi

    echo ""
    echo "  Recent activity:"
    echo "  ─────────────────────────────────────"
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE" | while IFS= read -r line; do echo "  $line"; done
    else
        echo "  No logs yet"
    fi
}

# ─── CLI Arguments ────────────────────────────────────────

if [ "$1" = "--daemon" ]; then
    run_daemon
    exit 0
fi

if [ "$1" = "--scan" ]; then
    echo ""
    echo "Scanning all WordPress sites..."
    echo ""
    scan_all_sites
    exit 0
fi

# ─── Interactive Menu ─────────────────────────────────────

while true; do
    clear
    sp_header "WordPress Auto-Recovery" "Detect & fix 500 errors"

    # Show daemon status in header
    if [ -f "$SERVICE_FILE" ]; then
        state=$(systemctl is-active shieldpress-wp-recovery.service 2>/dev/null || echo "inactive")
        if [ "$state" = "active" ]; then
            echo -e "  Daemon: \e[32mRunning\e[0m (checks every ${DAEMON_INTERVAL}s)"
        else
            echo -e "  Daemon: \e[31mStopped\e[0m"
        fi
    else
        echo -e "  Daemon: \e[33mNot installed\e[0m"
    fi
    sp_hr

    sp_menu_grid \
        "1|Scan All Sites Now|green" \
        "2|Install Auto-Recovery Daemon|blue" \
        "3|Daemon Status|cyan" \
        "4|Stop Daemon|yellow" \
        "5|Remove Daemon|red" \
        "6|View Logs|cyan" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1)
            echo ""
            echo "Scanning all WordPress sites for errors..."
            echo ""
            scan_all_sites
            ;;
        2) install_daemon ;;
        3) daemon_status ;;
        4)
            systemctl stop shieldpress-wp-recovery.service 2>/dev/null \
                && echo -e "  \e[32m[OK]\e[0m Daemon stopped" \
                || echo -e "  \e[33m[WARN]\e[0m Daemon not running"
            ;;
        5) remove_daemon ;;
        6)
            echo ""
            if [ -f "$LOG_FILE" ]; then
                echo "Last 30 entries:"
                echo "─────────────────────────────────────"
                tail -30 "$LOG_FILE"
            else
                echo "No logs yet"
            fi
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    echo ""
    read -p "Press Enter..."
done
