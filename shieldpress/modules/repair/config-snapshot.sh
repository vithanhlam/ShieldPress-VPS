#!/bin/bash
# ====================================================
# ShieldPress Config Snapshot & Restore
# Chụp ảnh toàn bộ config quan trọng, khôi phục khi cần
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
SNAPSHOT_DIR="$BASE_DIR/snapshots"
MAX_SNAPSHOTS=10
LOG_FILE="$LOG_DIR/snapshot.log"

mkdir -p "$SNAPSHOT_DIR" "$LOG_DIR"

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
# Danh sách file/thư mục cần snapshot
# ====================================================

SNAPSHOT_TARGETS=(
    # Nginx
    "/etc/nginx/nginx.conf"
    "/etc/nginx/conf.d/"
    "/etc/nginx/snippets/"
    # PHP-FPM (all versions)
    "/etc/opt/remi/php81/php-fpm.d/"
    "/etc/opt/remi/php81/php-fpm.conf"
    "/etc/opt/remi/php81/php.ini"
    "/etc/opt/remi/php81/php.d/"
    "/etc/opt/remi/php82/php-fpm.d/"
    "/etc/opt/remi/php82/php-fpm.conf"
    "/etc/opt/remi/php82/php.ini"
    "/etc/opt/remi/php82/php.d/"
    "/etc/opt/remi/php83/php-fpm.d/"
    "/etc/opt/remi/php83/php-fpm.conf"
    "/etc/opt/remi/php83/php.ini"
    "/etc/opt/remi/php83/php.d/"
    "/etc/opt/remi/php84/php-fpm.d/"
    "/etc/opt/remi/php84/php-fpm.conf"
    "/etc/opt/remi/php84/php.ini"
    "/etc/opt/remi/php84/php.d/"
    # Database
    "/etc/my.cnf"
    "/etc/my.cnf.d/"
    # Valkey/Redis
    "/etc/valkey/"
    # SSL
    "/etc/nginx/ssl/"
    # System tuning
    "/etc/sysctl.d/shieldpress.conf"
    "/etc/security/limits.d/shieldpress.conf"
    # SSH
    "/etc/ssh/sshd_config"
    # Firewall
    "/etc/firewalld/"
    # ShieldPress internal
    "$BASE_DIR/config/"
    # Domain configs
    "/home/domains/*/config/domain.env"
)

# ====================================================
# Tạo snapshot
# ====================================================

create_snapshot(){
    local LABEL="${1:-manual}"
    local TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    local SNAP_NAME="${TIMESTAMP}_${LABEL}"
    local SNAP_PATH="$SNAPSHOT_DIR/$SNAP_NAME"

    echo ""
    echo -e "${BOLD}Creating config snapshot: $SNAP_NAME${RESET}"
    echo "----------------------------------------------------"

    mkdir -p "$SNAP_PATH"

    local COUNT=0
    local ERRORS=0

    for target in "${SNAPSHOT_TARGETS[@]}"; do
        # Expand glob patterns
        local expanded=()
        eval "expanded=($target)" 2>/dev/null

        for item in "${expanded[@]}"; do
            [ -e "$item" ] || continue

            # Create parent directory structure in snapshot
            local REL_PATH="${item#/}"
            local DEST="$SNAP_PATH/$REL_PATH"
            mkdir -p "$(dirname "$DEST")"

            if [ -d "$item" ]; then
                cp -a "$item" "$DEST" 2>/dev/null && ((COUNT++)) || ((ERRORS++))
            elif [ -f "$item" ]; then
                cp -a "$item" "$DEST" 2>/dev/null && ((COUNT++)) || ((ERRORS++))
            fi
        done
    done

    # Save metadata
    cat > "$SNAP_PATH/.snapshot-meta" <<EOF
TIMESTAMP=$TIMESTAMP
LABEL=$LABEL
CREATED=$(date '+%F %T')
HOSTNAME=$(hostname 2>/dev/null)
FILES_COUNT=$COUNT
ERRORS=$ERRORS
NGINX_VERSION=$(nginx -v 2>&1 | grep -o 'nginx/[^ ]*')
PHP_VERSIONS=$(for v in 81 82 83 84; do [ -x "/opt/remi/php${v}/root/usr/bin/php" ] && echo -n "${v:0:1}.${v:1} "; done)
EOF

    # Generate checksums for critical files
    find "$SNAP_PATH" -type f ! -name ".snapshot-meta" ! -name ".checksums" -exec md5sum {} \; > "$SNAP_PATH/.checksums" 2>/dev/null

    # Compress snapshot
    cd "$SNAPSHOT_DIR" || return
    tar -czf "${SNAP_NAME}.tar.gz" "$SNAP_NAME" 2>/dev/null
    rm -rf "$SNAP_PATH"

    local SIZE=$(du -h "${SNAP_NAME}.tar.gz" 2>/dev/null | awk '{print $1}')

    ok "Snapshot created: $SNAP_NAME ($COUNT files, $SIZE)"
    [ "$ERRORS" -gt 0 ] && warn "$ERRORS files failed to copy"

    log "SNAPSHOT created: $SNAP_NAME ($COUNT files, $ERRORS errors)"

    # Prune old snapshots
    prune_snapshots

    return 0
}

