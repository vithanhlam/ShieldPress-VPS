#!/bin/bash
# ====================================================
# ShieldPress Upgrade Gate
# Trung tâm kiểm soát mọi nâng cấp phần mềm
# Các script upgrade khác phải gọi qua đây
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
POLICY_FILE="$BASE_DIR/config/upgrade-policy.conf"
LOG_FILE="$LOG_DIR/upgrade.log"
SNAPSHOT_SCRIPT="$BASE_DIR/modules/repair/config-snapshot.sh"
LOCK_SCRIPT="$BASE_DIR/modules/upgrade/package-lock.sh"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

# ====================================================
# Load policy
# ====================================================

load_policy(){
    if [ ! -f "$POLICY_FILE" ]; then
        fail "Upgrade policy not found: $POLICY_FILE"
        echo "  Run ShieldPress VPS update to restore policy file."
        return 1
    fi
    source "$POLICY_FILE"
    return 0
}

# ====================================================
# Check version against allowed/blocked patterns
# Returns: 0=allowed, 1=blocked, 2=unknown
# ====================================================

check_version_allowed(){
    local SERVICE="$1"      # nginx, php, mariadb, postgresql, nodejs
    local NEW_VERSION="$2"  # e.g. 1.26.3, 8.4.2

    local ALLOWED_VAR="${SERVICE^^}_ALLOWED"
    local BLOCKED_VAR="${SERVICE^^}_BLOCKED"
    local ALLOWED="${!ALLOWED_VAR}"
    local BLOCKED="${!BLOCKED_VAR}"

    # Check blocked first (takes priority)
    if [ -n "$BLOCKED" ]; then
        for pattern in $BLOCKED; do
            if version_matches "$NEW_VERSION" "$pattern"; then
                return 1
            fi
        done
    fi

    # Check allowed
    if [ -n "$ALLOWED" ]; then
        for pattern in $ALLOWED; do
            if version_matches "$NEW_VERSION" "$pattern"; then
                return 0
            fi
        done
        # Not in allowed list
        return 2
    fi

    # No policy defined = allow by default
    return 0
}

# ====================================================
# Pattern matching: "1.26.3" matches "1.26.*"
# ====================================================

version_matches(){
    local VERSION="$1"
    local PATTERN="$2"

    # Convert pattern to regex: "1.26.*" → "^1\.26\..*$"
    local REGEX=$(echo "$PATTERN" | sed 's/\./\\./g; s/\*/.*/g')
    REGEX="^${REGEX}$"

    echo "$VERSION" | grep -qE "$REGEX"
}

# ====================================================
# Get current installed version
# ====================================================

get_current_version(){
    local SERVICE="$1"

    case "$SERVICE" in
        nginx)
            nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+'
            ;;
        mariadb)
            mysql -V 2>/dev/null | grep -oP '[\d.]+' | head -1
            ;;
        postgresql)
            psql --version 2>/dev/null | grep -oP '[\d.]+' | head -1
            ;;
        nodejs)
            node -v 2>/dev/null | tr -d 'v'
            ;;
        php*)
            local VER="${SERVICE#php}"
            local BIN="/opt/remi/php${VER}/root/usr/bin/php"
            [ -x "$BIN" ] && "$BIN" -v 2>/dev/null | head -1 | awk '{print $2}'
            ;;
    esac
}

# ====================================================
# Get available version from repo
# ====================================================

get_available_version(){
    local SERVICE="$1"

    case "$SERVICE" in
        nginx)
            dnf info nginx 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1
            ;;
        mariadb)
            dnf info mariadb-server 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1
            ;;
        postgresql)
            dnf info postgresql-server 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1
            ;;
        nodejs)
            dnf info nodejs 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1
            ;;
        php*)
            local VER="${SERVICE#php}"
            dnf info "php${VER}-php-fpm" 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1
            ;;
    esac
}

