#!/bin/bash

# =========================================
# ShieldPress VPS ENTERPRISE UPDATE ENGINE v2
# ZERO-DOWNTIME + AUTO ROLLBACK + SAFE
# =========================================

set -o pipefail

BASE_DIR="/opt/shieldpress"
# Keep update backups outside the replaceable runtime tree.  The atomic
# switch removes the old /opt/shieldpress directory after a successful update.
BACKUP_DIR="/var/shieldpress/update-backups"
TMP_DIR="/tmp/shieldpress_update"
NEW_DIR="/tmp/shieldpress_new"
OLD_DIR="/opt/shieldpress_old"
LOCK_FILE="/tmp/shieldpress_update.lock"

VERSION_FILE="$BASE_DIR/version.txt"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/update-source.sh"
LOG_FILE="$LOG_DIR/update.log"

mkdir -p "$BACKUP_DIR" "$TMP_DIR" "$LOG_DIR"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"; }
ok(){ log "[OK] $1"; }
fail(){ log "[FAIL] $1"; rollback; exit 1; }

# Trap unexpected errors → rollback + exit
on_error(){
    local EXIT_CODE=$?
    local LINE_NO=$1
    log "[FAIL] Unexpected error at line $LINE_NO (exit code $EXIT_CODE)"
    rollback
    exit $EXIT_CODE
}
trap 'on_error $LINENO' ERR
set -e
write_installed_version(){
    echo "$TARGET_VERSION" > "$BASE_DIR/version.txt" || fail "Cannot write version.txt"
    chmod 644 "$BASE_DIR/version.txt" 2>/dev/null || true
}
is_update_pid_running(){
    local pid="$1"
    [ -n "$pid" ] || return 1
    [ "$pid" != "$$" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "updater.sh"
}
find_running_update_pid(){
    local proc pid
    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid=${proc##*/}
        if is_update_pid_running "$pid"; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}
acquire_update_lock(){
    local lock_pid running_pid

    if [ -f "$LOCK_FILE" ]; then
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)

        if is_update_pid_running "$lock_pid"; then
            echo "Another update is running! PID: $lock_pid"
            exit 1
        fi

        running_pid=$(find_running_update_pid || true)
        if [ -n "$running_pid" ]; then
            echo "Another update is running! PID: $running_pid"
            exit 1
        fi

        log "Removing stale update lock: $LOCK_FILE"
        rm -f "$LOCK_FILE"
    fi

    echo "$$" > "$LOCK_FILE"
}
cleanup_update_lock(){
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$LOCK_FILE"
    fi
}
trap 'cleanup_update_lock' EXIT

# =========================================
# LOCK (tránh chạy 2 lần)
# =========================================
acquire_update_lock

# =========================================
# ROLLBACK FUNCTION
# =========================================
rollback(){
    log "ROLLBACK INITIATED"

    if [ -d "$OLD_DIR" ]; then
        rm -rf "$BASE_DIR"
        mv "$OLD_DIR" "$BASE_DIR"
        log "Rollback completed"
    fi

    cleanup_update_lock
}

# =========================================
# CHECK DEPENDENCIES
# =========================================
for cmd in curl tar rsync sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || dnf install -y "$cmd" >/dev/null 2>&1
done

CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || fail "version.txt not found")
TARGET_VERSION="${SHIELDPRESS_TARGET_VERSION:-}"

if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$(sp_remote_version || true)
fi

if [ -z "$TARGET_VERSION" ]; then
    fail "Cannot detect latest version from $SHIELDPRESS_GITHUB_REPO"
fi

log "Update source: github.com/$SHIELDPRESS_GITHUB_REPO"
log "Current version: $CURRENT"
log "Target version: $TARGET_VERSION"

HEALTH_SERVICES=()
for svc in nginx mariadb postgresql valkey; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        HEALTH_SERVICES+=("$svc")
    else
        log "Service $svc is not running before update; skipping post-update health check for it"
    fi
done

# =========================================
# BACKUP
# =========================================
log "Creating backup..."

BACKUP_FILE="$BACKUP_DIR/shieldpress_$(date +%Y%m%d_%H%M%S).tar.gz"
TMP_BACKUP_FILE="$TMP_DIR/$(basename "$BACKUP_FILE")"
rm -f "$TMP_BACKUP_FILE"

tar -czf "$TMP_BACKUP_FILE" \
    --exclude="shieldpress/update-backups" \
    --exclude="shieldpress/logs" \
    -C /opt shieldpress || fail "Backup failed"

mv "$TMP_BACKUP_FILE" "$BACKUP_FILE" || fail "Cannot move backup into $BACKUP_DIR"
ok "Backup created: $BACKUP_FILE"

# =========================================
# DOWNLOAD + VERIFY
# =========================================
log "Downloading update from GitHub..."

EXTRACT_DIR="$TMP_DIR/extract"
rm -rf "$TMP_DIR" "$NEW_DIR"
mkdir -p "$TMP_DIR" "$NEW_DIR" "$EXTRACT_DIR"
cd "$TMP_DIR"

CHECKSUM_URL=$(sp_checksum_url "$TARGET_VERSION")
EXPECTED=""
if [ -n "$CHECKSUM_URL" ]; then
    curl -fsSL --connect-timeout 5 --max-time 20 "$CHECKSUM_URL" -o shieldpress.sha256 2>/dev/null \
        && EXPECTED=$(awk '{print $1}' shieldpress.sha256 2>/dev/null) \
        || EXPECTED=""