# ====================================================
# Liệt kê snapshots
# ====================================================

list_snapshots(){
    echo ""
    echo -e "${BOLD}Available Snapshots${RESET}"
    echo "===================================================="

    local SNAPS=()
    local IDX=1

    for snap in "$SNAPSHOT_DIR"/*.tar.gz; do
        [ -f "$snap" ] || continue
        local NAME=$(basename "$snap" .tar.gz)
        local SIZE=$(du -h "$snap" 2>/dev/null | awk '{print $1}')
        local DATE=$(echo "$NAME" | cut -d_ -f1-2 | sed 's/_/ /')
        local LABEL=$(echo "$NAME" | cut -d_ -f3-)

        # Format date for display
        local YEAR=${DATE:0:4}
        local MONTH=${DATE:4:2}
        local DAY=${DATE:6:2}
        local HOUR=${DATE:9:2}
        local MIN=${DATE:11:2}

        printf "  %b %-3s %s-%s-%s %s:%s  %-20s %s\n" \
            "${CYAN}●${RESET}" "${IDX})" "$YEAR" "$MONTH" "$DAY" "$HOUR" "$MIN" "$LABEL" "${DIM}($SIZE)${RESET}"

        SNAPS+=("$snap")
        ((IDX++))
    done

    if [ ${#SNAPS[@]} -eq 0 ]; then
        warn "No snapshots found"
        echo "  Run 'Create Snapshot' to save current config state"
        return 1
    fi

    echo "===================================================="
    echo "  Total: ${#SNAPS[@]} snapshot(s)"

    # Export for other functions
    SNAPSHOT_LIST=("${SNAPS[@]}")
    return 0
}

# ====================================================
# Khôi phục snapshot
# ====================================================

restore_snapshot(){
    list_snapshots || return

    echo ""
    echo "  0) Cancel"
    echo ""
    read -p "Select snapshot to restore: " CHOICE

    [ "$CHOICE" = "0" ] && return
    [[ "$CHOICE" =~ ^[0-9]+$ ]] || { fail "Invalid"; return; }

    local IDX=$((CHOICE - 1))
    [ "$IDX" -lt 0 ] || [ "$IDX" -ge ${#SNAPSHOT_LIST[@]} ] && { fail "Out of range"; return; }

    local SNAP_FILE="${SNAPSHOT_LIST[$IDX]}"
    local SNAP_NAME=$(basename "$SNAP_FILE" .tar.gz)

    echo ""
    warn "This will OVERWRITE current configs with snapshot: $SNAP_NAME"
    echo ""
    echo "What to restore:"
    echo "  1) Everything (Nginx + PHP + DB + SSL + System)"
    echo "  2) Nginx only"
    echo "  3) PHP only"
    echo "  4) Database config only"
    echo "  5) ShieldPress config only"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " RESTORE_SCOPE

    [ "$RESTORE_SCOPE" = "0" ] && return

    # Safety: create a snapshot of current state first
    echo ""
    echo "Creating safety snapshot of current state..."
    create_snapshot "pre-restore"

    # Extract snapshot to temp
    local TEMP_DIR=$(mktemp -d)
    tar -xzf "$SNAP_FILE" -C "$TEMP_DIR" 2>/dev/null || { fail "Failed to extract snapshot"; rm -rf "$TEMP_DIR"; return; }

    local SNAP_ROOT="$TEMP_DIR/$SNAP_NAME"

    echo ""
    echo "Restoring files..."

    local RESTORED=0
    local FAILED=0

    restore_path(){
        local SRC="$1"
        local DEST="/$2"

        if [ -d "$SRC" ]; then
            # Directory: copy contents
            if [ -d "$DEST" ]; then
                cp -af "$SRC"/* "$DEST"/ 2>/dev/null && ((RESTORED++)) || ((FAILED++))
            else
                mkdir -p "$DEST"
                cp -af "$SRC"/* "$DEST"/ 2>/dev/null && ((RESTORED++)) || ((FAILED++))
            fi
        elif [ -f "$SRC" ]; then
            mkdir -p "$(dirname "$DEST")"
            cp -af "$SRC" "$DEST" 2>/dev/null && ((RESTORED++)) || ((FAILED++))
        fi
    }

    case "$RESTORE_SCOPE" in
        1) # Everything
            for item in "$SNAP_ROOT"/*; do
                [ -e "$item" ] || continue
                local REL=$(echo "$item" | sed "s|$SNAP_ROOT/||")
                restore_path "$item" "$REL"
            done
            ;;
        2) # Nginx only
            [ -d "$SNAP_ROOT/etc/nginx" ] && restore_path "$SNAP_ROOT/etc/nginx" "etc/nginx"
            ;;
        3) # PHP only
            for v in 81 82 83 84; do
                [ -d "$SNAP_ROOT/etc/opt/remi/php${v}" ] && \
                    restore_path "$SNAP_ROOT/etc/opt/remi/php${v}" "etc/opt/remi/php${v}"
            done
            ;;
        4) # Database
            [ -f "$SNAP_ROOT/etc/my.cnf" ] && restore_path "$SNAP_ROOT/etc/my.cnf" "etc/my.cnf"
            [ -d "$SNAP_ROOT/etc/my.cnf.d" ] && restore_path "$SNAP_ROOT/etc/my.cnf.d" "etc/my.cnf.d"
            [ -d "$SNAP_ROOT/etc/valkey" ] && restore_path "$SNAP_ROOT/etc/valkey" "etc/valkey"
            ;;
        5) # ShieldPress
            [ -d "$SNAP_ROOT/opt/shieldpress/config" ] && \
                restore_path "$SNAP_ROOT/opt/shieldpress/config" "opt/shieldpress/config"
            ;;
        *) fail "Invalid scope"; rm -rf "$TEMP_DIR"; return ;;
    esac

    rm -rf "$TEMP_DIR"

    echo ""
    ok "Restored $RESTORED item(s)"
    [ "$FAILED" -gt 0 ] && warn "$FAILED item(s) failed"

    # Validate and restart services
    echo ""
    echo "Validating configs..."

    case "$RESTORE_SCOPE" in
        1|2)
            if nginx -t 2>&1; then
                systemctl reload nginx && ok "Nginx reloaded"
            else
                fail "Nginx config invalid after restore!"
                warn "Run 'Restore Snapshot' again with the pre-restore snapshot to undo"
            fi
            ;;&
        1|3)
            for v in 81 82 83 84; do
                SVC="php${v}-php-fpm"
                systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
                systemctl restart "$SVC" 2>/dev/null && ok "$SVC restarted" || warn "$SVC restart failed"
            done
            ;;&
        1|4)
            systemctl restart mariadb 2>/dev/null && ok "MariaDB restarted" || warn "MariaDB restart failed"
            systemctl restart valkey 2>/dev/null && ok "Valkey restarted" || warn "Valkey not running"
            ;;
    esac

    log "RESTORE completed from $SNAP_NAME (scope=$RESTORE_SCOPE, restored=$RESTORED, failed=$FAILED)"

    # Notify
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "security_alert" \
            "Config Restored" "Snapshot $SNAP_NAME restored (scope=$RESTORE_SCOPE)" 2>/dev/null
    fi
}

# ====================================================
# Xóa snapshot cũ (giữ MAX_SNAPSHOTS mới nhất)
# ====================================================

prune_snapshots(){
    local SNAPS=($(ls -1t "$SNAPSHOT_DIR"/*.tar.gz 2>/dev/null))
    local COUNT=${#SNAPS[@]}

    if [ "$COUNT" -gt "$MAX_SNAPSHOTS" ]; then
        local TO_DELETE=$((COUNT - MAX_SNAPSHOTS))
        for ((i=MAX_SNAPSHOTS; i<COUNT; i++)); do
            rm -f "${SNAPS[$i]}"
            log "PRUNED old snapshot: $(basename "${SNAPS[$i]}")"
        done
        echo -e "  ${DIM}Pruned $TO_DELETE old snapshot(s), keeping $MAX_SNAPSHOTS${RESET}"
    fi
}

# ====================================================
# So sánh snapshot với trạng thái hiện tại
# ====================================================

compare_snapshot(){
    list_snapshots || return

    echo ""
    echo "  0) Cancel"
    echo ""
    read -p "Select snapshot to compare: " CHOICE

    [ "$CHOICE" = "0" ] && return
    [[ "$CHOICE" =~ ^[0-9]+$ ]] || { fail "Invalid"; return; }

    local IDX=$((CHOICE - 1))
    [ "$IDX" -lt 0 ] || [ "$IDX" -ge ${#SNAPSHOT_LIST[@]} ] && { fail "Out of range"; return; }

    local SNAP_FILE="${SNAPSHOT_LIST[$IDX]}"
    local SNAP_NAME=$(basename "$SNAP_FILE" .tar.gz)

    echo ""
    echo -e "${BOLD}Comparing snapshot $SNAP_NAME with current state${RESET}"
    echo "===================================================="

    local TEMP_DIR=$(mktemp -d)
    tar -xzf "$SNAP_FILE" -C "$TEMP_DIR" 2>/dev/null || { fail "Failed to extract"; rm -rf "$TEMP_DIR"; return; }

    local SNAP_ROOT="$TEMP_DIR/$SNAP_NAME"
    local CHANGED=0
    local MISSING=0
    local NEW=0

    # Compare files
    while IFS= read -r line; do
        local SNAP_MD5=$(echo "$line" | awk '{print $1}')
        local SNAP_FILE_PATH=$(echo "$line" | awk '{print $2}')
        local REL_PATH=$(echo "$SNAP_FILE_PATH" | sed "s|$SNAP_ROOT/||")
        local REAL_PATH="/$REL_PATH"

        # Skip metadata files
        [[ "$REL_PATH" == .snapshot-meta ]] && continue
        [[ "$REL_PATH" == .checksums ]] && continue

        if [ ! -f "$REAL_PATH" ]; then
            echo -e "  ${RED}MISSING${RESET}  $REAL_PATH"
            ((MISSING++))
        else
            local CURRENT_MD5=$(md5sum "$REAL_PATH" 2>/dev/null | awk '{print $1}')
            if [ "$SNAP_MD5" != "$CURRENT_MD5" ]; then
                echo -e "  ${YELLOW}CHANGED${RESET}  $REAL_PATH"
                ((CHANGED++))
            fi
        fi
    done < "$SNAP_ROOT/.checksums"

    rm -rf "$TEMP_DIR"

    echo ""
    echo "===================================================="
    echo "  Changed : $CHANGED file(s)"
    echo "  Missing : $MISSING file(s)"
    echo "===================================================="

    if [ "$MISSING" -gt 0 ]; then
        echo ""
        warn "Missing files detected! Consider restoring from this snapshot."
    fi
}

# ====================================================
# Delete a specific snapshot
# ====================================================

delete_snapshot(){
    list_snapshots || return

    echo ""
    echo "  A) Delete ALL snapshots"
    echo "  0) Cancel"
    echo ""
    read -p "Select snapshot to delete: " CHOICE

    [ "$CHOICE" = "0" ] && return

    if [[ "$CHOICE" =~ ^[aA]$ ]]; then
        read -p "Delete ALL snapshots? (y/n): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || return
        rm -f "$SNAPSHOT_DIR"/*.tar.gz
        ok "All snapshots deleted"
        log "ALL snapshots deleted"
        return
    fi

    [[ "$CHOICE" =~ ^[0-9]+$ ]] || { fail "Invalid"; return; }
    local IDX=$((CHOICE - 1))
    [ "$IDX" -lt 0 ] || [ "$IDX" -ge ${#SNAPSHOT_LIST[@]} ] && { fail "Out of range"; return; }

    local SNAP_FILE="${SNAPSHOT_LIST[$IDX]}"
    rm -f "$SNAP_FILE"
    ok "Deleted: $(basename "$SNAP_FILE")"
    log "DELETED snapshot: $(basename "$SNAP_FILE")"
}

# ====================================================
# Entry point: can be called from other scripts
# ====================================================

# If called with argument "auto" → create snapshot silently
if [ "$1" = "auto" ]; then
    create_snapshot "${2:-auto}" > /dev/null 2>&1
    exit $?
fi

# Interactive menu
while true; do
    clear
    echo "===================================================="
    echo "          CONFIG SNAPSHOT MANAGER"
    echo "===================================================="

    # Show snapshot count
    SNAP_COUNT=$(ls "$SNAPSHOT_DIR"/*.tar.gz 2>/dev/null | wc -l)
    SNAP_SIZE=$(du -sh "$SNAPSHOT_DIR" 2>/dev/null | awk '{print $1}')
    echo -e "  Snapshots: ${CYAN}$SNAP_COUNT${RESET} (${SNAP_SIZE:-0})"
    echo ""

    echo "  1) Create Snapshot Now"
    echo "  2) List Snapshots"
    echo "  3) Restore from Snapshot"
    echo "  4) Compare with Current State"
    echo "  5) Delete Snapshot"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1)
            read -p "Label (optional, e.g. before-update): " LABEL
            create_snapshot "${LABEL:-manual}"
            ;;
        2) list_snapshots ;;
        3) restore_snapshot ;;
        4) compare_snapshot ;;
        5) delete_snapshot ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
