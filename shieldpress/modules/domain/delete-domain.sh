#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/modules/domain/helpers.sh"
source "$BASE_DIR/modules/helpers/task-progress.sh"

delete_stage(){
    local key="$1" label="$2" estimate="$3"
    shift 3
    run_with_loading "$label" "$DATA_DIR/domain-delete-${key}.time" "$estimate" "$@"
}

optional_delete_backup(){
    local answer
    while true; do
        read -r -p "Back up files and configuration before deletion? [Y/n]: " answer || return 1
        case "$answer" in
            ""|y|Y) delete_stage backup "Backing up files and configuration" 120 backup_domain_before_delete; return $? ;;
            n|N) echo "[INFO] Backup skipped."; return 0 ;;
            *) echo "Please enter Y or n." ;;
        esac
    done
}

backup_domain_before_delete(){
    local backup_root="$BACKUP_GLOBAL_DIR/domain-delete/$CLEAN_DOMAIN"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    mkdir -p "$backup_root"

    tar --ignore-failed-read -czf "$backup_root/${CLEAN_DOMAIN}-pre-delete-${ts}.tar.gz" \
        --exclude="${CLEAN_DOMAIN}/public_html/node_modules" \
        --exclude="${CLEAN_DOMAIN}/public_html/.next/cache" \
        -C "$(dirname "$DOMAIN_PATH")" "$CLEAN_DOMAIN" \
        -C /etc/nginx/conf.d "${CLEAN_DOMAIN}.conf" \
        -C /etc/systemd/system "${CLEAN_DOMAIN}-node.service" 2>/dev/null || {
            echo "[FAIL] Backup failed. Delete cancelled."
            return 1
        }

    echo "[OK] Backup created: $backup_root/${CLEAN_DOMAIN}-pre-delete-${ts}.tar.gz"
}

select_domain || exit

echo ""
echo "===================================================="
echo "  DELETE DOMAIN - $SELECTED_DOMAIN"
echo "===================================================="
echo "1) Delete FULL (Source + DB + Config + Cron)"
echo "2) Delete Source Only"
echo "3) Delete Database Only"
echo "0) Cancel"
echo "----------------------------------------------------"
read -p "Select: " opt

case $opt in
1)
    echo ""
    echo -e "\e[31mWARNING: This will permanently delete domain '$SELECTED_DOMAIN' and all its data!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }

    optional_delete_backup || { read -p "Press Enter..."; exit 1; }

    ENGINE="$DB_CONNECTION"
    case "$ENGINE" in mariadb) ENGINE=mysql ;; postgres|postgresql) ENGINE=pgsql ;; esac
    delete_stage schedules "Cleaning scheduled jobs" 10 python3 "$BASE_DIR/modules/backup/cleanup-domain-jobs.py" \
        --base "$BASE_DIR" --domains "$DOMAINS_ROOT" --domain "$DOMAIN_PATH" \
        --db "$DB_NAME" --engine "$ENGINE" || {
        echo "[FAIL] Schedule cleanup failed. Domain deletion stopped."
        exit 1
    }

    delete_stage database "Deleting database" 30 delete_database || { echo "[FAIL] Database deletion failed. Domain deletion stopped."; exit 1; }
    delete_stage source "Deleting source files" 60 delete_source || { echo "[FAIL] Source deletion failed."; exit 1; }
    delete_stage configs "Deleting configuration and domain directory" 30 delete_configs || { echo "[FAIL] Configuration cleanup failed."; exit 1; }

    # Remove SFTP group membership if present.
    gpasswd -d "$CLEAN_DOMAIN" sftpusers &>/dev/null && echo "[OK] SFTP removed"

    echo ""
    echo "[OK] Domain $SELECTED_DOMAIN fully deleted"
    ;;
2)
    read -p "Delete source files for $SELECTED_DOMAIN? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }
    optional_delete_backup || { read -p "Press Enter..."; exit 1; }
    delete_stage source "Deleting source files" 60 delete_source || { echo "[FAIL] Source deletion failed."; exit 1; }
    echo "[OK] Source files deleted"
    ;;
3)
    read -p "Delete database for $SELECTED_DOMAIN? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }
    delete_stage database "Deleting database" 30 delete_database || { echo "[FAIL] Database deletion failed."; exit 1; }
    echo "[OK] Database deleted"
    ;;
0)
    exit 0
    ;;
*)
    echo "Invalid option"
    ;;
esac

echo ""
read -p "Press Enter..."
