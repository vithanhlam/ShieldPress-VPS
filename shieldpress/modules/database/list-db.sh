#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/custom.sh"

DATA_FILE="$DATA_DIR/databases.list"
DOMAINS_ROOT="/home/domains"
MODULE_DIR="$BASE_DIR/modules/database"

get_field(){
    local line="$1"
    local key="$2"
    echo "$line" | tr '|' '\n' | sed 's/^ *//;s/ *$//' | grep "^${key}=" | head -n1 | cut -d'=' -f2-
}

db_size_mb(){
    local db="$1"
    mysql -N -e "
SELECT COALESCE(ROUND(SUM(data_length + index_length)/1024/1024,2),0)
FROM information_schema.tables
WHERE table_schema='${db}';
" 2>/dev/null
}

domain_using_db(){
    local db="$1"
    local env domain domain_db

    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        domain=$(grep "^DOMAIN=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        domain_db=$(grep "^DB_NAME=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')

        if [ "$domain_db" = "$db" ]; then
            echo "$domain"
            return
        fi
    done

    echo "-"
}

database_exists(){
    local db="$1"
    [ "$(mysql -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db}';" 2>/dev/null)" = "$db" ]
}

sync_domain_databases(){
    local env domain db_connection db_user db_pass db_name

    mkdir -p "$DATA_DIR"
    touch "$DATA_FILE"

    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue

        domain=$(grep "^DOMAIN=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        db_connection=$(grep "^DB_CONNECTION=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        db_name=$(grep "^DB_NAME=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        db_user=$(grep "^DB_USER=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        db_pass=$(grep "^DB_PASS=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')

        [ -n "$db_name" ] || continue
        [ "$db_connection" = "pgsql" ] && continue
        grep -q "^DB_NAME=$db_name[[:space:]]*|" "$DATA_FILE" 2>/dev/null && continue

        echo "DB_NAME=$db_name | DB_USER=$db_user | DB_PASS=$db_pass | DOMAIN=$domain | CREATED=imported-from-domain-env" >> "$DATA_FILE"
    done
}

show_database_detail(){
    local line="$1"
    local db_name db_user db_pass db_domain created domain size exists_status action confirm

    db_name=$(get_field "$line" "DB_NAME")
    db_user=$(get_field "$line" "DB_USER")
    db_pass=$(get_field "$line" "DB_PASS")
    db_domain=$(get_field "$line" "DOMAIN")
    created=$(get_field "$line" "CREATED")
    domain="$(domain_using_db "$db_name")"
    [ "$domain" = "-" ] && [ -n "$db_domain" ] && domain="$db_domain"

    if database_exists "$db_name"; then
        exists_status="exists"
        size="$(db_size_mb "$db_name") MB"
    else
        exists_status="missing"
        size="-"
    fi

    while true; do
        clear
        echo "===================================================="
        echo "                DATABASE INFORMATION"
        echo "===================================================="
        echo "Database : $db_name"
        echo "User     : ${db_user:-"-"}"
        echo "Password : ${db_pass:-"-"}"
        echo "Domain   : ${domain:-"-"}"
        echo "Size     : $size"
        echo "Status   : $exists_status"
        echo "Created  : ${created:-"-"}"
        echo "----------------------------------------------------"
        echo "1) Delete Database + User"
        echo "0) Back"
        echo "----------------------------------------------------"
        read -p "Select: " action

        case "$action" in
            1)
                echo ""
                echo -e "\e[31mWARNING: This will permanently delete database '$db_name' and its user!\e[0m"
                read -p "Continue? (y/n): " confirm

                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    echo "Cancelled."
                    sleep 1
                    continue
                fi

                bash "$MODULE_DIR/delete-db.sh" "$db_name" --confirmed
                return
                ;;
            0) return ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

while true; do
    clear
    echo "===================================================="
    echo "                 DATABASE LIST"
    echo "===================================================="

    sync_domain_databases

    if [ ! -s "$DATA_FILE" ]; then
        echo "No managed databases found."
        pause
        exit 0
    fi

    DB_LINES=()
    while IFS= read -r line; do
        DB_NAME=$(get_field "$line" "DB_NAME")
        [ -n "$DB_NAME" ] && DB_LINES+=("$line")
    done < "$DATA_FILE"

    if [ "${#DB_LINES[@]}" -eq 0 ]; then
        echo "No valid managed databases found."
        pause
        exit 0
    fi

    printf "%-4s %-32s %-20s %s\n" "No" "Database" "User" "Size"
    echo "----------------------------------------------------------------"

    idx=1
    for line in "${DB_LINES[@]}"; do
        DB_NAME=$(get_field "$line" "DB_NAME")
        DB_USER=$(get_field "$line" "DB_USER")
        [ -n "$DB_NAME" ] || continue

        if database_exists "$DB_NAME"; then
            DB_SIZE="$(db_size_mb "$DB_NAME") MB"
        else
            DB_SIZE="-"
        fi

        printf "%-4s %-32s %-20s %s\n" "$idx" "$DB_NAME" "${DB_USER:-"-"}" "$DB_SIZE"
        idx=$((idx + 1))
    done

    echo "----------------------------------------------------------------"
    echo "Enter database number to view details, or 0 to back."
    read -p "Select: " CHOICE

    [ "$CHOICE" = "0" ] && exit 0

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#DB_LINES[@]}" ]; then
        echo "Invalid option"
        sleep 1
        continue
    fi

    SELECTED_LINE="${DB_LINES[$((CHOICE - 1))]}"
    SELECTED_DB=$(get_field "$SELECTED_LINE" "DB_NAME")

    [ -n "$SELECTED_DB" ] || { echo "Invalid database record"; sleep 1; continue; }
    show_database_detail "$SELECTED_LINE"
done
