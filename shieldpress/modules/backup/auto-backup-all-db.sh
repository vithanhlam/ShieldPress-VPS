#!/bin/bash
# Configure independent automatic backup jobs for every application database.

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

pause(){ echo ""; read -rp "Press Enter..."; }
engine_name(){
    case "$1" in mysql|mariadb) echo mysql ;; pgsql|postgres|postgresql) echo pgsql ;; esac
}
database_script(){
    local engine="$1" db="$2" env env_db env_engine safe_name legacy_script
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
    legacy_script="$BASE_DIR/config/auto-backup/auto-backup-db-${safe_name}.sh"
    if [ -f "$legacy_script" ] && crontab -l 2>/dev/null | grep -Fq "$legacy_script"; then
        printf '%s\n' "$legacy_script"
    else
        printf '%s/config/auto-backup/auto-backup-db-%s-%s.sh\n' "$BASE_DIR" "$engine" "$safe_name"
    fi
}
schedule_status(){
    local script="$1"
    if [ -x "$script" ] && crontab -l 2>/dev/null | awk -v path="$script" '
        $0 !~ /^[[:space:]]*#/ && index($0, path) { found=1 }
        END { exit !found }
    '; then
        printf 'Scheduled'
    else
        printf 'No schedule'
    fi
}

declare -a ENGINES=() DATABASES=() SCRIPTS=() LABELS=()
declare -a BACKUP_DIRS=() NO_LOCAL=()
declare -A SEEN=()
INDEX=0
add_database(){
    local engine="$1" db="$2" env env_db env_engine label script backup_dir status
    local key="$engine:$db"
    [ -z "$db" ] || [ -n "${SEEN[$key]:-}" ] && return
    SEEN[$key]=1
    label="standalone"
    backup_dir="$BASE_DIR/backup/standalone-db"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        env_db=$(grep '^DB_NAME=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')
        env_engine=$(engine_name "$(grep '^DB_CONNECTION=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')")
        if [ "$env_db" = "$db" ] && [ "$env_engine" = "$engine" ]; then
            label=$(grep '^DOMAIN=' "$env" | cut -d'=' -f2- | tr -d '[:space:]')
            label="${label:-linked domain}"
            backup_dir="$(dirname "$(dirname "$env")")/backup/db"
            break
        fi
    done
    script=$(database_script "$engine" "$db")
    ((INDEX+=1))
    ENGINES[$INDEX]="$engine"
    DATABASES[$INDEX]="$db"
    SCRIPTS[$INDEX]="$script"
    LABELS[$INDEX]="$label"
    BACKUP_DIRS[$INDEX]="$backup_dir"
    status=$(schedule_status "$script")
    if [ "$status" = Scheduled ] && ! find "$backup_dir" -maxdepth 1 -type f \
        -name "${db}_*.sql.gz" -print -quit 2>/dev/null | grep -q .; then
        status='Scheduled; no local file'
        NO_LOCAL+=("$INDEX")
    fi
    printf '%2d) %-7s %-32s %-28s %s\n' "$INDEX" "$engine" "$db" "$label" "$status"
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
    if [ "$(schedule_status "${SCRIPTS[$i]}")" = "No schedule" ]; then
        MISSING+=("$i")
    fi
done

echo "------------------------------------------------------------"
if [ "${#MISSING[@]}" -eq 0 ]; then
    echo "All listed databases have individual automatic schedules."
    if [ "${#NO_LOCAL[@]}" -gt 0 ]; then
        echo "${#NO_LOCAL[@]} scheduled database(s) have no local .sql.gz backup file:"
        for i in "${NO_LOCAL[@]}"; do
            echo "  ${DATABASES[$i]}: ${BACKUP_DIRS[$i]}"
        done
        echo "Check $LOG_DIR/auto-backup.log and the remote backup settings."
        echo "Local files may be removed after a successful remote upload if configured."
    fi
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