# ====================================================
# Pre-upgrade checks (called before any upgrade)
# Returns 0 if safe to proceed
# ====================================================

pre_upgrade_check(){
    local SERVICE="$1"
    local NEW_VERSION="$2"

    echo ""
    echo -e "${BOLD}Pre-upgrade checks: $SERVICE → $NEW_VERSION${RESET}"
    echo "----------------------------------------------------"

    # 1. Load policy
    load_policy || return 1

    # 2. Check if version is allowed
    check_version_allowed "$SERVICE" "$NEW_VERSION"
    local RESULT=$?

    case $RESULT in
        0)
            ok "Version $NEW_VERSION is ALLOWED by ShieldPress policy"
            ;;
        1)
            echo ""
            fail "Version $NEW_VERSION is BLOCKED by ShieldPress policy"
            local NOTE_VAR="${SERVICE^^}_NOTE"
            local NOTE="${!NOTE_VAR}"
            [ -n "$NOTE" ] && echo -e "  ${DIM}Reason: $NOTE${RESET}"
            echo ""
            echo "  This version has not been tested or is known to cause issues."
            echo "  Wait for a ShieldPress VPS update that approves this version."
            log "BLOCKED upgrade: $SERVICE → $NEW_VERSION (policy)"
            return 1
            ;;
        2)
            echo ""
            warn "Version $NEW_VERSION is NOT in the approved list"
            echo "  Allowed versions: ${!ALLOWED_VAR}"
            echo ""
            read -p "  Override and continue anyway? (yes/no): " override
            if [ "$override" != "yes" ]; then
                log "REJECTED upgrade: $SERVICE → $NEW_VERSION (user declined override)"
                return 1
            fi
            warn "Proceeding with unapproved version (at your own risk)"
            log "OVERRIDE upgrade: $SERVICE → $NEW_VERSION (user approved)"
            ;;
    esac

    # 3. Check disk space
    local FREE_MB=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
    FREE_MB=$((FREE_MB / 1024))
    if [ "$FREE_MB" -lt 500 ]; then
        fail "Not enough disk space (${FREE_MB}MB free, need 500MB minimum)"
        return 1
    fi
    ok "Disk space: ${FREE_MB}MB free"

    # 4. Check services are running
    case "$SERVICE" in
        nginx)
            systemctl is-active --quiet nginx || { fail "Nginx is not running"; return 1; }
            nginx -t 2>/dev/null || { fail "Nginx config has errors, fix before upgrading"; return 1; }
            ok "Nginx running and config valid"
            ;;
        mariadb)
            systemctl is-active --quiet mariadb || { fail "MariaDB is not running"; return 1; }
            ok "MariaDB running"
            ;;
        postgresql)
            systemctl is-active --quiet postgresql || { fail "PostgreSQL is not running"; return 1; }
            ok "PostgreSQL running"
            ;;
    esac

    ok "Pre-upgrade checks passed"
    return 0
}

# ====================================================
# Graceful stop service
# Chờ connection drain trước khi stop hoàn toàn
# ====================================================

GRACEFUL_TIMEOUT=30

