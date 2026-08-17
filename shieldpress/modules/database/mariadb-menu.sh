#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/database"
DOMAINS_DIR="/home/domains"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "MariaDB Manager" "Create, import, manage"
    sp_menu_grid \
        "1|Create Database + User|green" \
        "2|Database List|cyan" \
        "3|Delete Database + User|red" \
        "4|Change DB Password|yellow" \
        "5|Import SQL|blue" \
        "6|Import to Domain DB|blue" \
        "7|Optimize Tables|green" \
        "8|Open Adminer|magenta" \
        "9|Set DB to Website|cyan" \
        "10|Export Database|cyan" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) bash $MODULE_DIR/create-db.sh ;;
        2) bash $MODULE_DIR/list-db.sh ;;
        3) bash $MODULE_DIR/delete-db.sh ;;
        4) bash $MODULE_DIR/change-pass.sh ;;
        5) bash $MODULE_DIR/import-db.sh ;;
        6) bash $MODULE_DIR/import-domain.sh ;;
        7) bash $MODULE_DIR/optimize-db.sh ;;
        8) bash $MODULE_DIR/adminer.sh ;;
        9) bash $MODULE_DIR/set-db-to-domain.sh ;;
        10) bash $MODULE_DIR/export-db.sh ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
