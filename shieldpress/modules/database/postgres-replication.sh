#!/bin/bash
# ShieldPress PostgreSQL physical streaming replication manager.
# Async physical replication; Laravel continues to write only to Primary.
set -u
BASE_DIR="/opt/shieldpress"; CONF="/etc/shieldpress/postgresql-replication.conf"; LOG="/var/log/shieldpress/postgresql-replication-health.log"; HEALTH_SERVICE="shieldpress-postgresql-replication-health"

# Detect the active cluster path on both RHEL-style and Debian/Ubuntu installs.
if [ -n "${PGDATA:-}" ]; then
    PGDATA="$PGDATA"
elif command -v psql >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    PGDATA=$(runuser -u postgres -- psql -Atqc 'SHOW data_directory' 2>/dev/null || true)
    PGDATA="${PGDATA:-/var/lib/pgsql/data}"
else
    PGDATA="/var/lib/pgsql/data"
fi
mkdir -p /etc/shieldpress /var/log/shieldpress; touch "$LOG"; chmod 600 "$CONF" "$LOG" 2>/dev/null || true
valid_token(){ [[ "${1:-}" =~ ^[A-Za-z0-9_.:/-]+$ ]]; }; valid_ipv4(){ [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && awk -F. '{for(i=1;i<=4;i++) if($i>255) exit 1}' <<< "$1"; }; sql_ident(){ printf '%s' "$1" | sed 's/"/""/g'; }; sql_lit(){ printf '%s' "$1" | sed "s/'/''/g"; }
server_role(){
    local detected
    detected=$(runuser -u postgres -- psql -Atqc 'SELECT CASE WHEN pg_is_in_recovery() THEN $$standby$$ ELSE $$primary$$ END' 2>/dev/null || true)
    if [ -n "$detected" ]; then
        echo "$detected"
    elif [ -f "$CONF" ]; then
        grep '^role=' "$CONF" | cut -d= -f2
    else
        echo unknown
    fi
}
show_context(){
    echo ""
    echo "Current server"
    echo "  Host   : $(hostname -f 2>/dev/null || hostname)"
    echo "  Role   : $(server_role)"
    echo "  PGDATA : $PGDATA"
    echo ""
}
confirm_text(){
    local expected="$1" answer
    read -r -p "Type $expected to continue: " answer
    [ "$answer" = "$expected" ]
}
write_pg_setting(){ local k="$1" v="$2"; sed -i -E "/^[[:space:]]*#?[[:space:]]*${k}[[:space:]]*=/d" "$PGDATA/postgresql.conf"; printf '%s = %s\n' "$k" "$v" >> "$PGDATA/postgresql.conf"; }
install_health_timer(){
    cat > "/etc/systemd/system/${HEALTH_SERVICE}.service" <<EOF
[Unit]
Description=ShieldPress PostgreSQL replication health check
After=postgresql.service
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/shieldpress/modules/database/postgres-replication.sh --health
EOF
    cat > "/etc/systemd/system/${HEALTH_SERVICE}.timer" <<EOF
[Unit]
Description=Every-minute ShieldPress PostgreSQL replication health check
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
Unit=${HEALTH_SERVICE}.service
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload; systemctl enable --now "${HEALTH_SERVICE}.timer" >/dev/null 2>&1
}
configure_primary(){
    local standby_host repl_user repl_pass slot bind_ip port hba s3_endpoint s3_bucket s3_region s3_key s3_secret s3_path confirm
    [ -f "$PGDATA/PG_VERSION" ] || { echo "PostgreSQL data directory not found: $PGDATA"; return 1; }
    show_context
    echo "SETUP MODE: THIS SERVER = PRIMARY (MAIN SERVER)"
    echo "The Primary accepts application writes. The Standby will copy its data."
    confirm_text "PRIMARY" || { echo "Cancelled; no data was changed."; return 1; }
    read -r -p "Standby IPv4 address: " standby_host; valid_ipv4 "$standby_host" || { echo "A valid standby IPv4 address is required."; return 1; }
    read -r -p "Replication role [shieldpress_repl]: " repl_user; repl_user="${repl_user:-shieldpress_repl}"; valid_token "$repl_user" || return 1
    read -r -s -p "Replication role password: " repl_pass; echo; [ -n "$repl_pass" ] || return 1
    read -r -p "Replication slot [shieldpress_standby]: " slot; slot="${slot:-shieldpress_standby}"; valid_token "$slot" || return 1
    read -r -p "Primary bind address [0.0.0.0]: " bind_ip; bind_ip="${bind_ip:-0.0.0.0}"; read -r -p "PostgreSQL port [5432]: " port; port="${port:-5432}"; [[ "$port" =~ ^[0-9]+$ ]] || return 1
    echo "Configure pgBackRest S3 repository (required for off-site WAL/PITR)."; read -r -p "S3 endpoint (without https://): " s3_endpoint; read -r -p "S3 bucket: " s3_bucket; read -r -p "S3 region [us-east-1]: " s3_region; s3_region="${s3_region:-us-east-1}"; read -r -p "S3 key: " s3_key; read -r -s -p "S3 secret: " s3_secret; echo; read -r -p "pgBackRest S3 path [shieldpress/postgresql]: " s3_path; s3_path="${s3_path:-shieldpress/postgresql}"
    for value in "$s3_endpoint" "$s3_bucket" "$s3_region" "$s3_key" "$s3_path"; do valid_token "$value" || { echo "Invalid S3 value."; return 1; }; done
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 --set=role="$(sql_lit "$repl_user")" --set=pw="$(sql_lit "$repl_pass")" -c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') THEN CREATE ROLE \"$(sql_ident "$repl_user")\" LOGIN REPLICATION PASSWORD :'pw'; ELSE ALTER ROLE \"$(sql_ident "$repl_user")\" WITH LOGIN REPLICATION PASSWORD :'pw'; END IF; END\$\$;" || return 1
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "SELECT pg_create_physical_replication_slot('$(sql_lit "$slot")') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$(sql_lit "$slot")');" >/dev/null || return 1
    write_pg_setting wal_level "'replica'"; write_pg_setting max_wal_senders 10; write_pg_setting max_replication_slots 10; write_pg_setting hot_standby on; write_pg_setting listen_addresses "'$bind_ip'"
    hba="$PGDATA/pg_hba.conf"; if ! grep -Fq "SHIELDPRESS REPLICATION $slot" "$hba"; then printf '\n# SHIELDPRESS REPLICATION %s\nhost replication %s %s/32 scram-sha-256\n' "$slot" "$repl_user" "$standby_host" >> "$hba"; fi; if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${standby_host}/32 port port=${port} protocol=tcp accept" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi; chown postgres:postgres "$PGDATA/postgresql.conf" "$hba"; restorecon "$PGDATA/postgresql.conf" "$hba" >/dev/null 2>&1 || true
    mkdir -p /etc/pgbackrest; if ! grep -q '^repo2-type=s3' /etc/pgbackrest/pgbackrest.conf 2>/dev/null; then sed -i "/^\[global\]$/a repo2-type=s3\nrepo2-path=\/$s3_path\nrepo2-s3-bucket=$s3_bucket\nrepo2-s3-endpoint=$s3_endpoint\nrepo2-s3-region=$s3_region\nrepo2-s3-key=$s3_key\nrepo2-s3-key-secret=$s3_secret\nrepo2-retention-full=7" /etc/pgbackrest/pgbackrest.conf
        chmod 600 /etc/pgbackrest/pgbackrest.conf; chown postgres:postgres /etc/pgbackrest/pgbackrest.conf; fi
    printf 'role=primary\nprimary_address=%s\nprimary_port=%s\nstandby_address=%s\nreplication_user=%s\nreplication_slot=%s\npgdata=%s\n' "$bind_ip" "$port" "$standby_host" "$repl_user" "$slot" "$PGDATA" > "$CONF"; chmod 600 "$CONF"; systemctl restart postgresql || return 1; install_health_timer; echo "Primary configured. Run pgBackRest full backup before initializing Standby."; echo "sudo -u postgres pgbackrest --stanza=<stanza> backup --type=full"
}
configure_standby(){
    local primary repl_user repl_pass slot port pgpass confirm previous_pgdata
    [ -f "$PGDATA/PG_VERSION" ] || { echo "PostgreSQL data directory not found: $PGDATA"; return 1; }
    show_context
    echo "SETUP MODE: THIS SERVER = STANDBY (SECONDARY SERVER)"
    echo "WARNING: initialization replaces the PostgreSQL data directory on THIS server."
    confirm_text "STANDBY" || { echo "Cancelled; no data was changed."; return 1; }
    read -r -p "Primary private IP/hostname: " primary
    read -r -p "Primary port [5432]: " port; port="${port:-5432}"
    read -r -p "Replication role [shieldpress_repl]: " repl_user; repl_user="${repl_user:-shieldpress_repl}"
    read -r -s -p "Replication role password: " repl_pass; echo
    read -r -p "Replication slot [shieldpress_standby]: " slot; slot="${slot:-shieldpress_standby}"
    valid_token "$primary" && valid_token "$repl_user" && valid_token "$slot" || { echo "Invalid primary, role or slot."; return 1; }
    read -r -p "This will REPLACE $PGDATA. Type REPLACE to confirm: " confirm
    [ "$confirm" = REPLACE ] || { echo "Cancelled; no data was changed."; return 1; }

    pgpass=$(mktemp /tmp/shieldpress-pgpass.XXXXXX)
    chmod 600 "$pgpass"; chown postgres:postgres "$pgpass"
    printf '%s:%s:*:%s:%s\n' "$primary" "$port" "$repl_user" "$repl_pass" > "$pgpass"
    systemctl stop postgresql || true

    # Keep the existing cluster in place until the new standby is verified.
    previous_pgdata="${PGDATA}.shieldpress-before-standby-$(date +%Y%m%d_%H%M%S)"
    if [ -e "$previous_pgdata" ] || ! mv "$PGDATA" "$previous_pgdata"; then
        rm -f "$pgpass"; systemctl start postgresql || true
        echo "Cannot safely move the existing PostgreSQL data directory; no data was changed."
        return 1
    fi
    if ! mkdir -p "$PGDATA" || ! chown postgres:postgres "$PGDATA"; then
        rmdir "$PGDATA" 2>/dev/null || true; mv "$previous_pgdata" "$PGDATA"
        rm -f "$pgpass"; systemctl start postgresql || true
        echo "Cannot prepare the new standby directory; previous data was restored."
        return 1
    fi
    if ! runuser -u postgres -- env PGPASSFILE="$pgpass" pg_basebackup -h "$primary" -p "$port" -U "$repl_user" -D "$PGDATA" -S "$slot" -R -X stream -P; then
        rm -rf "$PGDATA"; mv "$previous_pgdata" "$PGDATA"
        rm -f "$pgpass"; systemctl start postgresql || true
        echo "Standby initialization failed; previous data was restored."
        return 1
    fi
    rm -f "$pgpass"
    printf "primary_slot_name = '%s'\nhot_standby = on\n" "$slot" >> "$PGDATA/postgresql.auto.conf"
    chown postgres:postgres "$PGDATA/postgresql.auto.conf"; restorecon "$PGDATA/postgresql.auto.conf" >/dev/null 2>&1 || true
    printf 'role=standby\nprimary_address=%s\nprimary_port=%s\nreplication_user=%s\nreplication_slot=%s\npgdata=%s\n' "$primary" "$port" "$repl_user" "$slot" "$PGDATA" > "$CONF"
    chmod 600 "$CONF"; systemctl start postgresql || return 1; install_health_timer
    echo "Standby configured. Previous data retained at: $previous_pgdata"
}
health(){
    local role=unknown slot active state lag; [ -f "$CONF" ] && role=$(grep '^role=' "$CONF" | cut -d= -f2); if ! systemctl is-active --quiet postgresql; then printf '%s | failed | PostgreSQL is down\n' "$(date '+%F %T')" >> "$LOG"; return 1; fi; if [ "$role" = primary ]; then runuser -u postgres -- psql -Atqc "SELECT client_addr,state,sync_state,pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)) FROM pg_stat_replication;" || return 1; slot=$(grep '^replication_slot=' "$CONF" | cut -d= -f2); active=$(runuser -u postgres -- psql -Atqc "SELECT active FROM pg_replication_slots WHERE slot_name='$(sql_lit "$slot")';"); printf '%s | primary | slot=%s active=%s\n' "$(date '+%F %T')" "$slot" "${active:-false}" >> "$LOG"; else state=$(runuser -u postgres -- psql -Atqc 'SELECT CASE WHEN pg_is_in_recovery() THEN $$streaming/recovery$$ ELSE $$promoted/primary$$ END;' 2>/dev/null); lag=$(runuser -u postgres -- psql -Atqc 'SELECT COALESCE(pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn())), $$0 bytes$$);' 2>/dev/null); printf '%s | standby | state=%s replay_lag=%s\n' "$(date '+%F %T')" "$state" "$lag" >> "$LOG"; echo "state=$state replay_lag=$lag"; fi
}
backup_full(){ local stanza; show_context; read -r -p "pgBackRest stanza: " stanza; valid_token "$stanza" || return 1; runuser -u postgres -- pgbackrest --stanza="$stanza" check && runuser -u postgres -- pgbackrest --stanza="$stanza" backup --type=full; }
restore_check(){ local stanza target; read -r -p "pgBackRest stanza: " stanza; valid_token "$stanza" || return 1; target=$(mktemp -d /var/tmp/shieldpress-restore-check.XXXXXX); chmod 700 "$target"; if runuser -u postgres -- pgbackrest --stanza="$stanza" --pg1-path="$target" --type=immediate restore; then test -f "$target/PG_VERSION" && echo "[OK] Isolated restore completed: $target" || return 1; else echo "[FAIL] Restore check failed; target retained for inspection: $target"; return 1; fi; rm -rf "$target"; }
promote(){ [ -f "$PGDATA/standby.signal" ] || { echo "standby.signal not found; refusing promote."; return 1; }; read -r -p "Promote this standby now? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return 1; runuser -u postgres -- psql -Atqc 'SELECT pg_promote(true,60);' || return 1; sed -i '/^primary_conninfo[[:space:]]*=/d;/^primary_slot_name[[:space:]]*=/d' "$PGDATA/postgresql.auto.conf" 2>/dev/null || true; printf 'role=promoted\n' >> "$CONF"; echo "Standby promoted. Fence old primary before reconnecting clients, then move DNS/application endpoint."; }
interactive_menu(){
    while true; do
        clear
        echo "============================================================"
        echo " PostgreSQL Streaming Replication — SAFE SETUP WIZARD"
        echo "============================================================"
        show_context
        echo "Choose the role of THIS server:"
        echo "  1) THIS SERVER = PRIMARY  (Main server - accepts writes)"
        echo "  2) THIS SERVER = STANDBY  (Secondary server - receives copy)"
        echo "------------------------------------------------------------"
        echo "  3) Check replication status"
        echo "  4) Promote Standby to Primary [DANGER]"
        echo "  5) Run pgBackRest full backup"
        echo "  6) Test isolated restore"
        echo "  0) Back"
        echo "------------------------------------------------------------"
        read -r -p "Select: " c
        case "$c" in
            1) configure_primary ;;
            2) configure_standby ;;
            3) health ;;
            4) promote ;;
            5) backup_full ;;
            6) restore_check ;;
            0) break ;;
            *) echo "Invalid selection." ;;
        esac
        echo ""; read -r -p "Press Enter to continue..."
    done
}

case "${1:-}" in
    --primary) configure_primary ;;
    --standby) configure_standby ;;
    --health) health ;;
    --promote) promote ;;
    --backup-full) backup_full ;;
    --restore-check) restore_check ;;
    *) interactive_menu ;;
esac
