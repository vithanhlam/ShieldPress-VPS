#!/bin/bash
# Off-site replication for the local pgBackRest repository.
set -u

BASE_DIR="/opt/shieldpress"
WAL_CONFIG="${SP_WAL_CONFIG:-/etc/shieldpress/postgresql-wal.conf}"
REMOTE_CONFIG="$BASE_DIR/config/backup-remote.env"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
SERVICE_ID="shieldpress-pgbackrest-wal-remote"
SERVICE_FILE="/etc/systemd/system/${SERVICE_ID}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_ID}.timer"
LOG_FILE="/var/log/shieldpress/pgbackrest-wal-remote.log"
LOCK_FILE="/run/lock/shieldpress-pgbackrest-wal-remote.lock"

install_timer(){
    install -d -m 755 /var/log/shieldpress /run/lock
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ShieldPress off-site pgBackRest WAL replication
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/shieldpress/modules/backup/sync-wal-remote.sh --run
EOF
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Every-minute ShieldPress off-site pgBackRest WAL replication

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
Unit=${SERVICE_ID}.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_ID}.timer"
}

run_sync(){
    local now remote cluster domain database storage enabled stanza dest
    local remotes path had_registry=0 failures=0 copied=0
    now=$(date '+%F %T')

    command -v rclone >/dev/null 2>&1 || exit 0
    [ -f "$REMOTE_CONFIG" ] || exit 0
    # shellcheck disable=SC1090
    . "$REMOTE_CONFIG"
    [ "${REMOTE_ENABLED:-0}" = "1" ] || exit 0
    remotes="${RCLONE_REMOTES:-${RCLONE_REMOTE:-}}"
    path="${RCLONE_PATH:-shieldpress-backups}"
    [ -n "$remotes" ] && [ -f "$WAL_CONFIG" ] || exit 0

    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0

    while IFS='|' read -r cluster domain database storage enabled stanza _; do
        [ -n "$cluster" ] && [ "$enabled" = "1" ] || continue
        [ -n "$storage" ] && [ -n "$stanza" ] && [ -d "$storage" ] || continue
        had_registry=1
        while IFS= read -r remote; do
            remote="${remote%:}"
            [ -n "$remote" ] || continue
            dest="${remote}:${path}/postgresql-wal/${cluster}"
            # copy, rather than sync/delete, protects the off-site copy from
            # partial local damage and keeps immutable WAL objects available.
            if rclone copy "$storage" "$dest" \
                --config="$RCLONE_CONFIG" --fast-list --transfers=2 --checkers=4 \
                --retries=3 --low-level-retries=10 --contimeout=10s --timeout=60s \
                --log-level ERROR >> "$LOG_FILE" 2>&1; then
                copied=$((copied + 1))
            else
                failures=$((failures + 1))
                printf '%s | %s | %s | %s | remote copy failed\n' \
                    "$now" "$cluster" "$domain" "$remote" >> "$LOG_FILE"
            fi
        done <<< "$(printf '%s' "$remotes" | tr ',' '\n')"
    done < "$WAL_CONFIG"

    if [ "$had_registry" = "1" ]; then
        if [ "$failures" -eq 0 ]; then
            printf '%s | success | clusters copied=%s\n' "$now" "$copied" >> "$LOG_FILE"
        else
            printf '%s | failed | remote copy failures=%s\n' "$now" "$failures" >> "$LOG_FILE"
        fi
    fi
}

case "${1:-}" in
    --install) install_timer ;;
    --run) run_sync ;;
    *) echo "Usage: $0 --install|--run" >&2; exit 2 ;;
esac
