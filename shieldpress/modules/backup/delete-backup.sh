#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/backup.log"
mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "               DELETE BACKUP FILES"
echo "===================================================="

declare -a FOLDERS=()
i=1
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    [ -z "$DN" ] && continue
    echo "$i) $DN"
    FOLDERS[$i]=$(basename "$d")
    ((i++))
done

echo "--------------------------------------------------"
read -p "Select domain number: " choice
FOLDER="${FOLDERS[$choice]}"
[ -z "$FOLDER" ] && { echo "Invalid selection!"; pause; exit 1; }

DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
DOMAIN=$(grep "^DOMAIN=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

echo ""
echo "Backup Type:"
echo "1) Database   ($DOMAIN_PATH/backup/db)"
echo "2) Files      ($DOMAIN_PATH/backup/files)"
echo "3) Full       ($DOMAIN_PATH/backup/full)"
echo "4) Rollback   ($DOMAIN_PATH/backup/rollback*)"
echo "--------------------------------------------------"
read -p "Select type: " TYPE

case $TYPE in
    1) TARGET_DIR="$DOMAIN_PATH/backup/db" ;;
    2) TARGET_DIR="$DOMAIN_PATH/backup/files" ;;
    3) TARGET_DIR="$DOMAIN_PATH/backup/full" ;;
    4)
        # Rollback dirs bắt đầu bằng rollback_
        ROLLBACK_LIST=($(ls -d "$DOMAIN_PATH/backup/rollback_"* 2>/dev/null))
        if [ ${#ROLLBACK_LIST[@]} -eq 0 ]; then
            echo "No rollback backups found."
            pause; exit 0
        fi
        echo ""
        echo "Rollback snapshots:"
        for rb in "${ROLLBACK_LIST[@]}"; do
            SIZE=$(du -sh "$rb" 2>/dev/null | awk '{print $1}')
            echo "  $(basename $rb) [$SIZE]"
        done
        echo ""
        echo -e "\e[31mWARNING: All rollback snapshots will be permanently deleted!\e[0m"
        read -p "Continue? (y/n): " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] && rm -rf "$DOMAIN_PATH/backup/rollback_"* && \
            echo "[OK] All rollback snapshots deleted" || echo "Cancelled."
        pause; exit 0
        ;;
    *) echo "Invalid type!"; pause; exit 1 ;;
esac

[ -d "$TARGET_DIR" ] || { echo "No backup directory found."; pause; exit 0; }

# Show current usage
USAGE=$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')
COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
echo ""
echo "Directory : $TARGET_DIR"
echo "Files     : $COUNT  |  Size: $USAGE"
echo ""
echo "Delete Mode:"
echo "1) Delete All"
echo "2) Delete Specific File"
echo "3) Delete Older Than X Days"
echo "--------------------------------------------------"
read -p "Select mode: " MODE

case $MODE in
1)
    [ "$COUNT" -eq 0 ] && { echo "No files to delete."; pause; exit 0; }
    echo -e "\e[31mWARNING: All $COUNT backup files will be permanently deleted!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; pause; exit 0; }
    find "$TARGET_DIR" -type f -delete
    log "Deleted ALL backups for $DOMAIN in $TARGET_DIR"
    echo "[OK] All $COUNT files deleted."
    ;;
2)
    declare -a FILES=()
    j=1
    for f in "$TARGET_DIR"/*; do
        [ -f "$f" ] || continue
        SIZE=$(du -h "$f" | awk '{print $1}')
        echo "$j) $(basename $f)  [$SIZE]"
        FILES[$j]=$(basename "$f")
        ((j++))
    done
    [ ${#FILES[@]} -eq 0 ] && { echo "No files found."; pause; exit 0; }

    echo "--------------------------------------------------"
    read -p "Select file number: " FC
    FNAME="${FILES[$FC]}"
    [ -z "$FNAME" ] && { echo "Invalid selection!"; pause; exit 1; }

    read -p "Delete '$FNAME'? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; pause; exit 0; }
    rm -f "$TARGET_DIR/$FNAME"
    log "Deleted $FNAME for $DOMAIN"
    echo "[OK] File deleted."
    ;;
3)
    while true; do
        read -p "Delete backups older than how many days? " DAYS
        [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && break
        echo "Enter a positive number"
    done
    OLD_COUNT=$(find "$TARGET_DIR" -type f -mtime +"$DAYS" | wc -l)
    [ "$OLD_COUNT" -eq 0 ] && { echo "No files older than $DAYS days."; pause; exit 0; }

    read -p "Delete $OLD_COUNT files older than $DAYS days? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; pause; exit 0; }
    find "$TARGET_DIR" -type f -mtime +"$DAYS" -delete
    log "Deleted $OLD_COUNT backups older than $DAYS days for $DOMAIN"
    echo "[OK] $OLD_COUNT old files deleted."
    ;;
*)
    echo "Invalid mode!"
    ;;
esac

pause
