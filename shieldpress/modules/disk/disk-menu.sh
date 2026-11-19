#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
BACKUP_DIR="$BACKUP_GLOBAL_DIR"

pause(){ echo ""; read -r -p "Press Enter..."; }

# =================================================
# REPORTS (read-only; rendered by disk-report.py)
# =================================================

REPORT="$BASE_DIR/modules/disk/disk-report.py"
export DATA_DIR

report_header(){
    clear
    sp_header "$1" "Disk Manager"
}

disk_overview(){
    report_header "Disk Usage Overview"
    python3 -I "$REPORT" overview --domains "$DOMAINS_ROOT" --base "$BASE_DIR" --backups "$BACKUP_DIR"
}

top_files_domain(){
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return
    local site="$DOMAIN_PATH/public_html"
    [ -d "$site" ] || site="$DOMAIN_PATH"
    report_header "Largest Files: $SELECTED_DOMAIN"
    python3 -I "$REPORT" files "$site" --label "$SELECTED_DOMAIN"
}

top_files_all(){
    report_header "Largest Files: All Domains"
    python3 -I "$REPORT" files "$DOMAINS_ROOT" --all
}

backup_size(){
    report_header "Backup Storage"
    python3 -I "$REPORT" backups "$BACKUP_DIR" --logs "$LOG_DIR" --data "$DATA_DIR" --base "$BASE_DIR"
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "Disk Manager" "Storage & file analysis"
    sp_menu_grid \
        "1|Disk Usage Overview|cyan" \
        "2|Top Files (Single Domain)|blue" \
        "3|Top Files (All Domains)|blue" \
        "4|Backup Storage Size|yellow" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) disk_overview ;;
        2) top_files_domain ;;
        3) top_files_all ;;
        4) backup_size ;;
        0) break ;;
        *) sp_invalid; continue ;;
    esac

    pause
done