fi

# Never install an update whose release artifact cannot be verified.
[ -n "$EXPECTED" ] || fail "Release checksum unavailable; refusing unverified update"

SOURCE_ROOT=""
PACKAGE_USED=""

while IFS= read -r CANDIDATE_URL; do
    [ -n "$CANDIDATE_URL" ] || continue
    log "Trying package: $CANDIDATE_URL"

    rm -f shieldpress.tar.gz
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    if ! curl -fsSL --connect-timeout 10 --max-time 300 "$CANDIDATE_URL" -o shieldpress.tar.gz 2>/dev/null; then
        log "Package not available, trying next source"
        continue
    fi

    if [ -n "$EXPECTED" ]; then
        ACTUAL=$(sha256sum shieldpress.tar.gz | awk '{print $1}')
        if [ "$EXPECTED" != "$ACTUAL" ]; then
            log "Checksum mismatch for this package, trying next source"
            continue
        fi
        ok "Integrity verified"
    fi

    if ! tar -xzf shieldpress.tar.gz -C "$EXTRACT_DIR" 2>/dev/null; then
        log "Extraction failed, trying next source"
        continue
    fi

    SOURCE_ROOT=$(sp_find_source_root "$EXTRACT_DIR" || true)
    if [ -n "$SOURCE_ROOT" ]; then
        PACKAGE_USED="$CANDIDATE_URL"
        break
    fi

    log "Package has no runtime source, trying next source"
done < <(sp_package_urls "$TARGET_VERSION")

[ -n "$SOURCE_ROOT" ] || fail "Cannot download a valid package from GitHub"
ok "Package ready: $PACKAGE_USED"

# =========================================
# STAGE NEW SOURCE
# =========================================
log "Staging new version..."
rsync -a "$SOURCE_ROOT/" "$NEW_DIR/" || fail "Cannot stage new source"

[ -f "$NEW_DIR/shieldpress.sh" ] || fail "shieldpress.sh not found after extraction"

# preserve config files
for item in config.env license.key license.status config; do
    [ -e "$BASE_DIR/$item" ] && cp -a "$BASE_DIR/$item" "$NEW_DIR/$item" 2>/dev/null || true
done

# preserve persistent directories (now outside /opt/shieldpress)
# Migrate old locations if they exist as real dirs (not symlinks)
for dir in data logs backups-global; do
    if [ -d "$BASE_DIR/$dir" ] && [ ! -L "$BASE_DIR/$dir" ]; then
        # Old-style: real dir inside source - move to new location
        case "$dir" in
            logs)           rsync -a "$BASE_DIR/$dir/" /var/shieldpress/logs/ ;;
            data)           rsync -a "$BASE_DIR/$dir/" /var/shieldpress/data/ ;;
            backups-global) rsync -a "$BASE_DIR/$dir/" /home/backup-all/ ;;
        esac
    fi
done

# Ensure symlinks for backward compat in new install dir
if [ -f "$NEW_DIR/core/paths.sh" ]; then
    source "$NEW_DIR/core/paths.sh"
    ensure_shieldpress_dirs 2>/dev/null || true
    create_compat_symlinks 2>/dev/null || true
fi

mkdir -p "$NEW_DIR/update-backups"

# =========================================
# ATOMIC SWITCH
# =========================================
log "Switching version..."

rm -rf "$OLD_DIR"
mv "$BASE_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$BASE_DIR"

# =========================================
# FIX PERMISSION
# =========================================
log "Fixing permissions..."

write_installed_version
chmod +x "$BASE_DIR/shieldpress.sh" || fail "Cannot chmod shieldpress.sh"
find "$BASE_DIR/modules" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
chmod +x "$BASE_DIR/core"/*.sh 2>/dev/null || true
ln -sf "$BASE_DIR/shieldpress.sh" /usr/bin/shieldpress
ln -sf "$BASE_DIR/shieldpress.sh" /usr/local/bin/shieldpress

# =========================================
# SERVICE HEALTH CHECK
# =========================================
log "Checking services..."

for svc in "${HEALTH_SERVICES[@]}"; do
    if ! systemctl is-active --quiet $svc; then
        log "$svc is NOT running → rollback"
        rollback
        exit 1
    fi
done

# =========================================
# FINAL VERIFY
# =========================================
if [ ! -f "$BASE_DIR/shieldpress.sh" ]; then
    fail "shieldpress.sh missing"
fi

INSTALLED_VERSION=$(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo "")
if [ "$INSTALLED_VERSION" != "$TARGET_VERSION" ]; then
    fail "version.txt was not updated"
fi

# =========================================
# CLEANUP
# =========================================
rm -rf "$TMP_DIR" "$OLD_DIR"
write_installed_version
cleanup_update_lock

ok "UPDATE SUCCESSFULLY"
ok "Installed version: $(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo unknown)"

# =========================================
# AUTO-APPLY MIGRATION PATCHES
# =========================================
PATCHES_SCRIPT="$BASE_DIR/modules/patches/patches-menu.sh"
if [ -f "$PATCHES_SCRIPT" ]; then
    log "Running migration patches..."
    bash "$PATCHES_SCRIPT" --auto 2>&1 | tee -a "$LOG_FILE" || true
    ok "Migration patches applied"
fi

echo ""
echo "======================================"
echo "   ShieldPress VPS UPDATE COMPLETED"
echo "   Version: $(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo unknown)"
echo "======================================"
