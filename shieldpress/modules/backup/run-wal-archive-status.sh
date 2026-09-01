#!/bin/bash
set -u
BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/backup/_backup_helper.sh"
STATUS_DIR="${SP_BACKUP_STATUS_DIR:-/var/log/shieldpress/domain-backup-status}"
WAL_CONFIG="${SP_WAL_CONFIG:-/etc/shieldpress/postgresql-wal.conf}"
[ -f "$WAL_CONFIG" ] || exit 0
mkdir -p "$STATUS_DIR"

while IFS='|' read -r cluster domain db storage enabled interval stanza; do
    [ "$enabled" = 1 ] || continue
    [ -n "$domain" ] || continue
    safe=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
    domain_path="$DOMAINS_ROOT/$safe"
    [ -d "$domain_path" ] || continue
    state=success
    message="cluster WAL archive check passed (database=$db; no per-database WAL filtering)"
    if ! runuser -u postgres -- psql -Atqc 'SELECT 1' >/dev/null 2>&1; then
        state=failed; message="PostgreSQL is unavailable"
    elif ! command -v pgbackrest >/dev/null 2>&1; then
        state=failed; message="pgBackRest is not installed"
    elif [ -n "$stanza" ] && ! runuser -u postgres -- pgbackrest --stanza="$stanza" check >/dev/null 2>&1; then
        state=failed; message="pgBackRest check failed for stanza=$stanza"
    fi
    now=$(date '+%Y-%m-%d %H:%M:%S')
    printf 'domain=%s\ndatabase=%s\nstate=%s\nupdated=%s\nmessage=%s\n' "$domain" "$db" "$state" "$now" "$message" > "$STATUS_DIR/$safe.env"
    printf '%s | %s | %s | %s\n' "$now" "$domain" "$state" "$message" >> "$domain_path/logs/backup-wal.log"
    if [ "$state" = failed ]; then
        shieldpress_notify_event "backup_fail" "PostgreSQL WAL archive failed" "$domain: $message" 2>/dev/null || true
    fi
done < "$WAL_CONFIG"
