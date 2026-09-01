#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Backup & Restore" "ShieldPress VPS"

    sp_menu_grid \
        "1|Backup Database|blue" \
        "2|Backup Files|cyan" \
        "3|Backup Full (DB+Files)|green" \
        "4|Auto Backup Setup|yellow" \
        "5|Backup Status|cyan" \
        "6|Remote Storage|magenta" \
        "7|Upload to Remote|magenta" \
        "8|Telegram Backup|green" \
        "9|Restore Website|red" \
        "10|Delete Backups|red" \
        "11|Encryption|yellow" \
        "12|PostgreSQL WAL Policy|blue" \
        "0|Back|white"

    sp_prompt opt

    case $opt in
        1) bash "$BASE_DIR/modules/backup/backup-db.sh" ;;
        2) bash "$BASE_DIR/modules/backup/backup-files.sh" ;;
        3) bash "$BASE_DIR/modules/backup/backup-full.sh" ;;
        4) bash "$BASE_DIR/modules/backup/auto-backup.sh" ;;
        5) bash "$BASE_DIR/modules/backup/list-domain-backup.sh" ;;
        6) bash "$BASE_DIR/modules/backup/remote-backup.sh" ;;
        7) bash "$BASE_DIR/modules/backup/upload-backups-remote.sh" ;;
        8) bash "$BASE_DIR/modules/backup/backup-telegram.sh" ;;
        9) bash "$BASE_DIR/modules/backup/restore-site.sh" ;;
        10) bash "$BASE_DIR/modules/backup/delete-backup.sh" ;;
        11) bash "$BASE_DIR/modules/backup/backup-encrypt.sh" ;;
        12) bash "$BASE_DIR/modules/backup/configure-postgres-wal.sh" ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
