#!/bin/bash
# ====================================================
# ShieldPress Package Lock Manager
# Quản lý dnf versionlock để ngăn upgrade ngoài kiểm soát
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/upgrade.log"

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

# Package groups for each service
declare -A SERVICE_PACKAGES
SERVICE_PACKAGES=(
    [nginx]="nginx nginx-core nginx-mod-*"
    [php]="php81-* php82-* php83-* php84-*"
    [mariadb]="mariadb-server mariadb mariadb-common mariadb-backup mariadb-gssapi-server"
    [postgresql]="postgresql-server postgresql postgresql-contrib postgresql-libs"
    [nodejs]="nodejs nodejs-libs npm"
)

# ====================================================
# Ensure versionlock plugin is installed
# ====================================================

ensure_versionlock(){
    if ! dnf versionlock list &>/dev/null; then
        echo "Installing dnf versionlock plugin..."
        dnf install -y 'dnf-command(versionlock)' 2>/dev/null || \
        dnf install -y python3-dnf-plugin-versionlock 2>/dev/null || {
            fail "Cannot install versionlock plugin"
            return 1
        }
        ok "versionlock plugin installed"
    fi
    return 0
}

# ====================================================
# Lock a service's packages
# ====================================================

lock_service(){
    local SERVICE="$1"
    local PACKAGES="${SERVICE_PACKAGES[$SERVICE]}"

    if [ -z "$PACKAGES" ]; then
        fail "Unknown service: $SERVICE"
        return 1
    fi

    ensure_versionlock || return 1

    echo "Locking $SERVICE packages..."

    for pkg in $PACKAGES; do
        # Check if already locked
        if dnf versionlock list 2>/dev/null | grep -q "$pkg"; then
            echo -e "  ${DIM}$pkg already locked${RESET}"
            continue
        fi

        # Only lock if package is actually installed
        if rpm -q "$pkg" &>/dev/null 2>&1 || rpm -qa "$pkg" 2>/dev/null | grep -q .; then
            dnf versionlock add "$pkg" 2>/dev/null && \
                echo -e "  ${GREEN}✓${RESET} $pkg locked" || \
                echo -e "  ${YELLOW}!${RESET} $pkg lock failed"
        fi
    done

    log "LOCKED packages: $SERVICE"
    return 0
}

# ====================================================
# Unlock a service's packages (temporary, for upgrade)
# ====================================================

unlock_service(){
    local SERVICE="$1"
    local PACKAGES="${SERVICE_PACKAGES[$SERVICE]}"

    if [ -z "$PACKAGES" ]; then
        fail "Unknown service: $SERVICE"
        return 1
    fi

    ensure_versionlock || return 1

    echo "Unlocking $SERVICE packages..."

    for pkg in $PACKAGES; do
        dnf versionlock delete "$pkg" 2>/dev/null
    done

    ok "$SERVICE packages unlocked"
    log "UNLOCKED packages: $SERVICE"
    return 0
}

# ====================================================
# Lock ALL services
# ====================================================

lock_all(){
    echo ""
    echo -e "${BOLD}Locking all critical packages...${RESET}"
    echo "===================================================="

    ensure_versionlock || return 1

    for service in nginx php mariadb postgresql nodejs; do
        echo ""
        echo -e "${BOLD}$service:${RESET}"
        lock_service "$service"
    done

    echo ""
    ok "All critical packages locked"
    log "LOCKED ALL packages"
}

# ====================================================
# Unlock ALL (dangerous - for maintenance)
# ====================================================

unlock_all(){
    echo ""
    warn "This will unlock ALL packages, allowing uncontrolled upgrades!"
    read -p "Are you sure? (yes/no): " confirm
    [ "$confirm" = "yes" ] || { warn "Cancelled"; return; }

    ensure_versionlock || return 1

    dnf versionlock clear 2>/dev/null
    ok "All version locks cleared"
    warn "Remember to re-lock after maintenance!"
    log "UNLOCKED ALL packages (manual)"
}

# ====================================================
# Show lock status
# ====================================================

show_status(){
    echo ""
    echo -e "${BOLD}Package Lock Status${RESET}"
    echo "===================================================="

    ensure_versionlock || return

    # Check if versionlock has entries
    local LOCKED_LIST=$(dnf versionlock list 2>/dev/null)
    local LOCK_COUNT=$(echo "$LOCKED_LIST" | grep -c "." 2>/dev/null)

    if [ "$LOCK_COUNT" -le 1 ]; then
        echo ""
        warn "No packages are locked!"
        echo "  Run 'Lock All Packages' to protect your system."
        echo ""
        return
    fi

    for service in nginx php mariadb postgresql nodejs; do
        local PACKAGES="${SERVICE_PACKAGES[$service]}"
        local CURRENT=$(get_current_version_display "$service")
        local LOCKED=0

        for pkg in $PACKAGES; do
            echo "$LOCKED_LIST" | grep -q "$pkg" && LOCKED=1 && break
        done

        if [ "$LOCKED" -eq 1 ]; then
            echo -e "  ${GREEN}🔒${RESET} %-14s ${GREEN}LOCKED${RESET}  ($CURRENT)" "$service"
        else
            echo -e "  ${RED}🔓${RESET} %-14s ${RED}UNLOCKED${RESET}  ($CURRENT)" "$service"
        fi
    done

    echo ""
    echo "----------------------------------------------------"
    echo -e "  Total locks: $LOCK_COUNT"
    echo ""
    echo -e "  ${DIM}Locked packages cannot be upgraded via 'dnf update'.${RESET}"
    echo -e "  ${DIM}Use ShieldPress Upgrade Manager for controlled upgrades.${RESET}"
}

