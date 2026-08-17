#!/bin/bash

BASE_DIR="/opt/shieldpress"
CONFIG_DIR="$BASE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/telegram-notify.env"
MODULE_DIR="$BASE_DIR/modules/notification"
source "$BASE_DIR/core/ui.sh"

source "$BASE_DIR/core/paths.sh"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

pause(){ echo ""; read -p "Press Enter..."; }

load_defaults(){
    TELEGRAM_ENABLED=0
    TELEGRAM_TOKEN=""
    TELEGRAM_CHAT_ID=""
    TELEGRAM_API_BASE="https://api.telegram.org"
    NOTIFY_BACKUP_SUCCESS=1
    NOTIFY_BACKUP_FAIL=1
    NOTIFY_SERVER_ALERT=1
    NOTIFY_SECURITY_ALERT=1
    NOTIFY_INFO=0
    SERVER_MONITOR_DISK_WARN=85
    SERVER_MONITOR_RAM_WARN=90
    SERVER_MONITOR_LOAD_WARN=0

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config(){
    cat > "$CONFIG_FILE" <<EOF
TELEGRAM_ENABLED=$TELEGRAM_ENABLED
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
TELEGRAM_API_BASE=$TELEGRAM_API_BASE
NOTIFY_BACKUP_SUCCESS=$NOTIFY_BACKUP_SUCCESS
NOTIFY_BACKUP_FAIL=$NOTIFY_BACKUP_FAIL
NOTIFY_SERVER_ALERT=$NOTIFY_SERVER_ALERT
NOTIFY_SECURITY_ALERT=$NOTIFY_SECURITY_ALERT
NOTIFY_INFO=$NOTIFY_INFO
SERVER_MONITOR_DISK_WARN=$SERVER_MONITOR_DISK_WARN
SERVER_MONITOR_RAM_WARN=$SERVER_MONITOR_RAM_WARN
SERVER_MONITOR_LOAD_WARN=$SERVER_MONITOR_LOAD_WARN
EOF
    chmod 600 "$CONFIG_FILE"
}

show_status(){
    load_defaults
    echo "Current Telegram notification config:"
    echo "--------------------------------------------------"
    echo "Enabled         : $TELEGRAM_ENABLED"
    echo "Bot token       : ${TELEGRAM_TOKEN:+configured}"
    echo "Chat ID         : ${TELEGRAM_CHAT_ID:-not configured}"
    echo "API base        : $TELEGRAM_API_BASE"
    echo "Backup success  : $NOTIFY_BACKUP_SUCCESS"
    echo "Backup fail     : $NOTIFY_BACKUP_FAIL"
    echo "Server alerts   : $NOTIFY_SERVER_ALERT"
    echo "Security alerts : $NOTIFY_SECURITY_ALERT"
    echo "Info messages   : $NOTIFY_INFO"
    echo "Disk warn       : ${SERVER_MONITOR_DISK_WARN}%"
    echo "RAM warn        : ${SERVER_MONITOR_RAM_WARN}%"
    echo "Load warn       : ${SERVER_MONITOR_LOAD_WARN} (0=auto CPU cores)"
    echo "Cron            : $(crontab -l 2>/dev/null | grep -F "$MODULE_DIR/server-monitor.sh" | head -1 || echo off)"
    echo "--------------------------------------------------"
}

configure_telegram(){
    load_defaults
    echo ""
    echo "Create a bot with @BotFather, then get chat ID via:"
    echo "https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo ""
    read -p "Bot token [$TELEGRAM_TOKEN]: " TOKEN
    read -p "Chat ID [$TELEGRAM_CHAT_ID]: " CHAT_ID
    read -p "API base [$TELEGRAM_API_BASE]: " API_BASE

    TELEGRAM_TOKEN="${TOKEN:-$TELEGRAM_TOKEN}"
    TELEGRAM_CHAT_ID="${CHAT_ID:-$TELEGRAM_CHAT_ID}"
    TELEGRAM_API_BASE="${API_BASE:-$TELEGRAM_API_BASE}"
    TELEGRAM_ENABLED=1
    save_config

    echo "[OK] Telegram notification configured"
    bash "$MODULE_DIR/telegram-notify.sh" test && echo "[OK] Test sent" || echo "[WARN] Test failed"
    pause
}

toggle_value(){
    local NAME="$1"
    local CURRENT="$2"
    if [ "$CURRENT" = "1" ]; then
        eval "$NAME=0"
    else
        eval "$NAME=1"
    fi
}

toggle_events(){
    while true; do
        load_defaults
        clear
        echo "===================================================="
        echo "           NOTIFICATION EVENT TOGGLES"
        echo "===================================================="
        echo "1) Backup success  : $NOTIFY_BACKUP_SUCCESS"
        echo "2) Backup fail     : $NOTIFY_BACKUP_FAIL"
        echo "3) Server alerts   : $NOTIFY_SERVER_ALERT"
        echo "4) Security alerts : $NOTIFY_SECURITY_ALERT"
        echo "5) Info messages   : $NOTIFY_INFO"
        echo "0) Back"
        echo "--------------------------------------------------"
        read -p "Select: " opt

        case $opt in
            1) toggle_value NOTIFY_BACKUP_SUCCESS "$NOTIFY_BACKUP_SUCCESS"; save_config ;;
            2) toggle_value NOTIFY_BACKUP_FAIL "$NOTIFY_BACKUP_FAIL"; save_config ;;
            3) toggle_value NOTIFY_SERVER_ALERT "$NOTIFY_SERVER_ALERT"; save_config ;;
            4) toggle_value NOTIFY_SECURITY_ALERT "$NOTIFY_SECURITY_ALERT"; save_config ;;
            5) toggle_value NOTIFY_INFO "$NOTIFY_INFO"; save_config ;;
            0) break ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

