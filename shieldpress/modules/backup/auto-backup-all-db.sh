#!/bin/bash
# Configure independent automatic backup jobs for every application database.

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

pause(){ echo ""; read -rp "Press Enter..."; }
engine_name(){
    case "$1" in mysql|mariadb) echo mysql ;; pgsql|postgres|postgresql) echo pgsql ;; esac
}
database_script(){
    local engine="$1" db="$2" env env_db env_engine safe_name
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        env_db=$(grep '^DB_NAME=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')
        env_engine=$(engine_name "$(grep '^DB_CONNECTION=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')")
        if [ "$env_db" = "$db" ] && [ "$env_engine" = "$engine" ]; then
            printf '%s/config/auto-backup-db.sh\n' "$(dirname "$(dirname "$env")")"
            return
        fi
    done
    safe_name=$(printf '%s' "$db" | sed 's/[^a-zA-Z0-9]/_/g')
    printf '%s/config/auto-backup/auto-backup-db-%s.sh\n' "$BASE_DIR" "$safe_name"
}
schedule_status(){
    local script="$1"
    if [ -f "$script" ] && crontab -l 2>/dev/null | grep -Fq "$script"; then
        printf 'AUTO Backup conf'
    else
        printf 'No Backup'
    fi
}

declare -a ENGINES=() DATABASES=() SCRIPTS=() LABELS=()
declare -A SEEN=()
INDEX=0
add_database(){
    local engine="$1" db="$2" env env_db env_engine label script
    local key="$engine:$db"
    [ -z "$db" ] || [ -n "${SEEN[$key]:-}" ] && return
    SEEN[$key]=1
    label="standalone"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        env_db=$(grep '^DB_NAME=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')
        env_engine=$(engine_name "$(grep '^DB_CONNECTION=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')")
        if [ "$env_db" = "$db" ] && [ "$env_engine" = "$engine" ]; then
            label=$(grep '^DOMAIN=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')
            label="${label:-linked domain}"
            break
        fi
    done
    script=$(database_script "$engine" "$db")
    ((INDEX+=1))
    ENGINES[$INDEX]="$engine"
    DATABASES[$INDEX]="$db"
    SCRIPTS[$INDEX]="$script"
    LABELS[$INDEX]="$label"
    printf '%2d) %-7s %-32s %-28s %s\n' "$INDEX" "$engine" "$db" "$label" "$(schedule_status "$script")"
}

clear
echo "============================================================"
echo "       AUTO BACKUP ALL DATABASES (SEPARATE SCHEDULES)"
echo "============================================================"
echo "Each database gets its own backup script, cron schedule and retention."
echo ""
echo " #  ENGINE  DATABASE                         TARGET                       STATUS"
echo "------------------------------------------------------------"

if command -v mysql >/dev/null 2>&1; then
    while IFS= read -r db; do
        [[ "$db" =~ ^(information_schema|performance_schema|mysql|sys)$ ]] && continue
        add_database mysql "$db"
    done < <(mysql -N -e 'SHOW DATABASES;' 2>/dev/null)
fi
if command -v psql >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    while IFS= read -r db; do
        [ "$db" = postgres ] && continue
        add_database pgsql "$db"
    done < <(runuser -u postgres -- psql -tAc "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null)
fi

if [ "$INDEX" -eq 0 ]; then
    echo "No MariaDB or PostgreSQL databases found."
    pause
    exit 0
fi

declare -a MISSING=()
for ((i=1; i<=INDEX; i++)); do
    if [ "$(schedule_status "${SCRIPTS[$i]}")" = "No Backup" ]; then
        MISSING+=("$i")
    fi
done

echo "------------------------------------------------------------"
if [ "${#MISSING[@]}" -eq 0 ]; then
    echo "All listed databases already have individual automatic schedules."
    pause
    exit 0
fi
echo "${#MISSING[@]} database(s) do not have an automatic schedule."
read -rp "Configure each missing database now? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "No schedules changed."; pause; exit 0; }

for i in "${MISSING[@]}"; do
    echo ""
    echo "Configuring ${ENGINES[$i]} database ${DATABASES[$i]} (${LABELS[$i]})"
    bash "$BASE_DIR/modules/backup/auto-backup-db.sh" "${ENGINES[$i]}" "${DATABASES[$i]}"
done

echo ""
echo "Individual setup completed. Review schedules from Auto Backup Setup."
pause