graceful_stop_service(){
    local SERVICE="$1"
    local TIMEOUT="${2:-$GRACEFUL_TIMEOUT}"

    echo -e "${BOLD}Graceful stop: $SERVICE (timeout ${TIMEOUT}s)${RESET}"

    case "$SERVICE" in
        nginx)
            # SIGQUIT = finish current requests then exit
            nginx -s quit 2>/dev/null
            local WAITED=0
            while systemctl is-active --quiet nginx && [ "$WAITED" -lt "$TIMEOUT" ]; do
                sleep 1
                ((WAITED++))
            done
            if systemctl is-active --quiet nginx; then
                warn "Graceful timeout, forcing stop..."
                systemctl stop nginx 2>/dev/null
            fi
            ok "Nginx stopped (${WAITED}s)"
            ;;
        mariadb)
            # Check active connections
            local CONN=$(mysqladmin status 2>/dev/null | grep -oP 'Threads: \K[0-9]+')
            [ -n "$CONN" ] && [ "$CONN" -gt 1 ] && warn "Active connections: $CONN — waiting to drain..."

            # mysqladmin shutdown waits for queries to finish
            mysqladmin shutdown --wait=3 2>/dev/null
            local WAITED=0
            while systemctl is-active --quiet mariadb && [ "$WAITED" -lt "$TIMEOUT" ]; do
                sleep 1
                ((WAITED++))
            done
            if systemctl is-active --quiet mariadb; then
                warn "Graceful timeout, forcing stop..."
                systemctl stop mariadb 2>/dev/null
            fi
            ok "MariaDB stopped (${WAITED}s)"
            ;;
        postgresql)
            # smart mode = wait for all clients to disconnect
            local PG_DATA=$(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null | tr -d '[:space:]')
            PG_DATA="${PG_DATA:-/var/lib/pgsql/data}"

            # Check active connections
            local CONN=$(sudo -u postgres psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND pid != pg_backend_pid();" 2>/dev/null | tr -d '[:space:]')
            [ -n "$CONN" ] && [ "$CONN" -gt 0 ] && warn "Active queries: $CONN — waiting to finish..."

            # smart → fast fallback
            sudo -u postgres pg_ctl stop -D "$PG_DATA" -m smart -t "$TIMEOUT" 2>/dev/null
            if systemctl is-active --quiet postgresql; then
                warn "Smart shutdown timeout, using fast mode..."
                sudo -u postgres pg_ctl stop -D "$PG_DATA" -m fast -t 10 2>/dev/null
            fi
            if systemctl is-active --quiet postgresql; then
                systemctl stop postgresql 2>/dev/null
            fi
            ok "PostgreSQL stopped"
            ;;
        php*)
            local VER="${SERVICE#php}"
            local SVC="php${VER}-php-fpm"
            local PID_FILE="/var/opt/remi/php${VER}/run/php-fpm/php-fpm.pid"

            # SIGQUIT = finish current requests then exit
            if [ -f "$PID_FILE" ]; then
                local PID=$(cat "$PID_FILE")
                kill -QUIT "$PID" 2>/dev/null
                local WAITED=0
                while kill -0 "$PID" 2>/dev/null && [ "$WAITED" -lt "$TIMEOUT" ]; do
                    sleep 1
                    ((WAITED++))
                done
                if kill -0 "$PID" 2>/dev/null; then
                    warn "Graceful timeout, forcing stop..."
                    systemctl stop "$SVC" 2>/dev/null
                fi
                ok "$SVC stopped (${WAITED}s)"
            else
                systemctl stop "$SVC" 2>/dev/null
                ok "$SVC stopped"
            fi
            ;;
        *)
            systemctl stop "$SERVICE" 2>/dev/null
            ok "$SERVICE stopped"
            ;;
    esac
}

# ====================================================
# Pre-upgrade actions (snapshot + backup)
# Exports: _ROLLBACK_SNAPSHOT, _ROLLBACK_DUMP
# ====================================================

_ROLLBACK_SNAPSHOT=""
_ROLLBACK_DUMP=""

