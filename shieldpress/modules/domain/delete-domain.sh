#!/bin/bash

source /opt/shieldpress/modules/domain/helpers.sh

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

    backup_domain_before_delete || { read -p "Press Enter..."; exit 1; }

    ENGINE="$DB_CONNECTION"
    case "$ENGINE" in mariadb) ENGINE=mysql ;; postgres|postgresql) ENGINE=pgsql ;; esac
    python3 "$BASE_DIR/modules/backup/cleanup-domain-jobs.py" \
        --base "$BASE_DIR" --domains "$DOMAINS_ROOT" --domain "$DOMAIN_PATH" \
        --db "$DB_NAME" --engine "$ENGINE" || {
        echo "[FAIL] Schedule cleanup failed. Domain deletion stopped."
        exit 1
    }

    delete_database || { echo "[FAIL] Database deletion failed. Domain deletion stopped."; exit 1; }
    delete_source
    delete_configs

    # Remove SFTP group membership if present.
    gpasswd -d "$CLEAN_DOMAIN" sftpusers &>/dev/null && echo "[OK] SFTP removed"

    echo ""
    echo "[OK] Domain $SELECTED_DOMAIN fully deleted"
    ;;
2)
    read -p "Delete source files for $SELECTED_DOMAIN? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }
    backup_domain_before_delete || { read -p "Press Enter..."; exit 1; }
    delete_source
    echo "[OK] Source files deleted"
    ;;
3)
    read -p "Delete database for $SELECTED_DOMAIN? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }
    delete_database || { echo "[FAIL] Database deletion failed."; exit 1; }
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
