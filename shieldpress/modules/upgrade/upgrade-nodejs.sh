#!/bin/bash
# ====================================================
# ShieldPress Controlled Node.js Upgrade
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/modules/upgrade/upgrade-gate.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

DOMAINS_ROOT="/home/domains"

check_upgrade(){
    local CURRENT=$(get_current_version "nodejs")
    local AVAILABLE=$(get_available_version "nodejs")
    local NPM_VER=$(npm -v 2>/dev/null)

    echo ""
    echo "===================================================="
    echo "           NODE.JS UPGRADE CHECK"
    echo "===================================================="
    echo ""
    echo "  Node.js current  : ${CURRENT:-Not installed}"
    echo "  Node.js available: ${AVAILABLE:-Unable to check}"
    echo "  npm version      : ${NPM_VER:-N/A}"
    echo ""

    if [ -z "$CURRENT" ]; then
        warn "Node.js not detected"
        return 1
    fi

    if [ -z "$AVAILABLE" ]; then
        warn "Cannot check available version"
        return 1
    fi

    local CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
    local AVA_MAJOR=$(echo "$AVAILABLE" | cut -d. -f1)

    if [ "$CUR_MAJOR" != "$AVA_MAJOR" ]; then
        warn "MAJOR VERSION CHANGE: $CUR_MAJOR → $AVA_MAJOR"
        echo "  Major Node.js upgrades may break existing applications."
        echo "  Check app compatibility before upgrading."
    fi

    if [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "Already running the latest available version"
    fi

    # Check policy
    load_policy
    check_version_allowed "nodejs" "$AVAILABLE"
    case $? in
        0) echo -e "  Policy status    : ${GREEN}ALLOWED${RESET}" ;;
        1) echo -e "  Policy status    : ${RED}BLOCKED${RESET}" ;;
        2) echo -e "  Policy status    : ${YELLOW}NOT IN LIST${RESET}" ;;
    esac

    # List Node.js apps
    echo ""
    echo -e "${BOLD}Node.js Applications:${RESET}"
    echo "----------------------------------------------------"
    local APP_COUNT=0
    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        local APP_TYPE=$(grep "^APP_TYPE=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [ "$APP_TYPE" = "nodejs" ] || continue
        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        echo "  - $DN"
        ((APP_COUNT++))
    done
    [ "$APP_COUNT" -eq 0 ] && echo "  No Node.js applications found"

    echo ""
    return 0
}

do_upgrade(){
    local CURRENT=$(get_current_version "nodejs")
    local AVAILABLE=$(get_available_version "nodejs")

    if [ -z "$AVAILABLE" ] || [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "No upgrade available"
        return 0
    fi

    # Check if Node.js apps are running
    local APP_DOMAINS=()
    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        local APP_TYPE=$(grep "^APP_TYPE=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [ "$APP_TYPE" = "nodejs" ] || continue
        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        APP_DOMAINS+=("$DN")
    done

    if [ ${#APP_DOMAINS[@]} -gt 0 ]; then
        echo ""
        warn "The following Node.js apps will be affected:"
        for dn in "${APP_DOMAINS[@]}"; do
            echo "  - $dn"
        done
        echo ""
        echo "  Apps may need to restart or rebuild after upgrade."
    fi

    upgrade_service "nodejs" "$AVAILABLE" "
        # Graceful stop PM2 apps before upgrade
        if command -v pm2 &>/dev/null; then
            echo 'Gracefully stopping PM2 applications...'
            pm2 stop all 2>/dev/null
        fi

        # Upgrade Node.js
        dnf update -y nodejs npm 2>&1

        # Update npm to latest
        npm install -g npm@latest 2>/dev/null

        # Rebuild and restart PM2 managed apps
        if command -v pm2 &>/dev/null; then
            echo 'Updating PM2 and restarting applications...'
            pm2 update 2>/dev/null
            pm2 restart all 2>/dev/null
            if pm2 list 2>/dev/null | grep -q 'online'; then
                echo '[OK] PM2 apps restarted'
            else
                echo '[WARN] Some PM2 apps may not have restarted'
            fi
        fi
    "
}

while true; do
    clear
    echo "===================================================="
    echo "         NODE.JS UPGRADE MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Check for Upgrade"
    echo "  2) Upgrade Node.js"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) check_upgrade ;;
        2) do_upgrade ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
