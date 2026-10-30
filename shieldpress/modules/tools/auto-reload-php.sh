#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

BIN_DIR="$BASE_DIR/bin"
LOG_FILE="$LOG_DIR/php-auto-reload.log"
SCRIPT_FILE="$BIN_DIR/php-auto-reload"
CRON_TAG="SHIELDPRESS_PHP_AUTO_RELOAD"

mkdir -p "$BIN_DIR" "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }

install_checker(){
    cat > "$SCRIPT_FILE" <<'EOF'
#!/bin/bash

LOG_FILE="/var/shieldpress/logs/php-auto-reload.log"
mkdir -p /var/shieldpress/logs

for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}" || continue

    if ! systemctl is-active --quiet "$svc"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $svc is down, restarting" >> "$LOG_FILE"
        systemctl restart "$svc" >> "$LOG_FILE" 2>&1

        if systemctl is-active --quiet "$svc"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $svc restarted OK" >> "$LOG_FILE"
            # Pages cached during the 502 window would otherwise keep serving
            # the error after PHP is back. Purge every domain on this PHP version.
            ver="${svc#php}"; ver="${ver%%-*}"
            for env_file in /home/domains/*/config/domain.env; do
                [ -f "$env_file" ] || continue
                dom_ver=$(sed -n 's/^PHP_VERSION=//p' "$env_file" | tr -d '".[:space:]')
                [ "$dom_ver" = "$ver" ] || continue
                clean=$(basename "$(dirname "$(dirname "$env_file")")")
                [ -d "/var/cache/nginx/$clean" ] || continue
                find "/var/cache/nginx/$clean" -type f -delete 2>/dev/null
                echo "$(date '+%Y-%m-%d %H:%M:%S') | $clean FastCGI cache purged after $svc restart" >> "$LOG_FILE"
            done
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $svc restart FAILED" >> "$LOG_FILE"
        fi
    fi
done
EOF
    chmod +x "$SCRIPT_FILE"
}

enable_auto_reload(){
    install_checker
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "*/2 * * * * $SCRIPT_FILE >/dev/null 2>&1 # $CRON_TAG") | crontab -
    ok "PHP-FPM auto-reload enabled (every 2 minutes)"
}

disable_auto_reload(){
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    ok "PHP-FPM auto-reload disabled"
}

status_auto_reload(){
    echo ""
    echo "PHP-FPM Auto-Reload:"
    echo "--------------------------------"
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        ok "Enabled"
    else
        warn "Disabled"
    fi

    echo ""
    echo "PHP-FPM services:"
    for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}" || continue
        state=$(systemctl is-active "$svc" 2>/dev/null)
        echo "  $svc : $state"
    done
}

run_now(){
    install_checker
    "$SCRIPT_FILE"
    ok "PHP-FPM check completed"
}

view_log(){
    touch "$LOG_FILE"
    tail -f "$LOG_FILE"
}

# Non-interactive: regenerate the checker script of an already enabled
# installation (used by the update migration). Never enables a disabled one.
if [ "${1:-}" = "--refresh" ]; then
    crontab -l 2>/dev/null | grep -q "$CRON_TAG" || exit 0
    install_checker
    exit $?
fi

while true; do
    clear
    echo "===================================================="
    echo "             PHP-FPM AUTO-RELOAD"
    echo "===================================================="
    echo "1) Enable Auto-Reload"
    echo "2) Disable Auto-Reload"
    echo "3) Status"
    echo "4) Run Check Now"
    echo "5) View Log"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) enable_auto_reload ;;
        2) disable_auto_reload ;;
        3) status_auto_reload ;;
        4) run_now ;;
        5) view_log ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
