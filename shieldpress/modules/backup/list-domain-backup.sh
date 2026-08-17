#!/bin/bash

DOMAINS_ROOT="/home/domains"
BASE_DIR="/opt/shieldpress"

clear
echo "================================================================"
echo "                  DOMAIN BACKUP STATUS"
echo "================================================================"
echo ""
echo "1) Overview (all domains)"
echo "2) Detail (single domain - show all backup files)"
echo "----------------------------------------------------------------"
read -p "Select: " VIEW_MODE

case "$VIEW_MODE" in
1)
    # ===== OVERVIEW =====
    echo ""
    printf "%-25s %-6s %-6s %-10s %-8s %-12s\n" \
        "Domain" "DB" "Files" "Full" "Type" "Last Backup"
    echo "----------------------------------------------------------------"

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        DOMAIN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DOMAIN" ] && continue

        APP_TYPE=$(grep "^APP_TYPE=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        APP_TYPE="${APP_TYPE:-wp}"

        # Backup counts
        DB_COUNT=$(find "$d/backup/db" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
        FILE_COUNT=$(find "$d/backup/files" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
        FULL_COUNT=$(find "$d/backup/full" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)

        # Last backup timestamp
        LAST=$(find "$d/backup" -type f \( -name "*.gz" -o -name "*.enc" \) \
            -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
        if [ -n "$LAST" ]; then
            LAST_DATE=$(stat -c '%y' "$LAST" 2>/dev/null | cut -d'.' -f1)
        else
            LAST_DATE="-"
        fi

        # Short app type
        case "$APP_TYPE" in
            wordpress) TYPE_SHORT="WP" ;;
            laravel) TYPE_SHORT="LRV" ;;
            nodejs) TYPE_SHORT="NODE" ;;
            *) TYPE_SHORT="PHP" ;;
        esac

        printf "%-25s %-6s %-6s %-10s %-8s %-12s\n" \
            "$DOMAIN" "$DB_COUNT" "$FILE_COUNT" "$FULL_COUNT" "$TYPE_SHORT" "$LAST_DATE"
    done

    echo "================================================================"
    echo ""

    # Total backup storage
    TOTAL_BYTES=$(du -sb "$DOMAINS_ROOT"/*/backup 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    if [ "$TOTAL_BYTES" -gt 1073741824 ] 2>/dev/null; then
        TOTAL_HR="$(awk "BEGIN {printf \"%.1fG\", $TOTAL_BYTES/1073741824}")"
    elif [ "$TOTAL_BYTES" -gt 1048576 ] 2>/dev/null; then
        TOTAL_HR="$(awk "BEGIN {printf \"%.1fM\", $TOTAL_BYTES/1048576}")"
    else
        TOTAL_HR="${TOTAL_BYTES:-0} bytes"
    fi
    echo "Total backup storage: $TOTAL_HR"
    echo ""
    ;;

2)
    # ===== DETAIL: single domain =====
    echo ""
    echo "Select domain:"
    echo "--------------------------------"

    declare -a FOLDERS=()
    i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        AT=$(grep "^APP_TYPE=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        AT="${AT:-wordpress}"
        echo "$i) $DN [$AT]"
        FOLDERS[$i]=$(basename "$d")
        ((i++))
    done

    echo "--------------------------------"
    read -p "Select domain number: " choice
    FOLDER="${FOLDERS[$choice]}"
    [ -z "$FOLDER" ] && { echo "Invalid selection!"; read -p "Enter..."; exit 1; }

    DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    APP_TYPE=$(grep "^APP_TYPE=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    APP_TYPE="${APP_TYPE:-wordpress}"
    DB_NAME=$(grep "^DB_NAME=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

    echo ""
    echo "================================================================"
    echo "  BACKUP DETAIL: $DOMAIN"
    echo "================================================================"
    echo "  App Type : $APP_TYPE"
    echo "  Database : ${DB_NAME:-none} (${DB_CONNECTION:-none})"
    echo "  Path     : $DOMAIN_PATH/backup/"
    echo "================================================================"

    # Database backups
    echo ""
    echo "  DATABASE BACKUPS ($DOMAIN_PATH/backup/db/):"
    echo "  ─────────────────────────────────────────────"
    if [ -d "$DOMAIN_PATH/backup/db" ] && [ "$(ls -A "$DOMAIN_PATH/backup/db" 2>/dev/null)" ]; then
        j=1
        for f in "$DOMAIN_PATH/backup/db"/*; do
            [ -f "$f" ] || continue
            SIZE=$(du -h "$f" | awk '{print $1}')
            DATE_STR=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
            printf "    %2d) %-45s %6s  %s\n" "$j" "$(basename "$f")" "$SIZE" "$DATE_STR"
            ((j++))
        done
    else
        echo "    (no backups)"
    fi

    # File backups
    echo ""
    echo "  FILE BACKUPS ($DOMAIN_PATH/backup/files/):"
    echo "  ─────────────────────────────────────────────"
    if [ -d "$DOMAIN_PATH/backup/files" ] && [ "$(ls -A "$DOMAIN_PATH/backup/files" 2>/dev/null)" ]; then
        j=1
        for f in "$DOMAIN_PATH/backup/files"/*; do
            [ -f "$f" ] || continue
            SIZE=$(du -h "$f" | awk '{print $1}')
            DATE_STR=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
            printf "    %2d) %-45s %6s  %s\n" "$j" "$(basename "$f")" "$SIZE" "$DATE_STR"
            ((j++))
        done
    else
        echo "    (no backups)"
    fi

    # Full backups
    echo ""
    echo "  FULL BACKUPS ($DOMAIN_PATH/backup/full/):"
    echo "  ─────────────────────────────────────────────"
    if [ -d "$DOMAIN_PATH/backup/full" ] && [ "$(ls -A "$DOMAIN_PATH/backup/full" 2>/dev/null)" ]; then
        j=1
        for f in "$DOMAIN_PATH/backup/full"/*; do
            [ -f "$f" ] || continue
            SIZE=$(du -h "$f" | awk '{print $1}')
            DATE_STR=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
            printf "    %2d) %-45s %6s  %s\n" "$j" "$(basename "$f")" "$SIZE" "$DATE_STR"
            ((j++))
        done
    else
        echo "    (no backups)"
    fi

    # Total
    echo ""
    echo "  ─────────────────────────────────────────────"
    DOMAIN_BACKUP_SIZE=$(du -sh "$DOMAIN_PATH/backup" 2>/dev/null | awk '{print $1}')
    DOMAIN_BACKUP_COUNT=$(find "$DOMAIN_PATH/backup" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
    echo "  Total: $DOMAIN_BACKUP_COUNT files ($DOMAIN_BACKUP_SIZE)"
    echo ""

    # Auto-backup status
    echo "  AUTO-BACKUP STATUS:"
    echo "  ─────────────────────────────────────────────"
    [ -f "$DOMAIN_PATH/config/auto-backup-db.sh" ] && echo "    DB Auto   : ON" || echo "    DB Auto   : OFF"
    [ -f "$DOMAIN_PATH/config/auto-backup-files.sh" ] && echo "    Files Auto: ON" || echo "    Files Auto: OFF"
    [ -f "$DOMAIN_PATH/config/auto-backup-full.sh" ] && echo "    Full Auto : ON" || echo "    Full Auto : OFF"
    CRON_JOBS=$(crontab -l 2>/dev/null | grep "$FOLDER" | head -3)
    if [ -n "$CRON_JOBS" ]; then
        echo ""
        echo "  Cron schedules:"
        echo "$CRON_JOBS" | while read -r line; do
            echo "    $line"
        done
    fi
    echo ""
    ;;

*)
    echo "Invalid option"
    ;;
esac

read -p "Press Enter to continue..."