pre_upgrade_actions(){
    local SERVICE="$1"

    echo ""
    echo -e "${BOLD}Pre-upgrade actions${RESET}"
    echo "----------------------------------------------------"

    # 1. Config snapshot
    echo "Creating config snapshot..."
    if [ -f "$SNAPSHOT_SCRIPT" ]; then
        bash "$SNAPSHOT_SCRIPT" auto "pre-upgrade-${SERVICE}" 2>/dev/null
        # Find the latest snapshot for rollback
        _ROLLBACK_SNAPSHOT=$(ls -1t "$BASE_DIR/snapshots/"*.tar.gz 2>/dev/null | head -1)
        ok "Config snapshot saved"
    else
        warn "Snapshot script not found, skipping"
    fi

    # 2. Database dump (if upgrading database)
    case "$SERVICE" in
        mariadb)
            echo "Dumping all MariaDB databases..."
            local DUMP_DIR="$BASE_DIR/backups/pre-upgrade"
            mkdir -p "$DUMP_DIR"
            local DUMP_FILE="$DUMP_DIR/mariadb-$(date +%Y%m%d_%H%M%S).sql.gz"
            mysqldump --all-databases --single-transaction --routines --triggers 2>/dev/null | gzip > "$DUMP_FILE"
            if [ $? -eq 0 ] && [ -s "$DUMP_FILE" ]; then
                local SIZE=$(du -h "$DUMP_FILE" | awk '{print $1}')
                _ROLLBACK_DUMP="$DUMP_FILE"
                ok "MariaDB dump saved ($SIZE): $DUMP_FILE"
            else
                fail "MariaDB dump failed!"
                rm -f "$DUMP_FILE"
                return 1
            fi
            ;;
        postgresql)
            echo "Dumping all PostgreSQL databases..."
            local DUMP_DIR="$BASE_DIR/backups/pre-upgrade"
            mkdir -p "$DUMP_DIR"
            local DUMP_FILE="$DUMP_DIR/postgresql-$(date +%Y%m%d_%H%M%S).sql.gz"
            sudo -u postgres pg_dumpall 2>/dev/null | gzip > "$DUMP_FILE"
            if [ $? -eq 0 ] && [ -s "$DUMP_FILE" ]; then
                local SIZE=$(du -h "$DUMP_FILE" | awk '{print $1}')
                _ROLLBACK_DUMP="$DUMP_FILE"
                ok "PostgreSQL dump saved ($SIZE): $DUMP_FILE"
            else
                fail "PostgreSQL dump failed!"
                rm -f "$DUMP_FILE"
                return 1
            fi
            ;;
    esac

    return 0
}

# ====================================================
# Auto-rollback: khôi phục config + DB khi upgrade fail
# ====================================================

