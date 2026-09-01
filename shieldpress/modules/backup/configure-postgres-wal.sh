#!/bin/bash
set -u
BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/backup/_backup_helper.sh"
WAL_CONFIG="${SP_WAL_CONFIG:-/etc/shieldpress/postgresql-wal.conf}"
STATUS_DIR="${SP_BACKUP_STATUS_DIR:-/var/log/shieldpress/domain-backup-status}"
WAL_RETENTION_FULL=7
mkdir -p "$STATUS_DIR" "$(dirname "$WAL_CONFIG")" 2>/dev/null || true

select_pg_database(){
    local i=1 db choice size d env_db dbc
    declare -g -a PG_DATABASES=()
    echo "PostgreSQL databases (select by number):"
    echo "--------------------------------------------------"
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        size=$(runuser -u postgres -- psql -Atqc "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null)
        linked="-"
        for d in "$DOMAINS_ROOT"/*/; do
            [ -f "$d/config/domain.env" ] || continue
            env_db=$(grep '^DB_NAME=' "$d/config/domain.env" | cut -d= -f2- | tr -d '[:space:]')
            dbc=$(grep '^DB_CONNECTION=' "$d/config/domain.env" | cut -d= -f2- | tr -d '[:space:]')
            if [ "$env_db" = "$db" ] && [[ "$dbc" =~ ^(pgsql|postgres|postgresql)$ ]]; then
                linked=$(grep '^DOMAIN=' "$d/config/domain.env" | cut -d= -f2- | tr -d '[:space:]')
                break
            fi
        done
        printf "  %2d) %-32s %-10s domain: %s\n" "$i" "$db" "${size:--}" "$linked"
        PG_DATABASES[$i]="$db"
        i=$((i+1))
    done < <(runuser -u postgres -- psql -Atqc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn=true AND datname NOT IN ('postgres') ORDER BY datname;" 2>/dev/null)
    [ "$i" -gt 1 ] || { echo "No PostgreSQL databases found."; return 1; }
    echo "--------------------------------------------------"
    read -r -p "Select PostgreSQL database number: " choice
    DB_NAME="${PG_DATABASES[$choice]:-}"
    [ -n "$DB_NAME" ] || { echo "Invalid selection."; return 1; }

    DOMAIN_PATH=""
    for d in "$DOMAINS_ROOT"/*/; do
        [ -f "$d/config/domain.env" ] || continue
        env_db=$(grep '^DB_NAME=' "$d/config/domain.env" | cut -d= -f2- | tr -d '[:space:]')
        dbc=$(grep '^DB_CONNECTION=' "$d/config/domain.env" | cut -d= -f2- | tr -d '[:space:]')
        if [ "$env_db" = "$DB_NAME" ] && [[ "$dbc" =~ ^(pgsql|postgres|postgresql)$ ]]; then
            DOMAIN_PATH="$d"
            break
        fi
    done
    [ -n "$DOMAIN_PATH" ] || { echo "Selected database is not linked to a PostgreSQL domain.env."; return 1; }
    load_domain_info "$DOMAIN_PATH"
}

set_cfg(){
    local file="$1" key="$2" value="$3" tmp="${1}.tmp.$$"
    awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {if(!done){print k "=" v; done=1}; next} {print} END{if(!done) print k "=" v}' "$file" > "$tmp" && mv "$tmp" "$file"
    restorecon "$file" >/dev/null 2>&1 || true
    chmod 600 "$file"
}

write_status(){
    local state="$1" message="$2" now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$STATUS_DIR"
    printf 'domain=%s\ndatabase=%s\nstate=%s\nupdated=%s\nmessage=%s\n' "$DOMAIN" "$DB_NAME" "$state" "$now" "$message" > "$STATUS_DIR/${CLEAN_DOMAIN:-$DOMAIN}.env"
    printf '%s | %s | %s | %s\n' "$now" "$DOMAIN" "$state" "$message" >> "$DOMAIN_PATH/logs/backup-wal.log"
}

install_expire_timer(){
    local timer_id="shieldpress-pgbackrest-expire-${SAFE_CLUSTER}"
    local service="/etc/systemd/system/${timer_id}.service"
    local timer="/etc/systemd/system/${timer_id}.timer"
    local expire_log="/var/log/shieldpress/pgbackrest-expire-${SAFE_CLUSTER}.log"

    cat > "$service" <<EOF
[Unit]
Description=ShieldPress pgBackRest WAL retention (${SAFE_CLUSTER})
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/bin/sh -c '/usr/bin/pgbackrest --stanza=${STANZA} --repo1-retention-full=${WAL_RETENTION_FULL} expire >> ${expire_log} 2>&1'
EOF
    cat > "$timer" <<EOF
[Unit]
Description=Daily ShieldPress pgBackRest WAL retention (${SAFE_CLUSTER})

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
Unit=${timer_id}.service

[Install]
WantedBy=timers.target
EOF
    install -d -o postgres -g postgres -m 750 "$(dirname "$expire_log")"
    touch "$expire_log"
    chown postgres:postgres "$expire_log"
    chmod 640 "$expire_log"
    systemctl daemon-reload
    systemctl enable --now "${timer_id}.timer" >/dev/null 2>&1 || return 1
    echo "$timer_id"
}

select_pg_database || exit 1
BENV="$DOMAIN_PATH/config/backup.env"
[ -f "$BENV" ] || { echo "Missing $BENV"; exit 1; }
PG_DATA=$(runuser -u postgres -- psql -Atqc 'show data_directory' 2>/dev/null | tr -d '[:space:]')
PG_PORT=$(runuser -u postgres -- psql -Atqc 'show port' 2>/dev/null | tr -d '[:space:]')
[ -n "$PG_DATA" ] || { echo "Cannot identify PostgreSQL data directory."; write_status failed "cluster detection failed"; exit 1; }
CLUSTER_ID="${PG_DATA}:${PG_PORT:-5432}"
SAFE_CLUSTER=$(printf '%s' "$CLUSTER_ID" | sha256sum | cut -c1-16)
REQUESTED_MODE=$(grep '^postgres_backup_mode=' "$BENV" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
REQUESTED_MODE="${REQUESTED_MODE:-cluster-wal}"
STANZA_MODE=cluster-wal
if [ "$REQUESTED_MODE" = "pgbackrest" ] && grep -q '^PG_CLUSTER_DATA_DIR=' "$DOMAIN_PATH/config/domain.env" 2>/dev/null; then
    STANZA_MODE=pgbackrest
fi
echo "Domain: $DOMAIN"
echo "Cluster: $CLUSTER_ID"
read -r -p "Enable WAL archiving policy for this domain? [y/N]: " enabled
if [[ "$enabled" =~ ^[Yy]$ ]]; then WAL_ENABLED=1; else WAL_ENABLED=0; fi
while true; do
    read -r -p "WAL status interval [1m] (1m/5m/15m/hourly): " interval
    interval="${interval:-1m}"
    [[ "$interval" =~ ^(1m|5m|15m|hourly)$ ]] && break
    echo "Use 1m, 5m, 15m or hourly. WAL itself is continuous."
done
read -r -p "Archive storage path (absolute local path): " storage
if [ "$WAL_ENABLED" = 1 ] && [[ "$storage" != /* ]]; then
    echo "Storage must be an absolute local path."; write_status failed "invalid storage path"; exit 1
fi
# Ensure the cluster registry exists before conflict validation.  awk returns
# non-zero for a missing file, which would otherwise look like a real conflict.
touch "$WAL_CONFIG" 2>/dev/null || { write_status failed "cannot create WAL registry"; exit 1; }
chmod 600 "$WAL_CONFIG"
if [ "$WAL_ENABLED" = 1 ] && ! awk -F'|' -v c="$SAFE_CLUSTER" -v s="$storage" '$1 == c && $5 == 1 && $4 != "" && $4 != s {bad=1} END{exit bad}' "$WAL_CONFIG" 2>/dev/null; then
    echo "A shared PostgreSQL cluster already has a different WAL storage target. One archive destination must serve the whole cluster."
    write_status failed "shared cluster storage target conflict"; exit 1
fi
set_cfg "$BENV" backup_enabled "${DB_BACKUP_ENABLED:-1}"
set_cfg "$BENV" backup_frequency "${DB_BACKUP_FREQUENCY:-daily}"
set_cfg "$BENV" backup_storage "$storage"
set_cfg "$BENV" wal_backup_enabled "$WAL_ENABLED"
set_cfg "$BENV" wal_backup_interval "$interval"
set_cfg "$BENV" postgres_cluster_id "$CLUSTER_ID"
set_cfg "$BENV" postgres_backup_mode "$STANZA_MODE"
if [ "$STANZA_MODE" = pgbackrest ]; then
    STANZA="sp-domain-$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-16)"
else
    STANZA="sp-cluster-$SAFE_CLUSTER"
fi
set_cfg "$BENV" pgbackrest_stanza "$STANZA"

touch "$WAL_CONFIG"; chmod 600 "$WAL_CONFIG"
grep -v "|$DOMAIN|" "$WAL_CONFIG" 2>/dev/null > "${WAL_CONFIG}.tmp" || true
printf '%s|%s|%s|%s|%s|%s|%s\n' "$SAFE_CLUSTER" "$DOMAIN" "$DB_NAME" "$storage" "$WAL_ENABLED" "$interval" "$STANZA" >> "${WAL_CONFIG}.tmp"
mv "${WAL_CONFIG}.tmp" "$WAL_CONFIG"
# This is a lightweight health/status poll only. It does not execute pg_dump.
(crontab -l 2>/dev/null | grep -v 'run-wal-archive-status.sh'; echo "* * * * * $BASE_DIR/modules/backup/run-wal-archive-status.sh") | crontab -

if [ "$WAL_ENABLED" = 1 ]; then
    if ! command -v pgbackrest >/dev/null 2>&1; then
        write_status failed "pgBackRest is required; policy saved but archive was not activated"
        echo "[FAIL] pgBackRest is not installed. Policy saved; install it before activation."; exit 1
    fi
    mkdir -p /etc/pgbackrest "$storage"
    if ! grep -q '^repo1-path=' /etc/pgbackrest/pgbackrest.conf 2>/dev/null; then
        cat > /etc/pgbackrest/pgbackrest.conf << EOF
[global]
repo1-path=$storage
repo1-retention-full=7
repo1-type=posix
process-max=2

[${STANZA}]
pg1-path=$PG_DATA
EOF
    fi
    chown -R postgres:postgres "$storage" 2>/dev/null || true
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t postgresql_db_t "$storage(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t postgresql_db_t "$storage(/.*)?" 2>/dev/null || true
        restorecon -Rv "$storage" >/dev/null 2>&1 || true
    fi
    runuser -u postgres -- pgbackrest --stanza="$STANZA" stanza-create >/dev/null 2>&1 || true
    PG_CONF="$PG_DATA/postgresql.conf"
    if [ ! -f "$PG_CONF" ]; then
        write_status failed "PostgreSQL configuration file not found"
        exit 1
    fi
    sed -i '/^[[:space:]]*archive_mode[[:space:]]*=/d; /^[[:space:]]*archive_command[[:space:]]*=/d' "$PG_CONF"
    printf "archive_mode = 'on'\narchive_command = 'pgbackrest --stanza=%s archive-push %%p'\n" "$STANZA" >> "$PG_CONF"
    chown postgres:postgres "$PG_CONF" 2>/dev/null || true
    restorecon "$PG_CONF" >/dev/null 2>&1 || true
    systemctl restart postgresql >/dev/null 2>&1 || { write_status failed "PostgreSQL restart failed"; exit 1; }
    runuser -u postgres -- pgbackrest --stanza="$STANZA" check >/dev/null 2>&1 || { write_status failed "pgBackRest check failed"; exit 1; }
    install_expire_timer >/dev/null 2>&1 || { write_status failed "could not install WAL retention timer"; exit 1; }
    if [ "$STANZA_MODE" = pgbackrest ]; then
        write_status success "WAL archive enabled for explicitly isolated PostgreSQL cluster"
    else
        write_status success "WAL archive enabled at shared cluster level; domain policy active"
    fi
else
    write_status disabled "domain WAL policy disabled; shared cluster archive is unchanged"
fi
echo "[OK] Policy saved in $BENV"
echo "WAL is archived continuously at cluster level; $interval controls status checks only."
echo "Existing daily backup schedules were not modified."
