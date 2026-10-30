#!/bin/bash
# ============================================================
#  Update Roundcube Webmail in place
#  Uses upstream bin/installto.sh: keeps config, SQLite DB and
#  user data, runs DB schema updates. Restores backup on failure.
#  Usage: update-webmail.sh [--auto]
#    --auto  non-interactive, newest release of the installed branch
#            only (used by the ShieldPress update migration)
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"
source "$BASE_DIR/modules/helpers/task-progress.sh"

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1
WEBMAIL_BACKUP_DIR="${VAR_DIR:-/var/shieldpress}/webmail-backups"

pause(){ [ "$AUTO" -eq 1 ] || read -p "Press Enter..."; }

if [ "$AUTO" -eq 0 ]; then
    clear
    sp_header "Update Webmail" "Roundcube"
fi

CURRENT=$(rc_installed_version)
if [ -z "$CURRENT" ]; then
    fail "Roundcube installation not found at $WEBMAIL_DIR"
    pause
    exit 1
fi
BRANCH="${CURRENT%.*}"

# Interactive: offer the newest branch; auto: stay on the installed branch.
if [ "$AUTO" -eq 1 ] || ! rc_resolve_release; then
    RC_VERSION=""
fi
if [ -n "$RC_VERSION" ] && [ "${RC_VERSION%.*}" != "$BRANCH" ]; then
    echo -e "  Installed : ${CYAN}${CURRENT}${RESET}"
    echo -e "  Latest    : ${CYAN}${RC_VERSION}${RESET} (new branch ${RC_VERSION%.*})"
    # Branch upgrades can change PHP/plugin requirements.
    warn "Branch upgrade ${BRANCH} -> ${RC_VERSION%.*}: review upstream UPGRADING notes first"
    read -p "Upgrade to the new branch? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || RC_VERSION=""
fi
if [ -z "$RC_VERSION" ] && ! rc_resolve_release "$BRANCH"; then
    fail "No verified Roundcube release found for branch ${BRANCH} (GitHub unreachable or branch unsupported)"
    pause
    exit 1
fi

echo -e "  Installed : ${CYAN}${CURRENT}${RESET}"
echo -e "  Target    : ${CYAN}${RC_VERSION}${RESET}"
echo ""

if rc_version_ge "$CURRENT" "$RC_VERSION"; then
    ok "Roundcube ${CURRENT} is up to date"
    rc_security_ok "$CURRENT" || warn "Roundcube branch ${BRANCH} is unsupported; upgrade from Email > Webmail > [5]"
    pause
    exit 0
fi

if [ "$AUTO" -eq 0 ]; then
    read -p "Update now? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

log "=== WEBMAIL UPDATE ${CURRENT} -> ${RC_VERSION} ==="

PHP_BIN=$(rc_php_bin)
if [ -z "$PHP_BIN" ]; then
    fail "PHP CLI not found"
    pause
    exit 1
fi
command -v rsync >/dev/null 2>&1 || dnf install -y rsync >/dev/null 2>&1
if ! command -v rsync >/dev/null 2>&1; then
    fail "rsync is required by the Roundcube updater"
    pause
    exit 1
fi

# Backup (excluding caches) before touching any file
mkdir -p "$WEBMAIL_BACKUP_DIR"
chmod 700 "$WEBMAIL_BACKUP_DIR"
BACKUP_FILE="$WEBMAIL_BACKUP_DIR/webmail-${CURRENT}-$(date +%Y%m%d_%H%M%S).tar.gz"
if ! run_with_loading "Backing up webmail" "$DATA_DIR/roundcube-backup.time" 10 \
        tar -czf "$BACKUP_FILE" --exclude="webmail/temp/*" --exclude="webmail/logs/*" \
        -C "$(dirname "$WEBMAIL_DIR")" "$(basename "$WEBMAIL_DIR")"; then
    rm -f "$BACKUP_FILE"
    fail "Backup failed; update cancelled"
    pause
    exit 1
fi
chmod 600 "$BACKUP_FILE"
ok "Backup created: $BACKUP_FILE"

RC_TMP=$(mktemp -d /tmp/roundcube.XXXXXX)
if ! run_with_loading "Downloading Roundcube ${RC_VERSION}" "$DATA_DIR/roundcube-download.time" 15 \
        rc_fetch_release "$RC_TMP"; then
    rm -rf "$RC_TMP"
    pause
    exit 1
fi
ok "Roundcube ${RC_VERSION} downloaded (SHA-256 verified)"

restore_backup(){
    warn "Restoring Roundcube ${CURRENT} from backup..."
    rm -rf "$WEBMAIL_DIR"
    if tar -xzf "$BACKUP_FILE" -C "$(dirname "$WEBMAIL_DIR")"; then
        rc_fix_permissions
        ok "Roundcube ${CURRENT} restored"
    else
        fail "Restore failed; backup kept at $BACKUP_FILE"
    fi
}

apply_update(){
    "$PHP_BIN" "$RC_TMP/roundcubemail-${RC_VERSION}/bin/installto.sh" -y "$WEBMAIL_DIR" >>"$LOG_FILE" 2>&1
}

if run_with_loading "Applying Roundcube ${RC_VERSION}" "$DATA_DIR/roundcube-update.time" 20 apply_update \
   && [ "$(rc_installed_version)" = "$RC_VERSION" ]; then
    rm -rf "$RC_TMP"
    # installto.sh recreates the installer directory when present; never expose it
    rm -rf "$WEBMAIL_DIR/installer"
    rc_fix_permissions
    ok "Roundcube updated: ${CURRENT} -> ${RC_VERSION}"
else
    rm -rf "$RC_TMP"
    fail "Roundcube update failed (see $LOG_FILE)"
    restore_backup
    pause
    exit 1
fi

# Keep the three most recent backups
ls -1t "$WEBMAIL_BACKUP_DIR"/webmail-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f

pause
exit 0