auto_rollback(){
    local SERVICE="$1"

    echo ""
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    echo -e "${RED}${BOLD}  AUTO-ROLLBACK: $SERVICE${RESET}"
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    log "AUTO-ROLLBACK started for $SERVICE"

    local ROLLBACK_OK=1

    # 1. Restore config snapshot
    if [ -n "$_ROLLBACK_SNAPSHOT" ] && [ -f "$_ROLLBACK_SNAPSHOT" ]; then
        echo ""
        echo "Restoring config snapshot..."
        local SNAP_NAME=$(basename "$_ROLLBACK_SNAPSHOT" .tar.gz)
        local TEMP_DIR=$(mktemp -d)
        tar -xzf "$_ROLLBACK_SNAPSHOT" -C "$TEMP_DIR" 2>/dev/null

        if [ -d "$TEMP_DIR/$SNAP_NAME" ]; then
            local SNAP_ROOT="$TEMP_DIR/$SNAP_NAME"

            # Restore all config files from snapshot
            for item in "$SNAP_ROOT"/*; do
                [ -e "$item" ] || continue
                local REL=$(echo "$item" | sed "s|$SNAP_ROOT/||")
                local DEST="/$REL"
                if [ -d "$item" ]; then
                    [ -d "$DEST" ] || mkdir -p "$DEST"
                    cp -af "$item"/* "$DEST"/ 2>/dev/null
                elif [ -f "$item" ]; then
                    mkdir -p "$(dirname "$DEST")"
                    cp -af "$item" "$DEST" 2>/dev/null
                fi
            done
            ok "Config snapshot restored: $SNAP_NAME"
            log "AUTO-ROLLBACK config restored from $SNAP_NAME"
        else
            fail "Failed to extract snapshot"
            ROLLBACK_OK=0
        fi
        rm -rf "$TEMP_DIR"
    else
        warn "No snapshot available for rollback"
        ROLLBACK_OK=0
    fi

    # 2. Restore database dump (if available)
    if [ -n "$_ROLLBACK_DUMP" ] && [ -f "$_ROLLBACK_DUMP" ]; then
        echo ""
        echo "Restoring database from pre-upgrade dump..."

        case "$SERVICE" in
            mariadb)
                # Start MariaDB first if not running
                systemctl start mariadb 2>/dev/null
                sleep 2
                if systemctl is-active --quiet mariadb; then
                    gunzip < "$_ROLLBACK_DUMP" | mysql 2>/dev/null
                    if [ $? -eq 0 ]; then
                        ok "MariaDB data restored from dump"
                        log "AUTO-ROLLBACK MariaDB data restored"
                    else
                        fail "MariaDB data restore failed!"
                        warn "Manual restore needed: gunzip < $_ROLLBACK_DUMP | mysql"
                        ROLLBACK_OK=0
                    fi
                else
                    fail "Cannot start MariaDB for data restore"
                    ROLLBACK_OK=0
                fi
                ;;
            postgresql)
                systemctl start postgresql 2>/dev/null
                sleep 2
                if systemctl is-active --quiet postgresql; then
                    gunzip < "$_ROLLBACK_DUMP" | sudo -u postgres psql 2>/dev/null
                    if [ $? -eq 0 ]; then
                        ok "PostgreSQL data restored from dump"
                        log "AUTO-ROLLBACK PostgreSQL data restored"
                    else
                        fail "PostgreSQL data restore failed!"
                        warn "Manual restore: gunzip < $_ROLLBACK_DUMP | sudo -u postgres psql"
                        ROLLBACK_OK=0
                    fi
                else
                    fail "Cannot start PostgreSQL for data restore"
                    ROLLBACK_OK=0
                fi
                ;;
        esac
    fi

    # 3. Restart service with restored config
    echo ""
    echo "Restarting $SERVICE with restored config..."
    case "$SERVICE" in
        nginx)
            if nginx -t 2>/dev/null; then
                systemctl start nginx 2>/dev/null && ok "Nginx restarted"
            else
                fail "Nginx config still invalid after rollback!"
                ROLLBACK_OK=0
            fi
            ;;
        mariadb)
            systemctl restart mariadb 2>/dev/null
            if mysqladmin ping 2>/dev/null | grep -q "alive"; then
                ok "MariaDB restarted and responding"
            else
                fail "MariaDB not responding after rollback"
                ROLLBACK_OK=0
            fi
            ;;
        postgresql)
            systemctl restart postgresql 2>/dev/null
            if sudo -u postgres psql -c "SELECT 1;" &>/dev/null; then
                ok "PostgreSQL restarted and responding"
            else
                fail "PostgreSQL not responding after rollback"
                ROLLBACK_OK=0
            fi
            ;;
        php*)
            local VER="${SERVICE#php}"
            local SVC="php${VER}-php-fpm"
            systemctl restart "$SVC" 2>/dev/null
            if systemctl is-active --quiet "$SVC"; then
                ok "$SVC restarted"
            else
                fail "$SVC not running after rollback"
                ROLLBACK_OK=0
            fi
            ;;
    esac

    echo ""
    if [ "$ROLLBACK_OK" -eq 1 ]; then
        ok "Auto-rollback completed successfully"
        log "AUTO-ROLLBACK completed OK for $SERVICE"
    else
        fail "Auto-rollback completed with errors"
        warn "Check logs and manually verify: $LOG_FILE"
        log "AUTO-ROLLBACK completed with ERRORS for $SERVICE"
    fi

    # Notify
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "server_alert" \
            "Upgrade Rollback" "$SERVICE upgrade failed and was rolled back on $(hostname)" 2>/dev/null
    fi

    return 0
}

# ====================================================
# Post-upgrade validation
# ====================================================

post_upgrade_validate(){
    local SERVICE="$1"
    local OLD_VERSION="$2"

    echo ""
    echo -e "${BOLD}Post-upgrade validation${RESET}"
    echo "----------------------------------------------------"

    local NEW_VERSION=$(get_current_version "$SERVICE")
    local ALL_OK=1

    case "$SERVICE" in
        nginx)
            if nginx -t 2>/dev/null; then
                ok "Nginx config test passed"
            else
                fail "Nginx config test FAILED"
                ALL_OK=0
            fi
            if systemctl is-active --quiet nginx; then
                ok "Nginx service running"
            else
                fail "Nginx service not running"
                ALL_OK=0
            fi
            ;;
        mariadb)
            if systemctl is-active --quiet mariadb; then
                ok "MariaDB service running"
            else
                fail "MariaDB service not running"
                ALL_OK=0
            fi
            if mysqladmin ping 2>/dev/null | grep -q "alive"; then
                ok "MariaDB responding to queries"
            else
                fail "MariaDB not responding"
                ALL_OK=0
            fi
            ;;
        postgresql)
            if systemctl is-active --quiet postgresql; then
                ok "PostgreSQL service running"
            else
                fail "PostgreSQL service not running"
                ALL_OK=0
            fi
            if sudo -u postgres psql -c "SELECT 1;" &>/dev/null; then
                ok "PostgreSQL responding to queries"
            else
                fail "PostgreSQL not responding"
                ALL_OK=0
            fi
            ;;
        nodejs)
            if command -v node &>/dev/null; then
                ok "Node.js binary available"
            else
                fail "Node.js binary not found"
                ALL_OK=0
            fi
            ;;
        php*)
            local VER="${SERVICE#php}"
            local SVC="php${VER}-php-fpm"
            local FPM="/opt/remi/php${VER}/root/usr/sbin/php-fpm"
            if [ -x "$FPM" ] && $FPM -t 2>/dev/null; then
                ok "PHP ${VER:0:1}.${VER:1} FPM config valid"
            else
                fail "PHP ${VER:0:1}.${VER:1} FPM config FAILED"
                ALL_OK=0
            fi
            if systemctl is-active --quiet "$SVC"; then
                ok "PHP ${VER:0:1}.${VER:1} FPM running"
            else
                fail "PHP ${VER:0:1}.${VER:1} FPM not running"
                ALL_OK=0
            fi
            ;;
    esac

    echo ""
    echo "  Version: $OLD_VERSION → $NEW_VERSION"

    if [ "$ALL_OK" -eq 1 ]; then
        ok "Upgrade validated successfully"
        log "UPGRADE OK: $SERVICE $OLD_VERSION → $NEW_VERSION"

        # Notify
        if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
            bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "info" \
                "Upgrade Complete" "$SERVICE upgraded: $OLD_VERSION → $NEW_VERSION on $(hostname)" 2>/dev/null
        fi
        return 0
    else
        fail "Upgrade validation FAILED"
        log "UPGRADE FAILED validation: $SERVICE $OLD_VERSION → $NEW_VERSION"

        if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
            bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "server_alert" \
                "Upgrade Failed" "$SERVICE upgrade failed validation: $OLD_VERSION → $NEW_VERSION on $(hostname)" 2>/dev/null
        fi
        return 1
    fi
}

# ====================================================
# Lock package after upgrade
# ====================================================

post_upgrade_lock(){
    local SERVICE="$1"

    if [ -f "$LOCK_SCRIPT" ]; then
        bash "$LOCK_SCRIPT" lock "$SERVICE" 2>/dev/null
    fi
}

# ====================================================
# Full upgrade flow (called by individual upgrade scripts)
# Usage: upgrade_service SERVICE NEW_VERSION UPGRADE_CMD
# ====================================================

upgrade_service(){
    local SERVICE="$1"
    local NEW_VERSION="$2"
    local UPGRADE_CMD="$3"

    local OLD_VERSION=$(get_current_version "$SERVICE")

    # Reset rollback state
    _ROLLBACK_SNAPSHOT=""
    _ROLLBACK_DUMP=""

    echo ""
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "${BOLD}  UPGRADING: $SERVICE${RESET}"
    echo -e "${BOLD}  $OLD_VERSION → $NEW_VERSION${RESET}"
    echo -e "${BOLD}=====================================================${RESET}"

    # Step 1: Pre-checks
    pre_upgrade_check "$SERVICE" "$NEW_VERSION" || return 1

    # Step 2: Confirm
    echo ""
    echo -e "${YELLOW}${BOLD}Confirm upgrade:${RESET}"
    echo "  Service : $SERVICE"
    echo "  Current : $OLD_VERSION"
    echo "  Target  : $NEW_VERSION"
    echo ""
    read -p "Proceed? (yes/no): " confirm
    [ "$confirm" = "yes" ] || { warn "Cancelled"; return 1; }

    # Step 3: Pre-actions (snapshot + backup)
    pre_upgrade_actions "$SERVICE" || return 1

    # Step 4: Unlock package
    echo ""
    echo -e "${BOLD}Unlocking package...${RESET}"
    if [ -f "$LOCK_SCRIPT" ]; then
        bash "$LOCK_SCRIPT" unlock "$SERVICE" 2>/dev/null
    fi

    # Step 5: Execute upgrade
    echo ""
    echo -e "${BOLD}Executing upgrade...${RESET}"
    echo "----------------------------------------------------"
    log "UPGRADING $SERVICE: $OLD_VERSION → $NEW_VERSION"

    eval "$UPGRADE_CMD"
    local UPGRADE_EXIT=$?

    # Step 6: Re-lock package
    echo ""
    echo -e "${BOLD}Re-locking package...${RESET}"
    post_upgrade_lock "$SERVICE"

    # Step 7: Validate → auto-rollback on failure
    if [ $UPGRADE_EXIT -eq 0 ]; then
        post_upgrade_validate "$SERVICE" "$OLD_VERSION"
        if [ $? -ne 0 ]; then
            fail "Post-upgrade validation FAILED"
            echo ""
            echo -e "${YELLOW}${BOLD}Auto-rollback will attempt to restore the previous state.${RESET}"
            read -p "Rollback now? (yes/no) [yes]: " rollback_confirm
            rollback_confirm="${rollback_confirm:-yes}"
            if [ "$rollback_confirm" = "yes" ]; then
                auto_rollback "$SERVICE"
            else
                warn "Rollback skipped. Manual restore available:"
                [ -n "$_ROLLBACK_SNAPSHOT" ] && echo "  Snapshot: $_ROLLBACK_SNAPSHOT"
                [ -n "$_ROLLBACK_DUMP" ] && echo "  DB dump : $_ROLLBACK_DUMP"
            fi
            return 1
        fi
        return 0
    else
        fail "Upgrade command failed (exit code: $UPGRADE_EXIT)"
        log "UPGRADE COMMAND FAILED: $SERVICE (exit: $UPGRADE_EXIT)"

        echo ""
        echo -e "${YELLOW}${BOLD}Upgrade command failed. Auto-rollback will restore the previous state.${RESET}"
        read -p "Rollback now? (yes/no) [yes]: " rollback_confirm
        rollback_confirm="${rollback_confirm:-yes}"
        if [ "$rollback_confirm" = "yes" ]; then
            auto_rollback "$SERVICE"
        else
            warn "Rollback skipped. Manual restore available:"
            [ -n "$_ROLLBACK_SNAPSHOT" ] && echo "  Snapshot: $_ROLLBACK_SNAPSHOT"
            [ -n "$_ROLLBACK_DUMP" ] && echo "  DB dump : $_ROLLBACK_DUMP"
        fi
        return 1
    fi
}
