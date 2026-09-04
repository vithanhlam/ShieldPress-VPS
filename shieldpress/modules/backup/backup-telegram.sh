#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAINS_ROOT="/home/domains"
source "$BASE_DIR/core/paths.sh"
CONFIG_FILE="$BASE_DIR/config.env"
LOG_FILE="$LOG_DIR/telegram-backup.log"

source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$LOG_DIR"

# Domain selector for telegram backup
select_domain_telegram(){
    echo ""
    echo "Available Domains:"
    echo "--------------------------------------------------"
    declare -g -a TG_FOLDERS=()
    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        echo "$i) $DN"
        TG_FOLDERS[$i]=$(basename "$d")
        ((i++))
    done
    echo "--------------------------------------------------"
    read -p "Select domain number: " choice
    local FOLDER="${TG_FOLDERS[$choice]}"
    [ -z "$FOLDER" ] && return 1
    DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    return 0
}

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"; }
fail(){ log "[FAILED] $1"; }
ok(){ log "[OK] $1"; }

# =========================================
# LOAD TELEGRAM CONFIG
# =========================================
load_telegram(){
    [ ! -f "$CONFIG_FILE" ] && fail "Config not found" && return 1
    TELEGRAM_TOKEN=$(grep "^TELEGRAM_TOKEN=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_CHAT=$(grep "^TELEGRAM_CHAT=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_API_BASE=$(grep "^TELEGRAM_API_BASE=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT" ]; then
        fail "Telegram not configured"
        return 1
    fi
}

# =========================================
# BACKUP DB + THEMES + PLUGINS
# =========================================
create_backup(){

    select_domain_telegram || {
        log "ERROR: Domain selection failed"
        exit 1
    }

    DOMAIN_NAME="$DOMAIN"
    load_domain_info "$DOMAIN_PATH"

    # ===== LOG DOMAIN =====
    local DOMAIN_LOG_DIR="$DOMAIN_PATH/logs"
    mkdir -p "$DOMAIN_LOG_DIR"
    BACKUP_INDEX="$DOMAIN_LOG_DIR/telegram-backup.log"

    BACKUP_DIR="$DOMAIN_PATH/backup/telegram"
    mkdir -p "$BACKUP_DIR"

    TMP_DIR=$(mktemp -d /tmp/shieldpress_backup_XXXXXX)

    log "Preparing backup for $DOMAIN ($APP_TYPE)..."

    # Database dump (generic - supports MySQL/MariaDB/PostgreSQL)
    if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
        backup_db_to_file "$TMP_DIR/db.sql.gz" 2>/dev/null
        if [ $? -ne 0 ]; then
            warn "Database backup failed, continuing with files only"
        fi
    fi

    # Archive source files (generic - supports WP/Laravel/Node.js)
    archive_source_to_file "$TMP_DIR/files.tar.gz" 2>/dev/null
    if [ $? -ne 0 ]; then
        fail "Source file backup failed"
        rm -rf "$TMP_DIR"
        return 1
    fi

    FILE="$BACKUP_DIR/${DOMAIN_NAME}_$(date +%Y%m%d_%H%M%S).tar.gz"

    if command -v pigz >/dev/null 2>&1; then
        tar -cf - -C "$TMP_DIR" . | pigz -4 > "$FILE"
    else
        tar -czf "$FILE" -C "$TMP_DIR" .
    fi

    rm -rf "$TMP_DIR"

    ok "Backup created: $FILE"

    echo "$(date '+%Y-%m-%d %H:%M:%S')|CREATED|$FILE" >> "$BACKUP_INDEX"

    echo "$FILE" > /tmp/shieldpress_last_backup
}

# =========================================
# SPLIT FILE < 50MB
# =========================================
split_file(){
    FILE="$1"
    SPLIT_PREFIX="${FILE}.part_"

    split -b 18M "$FILE" "$SPLIT_PREFIX"

    ls ${SPLIT_PREFIX}*
}



# =========================================
# SEND MULTI PART TELEGRAM
# =========================================
send_parts(){

    load_telegram || return 1

    FILE="$1"

    LOG_DIR="$DOMAIN_PATH/logs"
    BACKUP_INDEX="$LOG_DIR/telegram-backup.log"
    mkdir -p "$LOG_DIR"


    SPLIT_PREFIX="${FILE}.part_"

    log "Splitting file..."
    split -b 18M "$FILE" "$SPLIT_PREFIX"

    SUCCESS=true

    for part in ${SPLIT_PREFIX}*; do

        SIZE=$(du -h "$part" | cut -f1)
        log "Uploading $(basename "$part") ($SIZE)..."

        RESPONSE=$(curl -s -X POST "${TELEGRAM_API_BASE}/bot${TELEGRAM_TOKEN}/sendDocument" \
            -F chat_id="$TELEGRAM_CHAT" \
            -F document=@"$part")

        FILE_ID=$(echo "$RESPONSE" | jq -r '.result.document.file_id')

        if [ -n "$FILE_ID" ] && [ "$FILE_ID" != "null" ]; then
            ok "Uploaded $(basename "$part")"

            echo "$(date '+%Y-%m-%d %H:%M:%S')|PART|$(basename "$part")|$FILE_ID" >> "$BACKUP_INDEX"
        else
            fail "Upload failed $(basename "$part")"
            echo "$RESPONSE"
            SUCCESS=false
        fi

        sleep 1
    done

    rm -f ${SPLIT_PREFIX}*

    # ===== FINAL LOG =====
    if [ "$SUCCESS" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')|UPLOADED|$FILE" >> "$BACKUP_INDEX"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S')|FAILED|$FILE" >> "$BACKUP_INDEX"
    fi

    rm -f "$FILE"
}

# =========================================
# BACKUP NOW
# =========================================
backup_now(){
    create_backup || return 1
    FILE=$(cat /tmp/shieldpress_last_backup)
    send_parts "$FILE"
}

# =========================================
# TEST TELEGRAM
# =========================================
test_telegram(){

    load_telegram || return 1

    curl -s -X POST "${TELEGRAM_API_BASE}/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT" \
        -d text="✅ ShieldPress Telegram Backup OK" >/dev/null

    ok "Test sent"
}

# =========================================
# CONFIG TELEGRAM (GIỮ NGUYÊN)
# =========================================
config_telegram(){

    echo ""
    echo "========================================"
    echo "        TELEGRAM CONFIG SETUP"
    echo "========================================"

    # =========================
    # LOAD CURRENT CONFIG
    # =========================
    TELEGRAM_TOKEN=$(grep "^TELEGRAM_TOKEN=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_CHAT=$(grep "^TELEGRAM_CHAT=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_API_BASE=$(grep "^TELEGRAM_API_BASE=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

    echo ""

    if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT" ]; then
        echo "Current config detected:"
        echo "----------------------------------------"
        echo "Bot Token : $TELEGRAM_TOKEN"
        echo "Chat ID   : $TELEGRAM_CHAT"
        echo "----------------------------------------"
        echo ""
        read -p "Keep current config? [Y/n]: " KEEP
        KEEP="${KEEP:-y}"

        if [[ "$KEEP" =~ ^[yY]$ ]]; then
            echo ""
            echo "👉 Testing current config..."

            curl -s -X POST "${TELEGRAM_API_BASE}/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT" \
                -d text="✅ ShieldPress Telegram OK (test message)" >/dev/null

            if [ $? -eq 0 ]; then
                ok "Telegram is working!"
            else
                fail "Telegram test failed!"
            fi

            return 0
        fi
    fi

    # =========================
    # GUIDE
    # =========================
    echo ""
    echo "👉 Create bot: @BotFather → /newbot"
    echo "👉 Add bot to group → send message"
    echo "👉 Get Chat ID:"
    echo "   https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo ""

    # =========================
    # INPUT TOKEN
    # =========================
    read -p "Enter Bot Token: " TOKEN

    echo ""
    echo "👉 Open this link to get Chat ID:"
    echo "https://api.telegram.org/bot${TOKEN}/getUpdates"
    echo ""

    # =========================
    # INPUT CHAT ID
    # =========================
    read -p "Enter Chat ID: " CHAT

    echo ""
    echo "👉 Testing Telegram..."

    # =========================
    # TEST BEFORE SAVE
    # =========================
    RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -d chat_id="$CHAT" \
        -d text="✅ ShieldPress Telegram Config Success")

    if echo "$RESPONSE" | grep -q '"ok":true'; then

        echo ""
        ok "Telegram test SUCCESS!"

        # =========================
        # SAVE CONFIG
        # =========================
        sed -i "/TELEGRAM_TOKEN/d" "$CONFIG_FILE"
        sed -i "/TELEGRAM_CHAT/d" "$CONFIG_FILE"

        echo "TELEGRAM_TOKEN=$TOKEN" >> "$CONFIG_FILE"
        echo "TELEGRAM_CHAT=$CHAT" >> "$CONFIG_FILE"

        echo ""
        ok "Config saved!"

    else
        echo ""
        fail "Telegram test FAILED!"
        echo ""
        echo "Response:"
        echo "$RESPONSE"
        echo ""
        echo "❌ Not saved. Please check TOKEN / CHAT ID."
    fi
}
# =========================================
# LIST BACKUP (GIỮ NGUYÊN)
# =========================================
list_telegram(){

    load_telegram || return 1
    select_domain_telegram || return 1

    local TG_BACKUP_DIR="$DOMAIN_PATH/backup/telegram"
    BACKUP_INDEX="$DOMAIN_PATH/logs/telegram-backup.log"

    mkdir -p "$TG_BACKUP_DIR"
    mkdir -p "$(dirname "$BACKUP_INDEX")"

    [ ! -f "$BACKUP_INDEX" ] && echo "No backup log found" && return 1

    echo ""
    echo "Reading backup list from log..."

    # =========================
    # LẤY BACKUP ĐÃ UPLOAD
    # =========================
    mapfile -t BACKUPS < <(
        grep "|UPLOADED|" "$BACKUP_INDEX" \
        | awk -F'|' '{print $3}' \
        | sort -u
    )

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "No backups found in log"
        return 1
    fi

    echo ""
    echo "Available backups:"
    echo "--------------------------------"

    for i in "${!BACKUPS[@]}"; do
        echo "$((i+1))) ${BACKUPS[$i]}"
    done

    echo "--------------------------------"
    read -p "Select backup: " choice

    SELECTED="${BACKUPS[$((choice-1))]}"
    [ -z "$SELECTED" ] && echo "Invalid selection" && return 1

    SELECTED_NAME=$(basename "$SELECTED")

    echo ""
    echo "Selected: $SELECTED_NAME"
    read -p "Download now? (y/n): " confirm
    [ "$confirm" != "y" ] && return 1

    # =========================
    # LẤY PART TỪ LOG
    # =========================
    echo ""
    echo "Reading parts from log..."

    mapfile -t FILE_DATA < <(
        grep "|PART|" "$BACKUP_INDEX" \
        | awk -F'|' -v name="$SELECTED_NAME" '$3 ~ "^"name {print $3 "|" $4}'
    )

    if [ ${#FILE_DATA[@]} -eq 0 ]; then
        echo "No file parts found in log!"
        return 1
    fi

    TMP_DIR=$(mktemp -d /tmp/telegram_download_XXXXXX)

    echo ""
    echo "Downloading parts..."

    PART_FILES=()

    for item in "${FILE_DATA[@]}"; do

        FILE_NAME=$(echo "$item" | cut -d'|' -f1)
        FILE_ID=$(echo "$item" | cut -d'|' -f2)

        if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
            echo "Invalid file_id: $FILE_NAME"
            continue
        fi

        FILE_PATH=""

        for i in {1..3}; do
            RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getFile?file_id=$FILE_ID")
            FILE_PATH=$(echo "$RESP" | jq -r '.result.file_path')

            if [ -n "$FILE_PATH" ] && [ "$FILE_PATH" != "null" ]; then
                break
            fi

            echo "Retry $i..."
            sleep 2
        done

        if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
            echo "Failed to get file path: $FILE_NAME"
            echo "Response: $RESP"
            continue
        fi

        echo "Downloading $FILE_NAME..."

        curl -s -o "$TMP_DIR/$FILE_NAME" \
            "https://api.telegram.org/file/bot${TELEGRAM_TOKEN}/${FILE_PATH}"

        # =========================
        # VALIDATE FILE
        # =========================
        SIZE=$(stat -c%s "$TMP_DIR/$FILE_NAME" 2>/dev/null)

        if [ -z "$SIZE" ] || [ "$SIZE" -lt 500000 ]; then
            echo "Invalid file (too small): $FILE_NAME ($SIZE bytes)"
            head -c 200 "$TMP_DIR/$FILE_NAME"
            echo ""
            rm -f "$TMP_DIR/$FILE_NAME"
            continue
        fi


        PART_FILES+=("$TMP_DIR/$FILE_NAME")
    done

    if [ ${#PART_FILES[@]} -eq 0 ]; then
        echo "No valid parts downloaded!"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # =========================
    # MERGE
    # =========================
    echo ""
    echo "Merging parts..."

    IFS=$'\n' PART_FILES_SORTED=($(printf "%s\n" "${PART_FILES[@]}" | sort -V))
    unset IFS

    FINAL_PATH="$TG_BACKUP_DIR/$SELECTED_NAME"

    cat "${PART_FILES_SORTED[@]}" > "$FINAL_PATH"

    if [ ! -f "$FINAL_PATH" ]; then
        echo "Merge failed!"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # =========================
    # VERIFY TAR
    # =========================
    tar -tzf "$FINAL_PATH" >/dev/null 2>&1 || {
        echo "Corrupted archive!"
        rm -f "$FINAL_PATH"
        rm -rf "$TMP_DIR"
        return 1
    }

    echo ""
    echo "================================"
    echo " DOWNLOAD COMPLETED"
    echo "================================"
    echo "Saved to: $FINAL_PATH"

    echo "$(date '+%Y-%m-%d %H:%M:%S')|DOWNLOADED|$FINAL_PATH" >> "$BACKUP_INDEX"

    rm -rf "$TMP_DIR"
}
# =========================================
# SCHEDULE BACKUP (UPGRADE)
# =========================================
schedule_backup(){

    select_domain_telegram || return 1

    DOMAIN_NAME="$DOMAIN"

    echo ""
    echo "=============================="
    echo " TELEGRAM BACKUP SCHEDULER"
    echo "=============================="
    echo "1) Add / Update Schedule"
    echo "2) Remove Schedule"
    echo "3) View Current Schedule"
    echo "0) Back"
    echo "------------------------------"
    read -p "Choose: " action

    case $action in

        # =========================
        # ADD / UPDATE
        # =========================
        1)
            echo ""
            echo "1) Daily"
            echo "2) Weekly"
            echo "3) Monthly"
            read -p "Choose: " type

            case $type in
                1)
                    read -p "Hour (0-23): " H
                    CRON="0 $H * * *"
                    ;;
                2)
                    read -p "Day of week (0-6): " D
                    read -p "Hour: " H
                    CRON="0 $H * * $D"
                    ;;
                3)
                    read -p "Day of month (1-31): " D
                    read -p "Hour: " H
                    CRON="0 $H $D * *"
                    ;;
                *)
                    echo "Invalid"; return
                    ;;
            esac

            CMD="$CRON bash $BASE_DIR/modules/backup/backup-telegram.sh run $DOMAIN_NAME"

            # remove cron cũ của domain này
            (crontab -l 2>/dev/null | grep -v "backup-telegram.sh run $DOMAIN_NAME"; echo "$CMD") | crontab -

            ok "Scheduled updated for $DOMAIN_NAME"
            ;;

        # =========================
        # REMOVE
        # =========================
        2)
            echo ""
            echo "Removing schedule for $DOMAIN_NAME..."

            NEW_CRON=$(crontab -l 2>/dev/null | grep -v "backup-telegram.sh run $DOMAIN_NAME")

            echo "$NEW_CRON" | crontab -

            ok "Schedule removed for $DOMAIN_NAME"
            ;;

        # =========================
        # VIEW
        # =========================
        3)
            echo ""
            echo "Current schedule for $DOMAIN_NAME:"
            echo "--------------------------------"

            crontab -l 2>/dev/null | grep "backup-telegram.sh run $DOMAIN_NAME" || echo "No schedule found"

            echo "--------------------------------"
            ;;

        0)
            return
            ;;

        *)
            echo "Invalid option"
            ;;
    esac
}