get_current_version_display(){
    local SERVICE="$1"
    case "$SERVICE" in
        nginx) nginx -v 2>&1 | grep -oP 'nginx/\K[\d.]+' ;;
        php) echo "$(for v in 81 82 83 84; do [ -x "/opt/remi/php${v}/root/usr/bin/php" ] && echo -n "${v:0:1}.${v:1} "; done)" ;;
        mariadb) mysql -V 2>/dev/null | grep -oP '[\d.]+' | head -1 ;;
        postgresql) psql --version 2>/dev/null | grep -oP '[\d.]+' | head -1 ;;
        nodejs) node -v 2>/dev/null | tr -d 'v' ;;
    esac
}

# ====================================================
# DNF update protection hook
# Create a dnf plugin that warns when updating locked packages
# ====================================================

install_update_guard(){
    echo ""
    echo -e "${BOLD}Installing DNF Update Guard...${RESET}"
    echo "----------------------------------------------------"

    local GUARD_SCRIPT="$BASE_DIR/bin/shieldpress-update-guard"

    cat > "$GUARD_SCRIPT" <<'GUARD_EOF'
#!/bin/bash
# ShieldPress DNF Update Guard
# Cảnh báo khi user chạy dnf update trực tiếp

PROTECTED="nginx mariadb-server postgresql-server nodejs php81 php82 php83 php84"

for pkg in $PROTECTED; do
    for arg in "$@"; do
        if echo "$arg" | grep -qi "$pkg"; then
            echo ""
            echo "=============================================="
            echo "  ShieldPress: PROTECTED PACKAGE DETECTED"
            echo "=============================================="
            echo "  Package '$pkg' is managed by ShieldPress."
            echo "  Use: shieldpress → Upgrade Manager"
            echo "=============================================="
            echo ""
            exit 1
        fi
    done
done
GUARD_EOF

    chmod +x "$GUARD_SCRIPT"

    # Add alias to prevent direct dnf update of protected packages
    local PROFILE_FILE="/etc/profile.d/shieldpress-guard.sh"
    cat > "$PROFILE_FILE" <<'PROFILE_EOF'
# ShieldPress: Warn on dangerous dnf operations
shieldpress_dnf_guard(){
    if [ "$1" = "update" ] || [ "$1" = "upgrade" ]; then
        echo ""
        echo -e "\e[33m[ShieldPress]\e[0m Critical packages (nginx, php, mariadb, postgresql, nodejs) are locked."
        echo -e "\e[33m[ShieldPress]\e[0m Use 'shieldpress' → Upgrade Manager for controlled upgrades."
        echo -e "\e[33m[ShieldPress]\e[0m OS packages will still update normally."
        echo ""
    fi
    command dnf "$@"
}
alias dnf='shieldpress_dnf_guard'
PROFILE_EOF

    ok "Update guard installed"
    echo "  Users will see a warning when running 'dnf update'"
    log "UPDATE GUARD installed"
}

# ====================================================
# Entry point (called from other scripts)
# ====================================================

case "$1" in
    lock)
        [ -n "$2" ] && lock_service "$2" || lock_all
        exit $?
        ;;
    unlock)
        [ -n "$2" ] && unlock_service "$2" || unlock_all
        exit $?
        ;;
    status)
        show_status
        exit 0
        ;;
esac

# ====================================================
# Interactive menu
# ====================================================

while true; do
    clear
    echo "===================================================="
    echo "          PACKAGE LOCK MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Show Lock Status"
    echo "  2) Lock All Packages"
    echo "  3) Unlock All Packages"
    echo "  4) Lock Specific Service"
    echo "  5) Unlock Specific Service"
    echo "  6) Install Update Guard"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) lock_all ;;
        3) unlock_all ;;
        4)
            echo ""
            echo "Services: nginx, php, mariadb, postgresql, nodejs"
            read -p "Lock which service: " svc
            lock_service "$svc"
            ;;
        5)
            echo ""
            echo "Services: nginx, php, mariadb, postgresql, nodejs"
            read -p "Unlock which service: " svc
            unlock_service "$svc"
            ;;
        6) install_update_guard ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
