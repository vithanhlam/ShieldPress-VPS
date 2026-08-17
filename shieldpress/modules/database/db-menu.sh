#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/database"
DOMAINS_DIR="/home/domains"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Database Manager" "MariaDB & PostgreSQL"

    # Check which DB engines are available
    MARIA_OK=0
    PG_OK=0
    systemctl is-active --quiet mariadb 2>/dev/null && MARIA_OK=1
    systemctl is-active --quiet postgresql 2>/dev/null && PG_OK=1

    if [ "$MARIA_OK" = "1" ]; then
        echo -e "  MariaDB: \e[32mRunning\e[0m"
    else
        echo -e "  MariaDB: \e[31mStopped\e[0m"
    fi
    if [ "$PG_OK" = "1" ]; then
        echo -e "  PostgreSQL: \e[32mRunning\e[0m"
    else
        echo -e "  PostgreSQL: \e[33mN/A\e[0m"
    fi
    sp_hr

    sp_menu_grid \
        "1|MariaDB Manager|green" \
        "2|PostgreSQL Manager|blue" \
        "3|Optimize MariaDB|green" \
        "4|DB Configuration|yellow" \
        "5|Export MariaDB|cyan" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) bash $MODULE_DIR/mariadb-menu.sh ;;
        2) bash $MODULE_DIR/pg-menu.sh ;;
        3) bash "$BASE_DIR/modules/optimize/db-optimize.sh" ;;
        4) bash $MODULE_DIR/config-db.sh ;;
        5) bash $MODULE_DIR/export-db.sh ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