# =========================================
# RUN CRON
# =========================================
run_cron(){

    DOMAIN_NAME="$1"
    DOMAIN_FOLDER=$(echo "$DOMAIN_NAME" | sed 's/[^a-zA-Z0-9]/_/g')
    DOMAIN_PATH="$DOMAINS_ROOT/$DOMAIN_FOLDER"
    DOMAIN="$DOMAIN_NAME"

    load_domain_info "$DOMAIN_PATH"

    local CRON_BACKUP_DIR="$DOMAIN_PATH/backup/telegram"
    mkdir -p "$CRON_BACKUP_DIR"

    TMP="$CRON_BACKUP_DIR/${DOMAIN_NAME}_cron.tar.gz"
    TMP_DIR=$(mktemp -d /tmp/shieldpress_tg_cron_XXXXXX)

    # Database dump (generic)
    if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
        backup_db_to_file "$TMP_DIR/db.sql.gz" >/dev/null 2>&1
    fi

    # Archive source files (generic)
    archive_source_to_file "$TMP_DIR/files.tar.gz" >/dev/null 2>&1

    if command -v pigz >/dev/null 2>&1; then
        tar -cf - -C "$TMP_DIR" . | pigz -4 > "$TMP"
    else
        tar -czf "$TMP" -C "$TMP_DIR" .
    fi

    rm -rf "$TMP_DIR"

    send_parts "$TMP"

    rm -f "$TMP"
}

# =========================================
# CRON MODE (RUN FIRST)
# =========================================
if [ "$1" = "run" ]; then
    run_cron "$2"
    exit 0
fi

# =========================================
# MENU (GIỮ NGUYÊN)
# =========================================
while true; do

clear
echo "===================================================="
echo "        TELEGRAM BACKUP PRO"
echo "===================================================="
echo " 1) Backup Now"
echo " 2) Schedule Backup"
echo " 3) Test Telegram"
echo " 4) Config Telegram"
echo " 5) List Backup (Telegram)"
echo " 0) Back"
echo "----------------------------------------------------"

read -p "Select: " opt

case $opt in
    1) backup_now; read -p "Enter..." ;;
    2) schedule_backup; read -p "Enter..." ;;
    3) test_telegram; read -p "Enter..." ;;
    4) config_telegram; read -p "Enter..." ;;
    5) list_telegram; read -p "Enter..." ;;
    0) exit ;;
    *) echo "Invalid"; sleep 1 ;;
esac

done