configure_thresholds(){
    load_defaults
    while true; do
        read -p "Disk warning percent [$SERVER_MONITOR_DISK_WARN]: " D
        D="${D:-$SERVER_MONITOR_DISK_WARN}"
        [[ "$D" =~ ^[0-9]+$ ]] && [ "$D" -ge 1 ] && [ "$D" -le 99 ] && break
        echo "Enter 1-99"
    done

    while true; do
        read -p "RAM warning percent [$SERVER_MONITOR_RAM_WARN]: " R
        R="${R:-$SERVER_MONITOR_RAM_WARN}"
        [[ "$R" =~ ^[0-9]+$ ]] && [ "$R" -ge 1 ] && [ "$R" -le 99 ] && break
        echo "Enter 1-99"
    done

    while true; do
        read -p "Load warning [${SERVER_MONITOR_LOAD_WARN}, 0=auto CPU cores]: " L
        L="${L:-$SERVER_MONITOR_LOAD_WARN}"
        [[ "$L" =~ ^[0-9]+$ ]] && break
        echo "Enter a number"
    done

    SERVER_MONITOR_DISK_WARN="$D"
    SERVER_MONITOR_RAM_WARN="$R"
    SERVER_MONITOR_LOAD_WARN="$L"
    save_config
    echo "[OK] Thresholds saved"
    pause
}

schedule_monitor(){
    echo ""
    echo "Monitor interval:"
    echo "1) Every 5 minutes"
    echo "2) Every 15 minutes"
    echo "3) Every 30 minutes"
    echo "4) Hourly"
    echo "5) Disable"
    read -p "Select: " opt

    case $opt in
        1) CRON="*/5 * * * *" ;;
        2) CRON="*/15 * * * *" ;;
        3) CRON="*/30 * * * *" ;;
        4) CRON="0 * * * *" ;;
        5)
            crontab -l 2>/dev/null | grep -v -F "$MODULE_DIR/server-monitor.sh" | crontab -
            echo "[OK] Server monitor disabled"
            pause; return
            ;;
        *) echo "Invalid option"; pause; return ;;
    esac

    chmod +x "$MODULE_DIR/server-monitor.sh" "$MODULE_DIR/telegram-notify.sh" 2>/dev/null
    (crontab -l 2>/dev/null | grep -v -F "$MODULE_DIR/server-monitor.sh"; echo "$CRON bash $MODULE_DIR/server-monitor.sh") | crontab -
    echo "[OK] Server monitor scheduled: $CRON"
    pause
}

while true; do
    clear
    sp_header "Telegram Notifications" "Alerts and event routing"
    show_status
    sp_menu_grid \
        "1|Configure Telegram Bot|green" \
        "2|Toggle Events|yellow" \
        "3|Alert Thresholds|blue" \
        "4|Schedule Monitor|magenta" \
        "5|Send Test|cyan" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) configure_telegram ;;
        2) toggle_events ;;
        3) configure_thresholds ;;
        4) schedule_monitor ;;
        5) bash "$MODULE_DIR/telegram-notify.sh" test; pause ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
