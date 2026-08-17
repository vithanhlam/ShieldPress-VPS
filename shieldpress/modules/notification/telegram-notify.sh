#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
CONFIG_DIR="$BASE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/telegram-notify.env"
LOG_FILE="$LOG_DIR/telegram-notify.log"

mkdir -p "$CONFIG_DIR" "$LOG_DIR"

log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

load_config(){
    [ -f "$CONFIG_FILE" ] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-0}"
    TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
    NOTIFY_BACKUP_SUCCESS="${NOTIFY_BACKUP_SUCCESS:-1}"
    NOTIFY_BACKUP_FAIL="${NOTIFY_BACKUP_FAIL:-1}"
    NOTIFY_SERVER_ALERT="${NOTIFY_SERVER_ALERT:-1}"
    NOTIFY_SECURITY_ALERT="${NOTIFY_SECURITY_ALERT:-1}"
    NOTIFY_INFO="${NOTIFY_INFO:-0}"

    [ "$TELEGRAM_ENABLED" = "1" ] || return 1
    [ -n "$TELEGRAM_TOKEN" ] || return 1
    [ -n "$TELEGRAM_CHAT_ID" ] || return 1
}

category_enabled(){
    case "$1" in
        backup_success) [ "$NOTIFY_BACKUP_SUCCESS" = "1" ] ;;
        backup_fail) [ "$NOTIFY_BACKUP_FAIL" = "1" ] ;;
        server_alert) [ "$NOTIFY_SERVER_ALERT" = "1" ] ;;
        security_alert) [ "$NOTIFY_SECURITY_ALERT" = "1" ] ;;
        info|test) [ "$NOTIFY_INFO" = "1" ] || [ "$1" = "test" ] ;;
        *) return 0 ;;
    esac
}

send_message(){
    local CATEGORY="$1"
    local TITLE="$2"
    local BODY="$3"
    local HOST
    HOST=$(hostname 2>/dev/null || echo "server")

    load_config || exit 0
    category_enabled "$CATEGORY" || exit 0

    local TEXT
    TEXT=$(printf '[ShieldPress] %s\nServer: %s\nType: %s\nTime: %s\n\n%s' \
        "$TITLE" "$HOST" "$CATEGORY" "$(date '+%F %T %Z')" "$BODY")

    curl -fsS --connect-timeout 5 --max-time 15 \
        -X POST "${TELEGRAM_API_BASE}/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        --data-urlencode text="$TEXT" >/dev/null

    if [ $? -eq 0 ]; then
        log "SENT $CATEGORY | $TITLE"
    else
        log "FAILED $CATEGORY | $TITLE"
        exit 1
    fi
}

case "$1" in
    send)
        shift
        send_message "$1" "$2" "$3"
        ;;
    test)
        send_message "test" "Telegram notification test" "If you received this message, notification is working."
        ;;
    *)
        echo "Usage: $0 send <category> <title> <body>"
        echo "       $0 test"
        exit 1
        ;;
esac
