#!/bin/bash
# ====================================================
# ShieldPress Controlled Nginx Upgrade
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

check_upgrade(){
    local CURRENT=$(get_current_version "nginx")
    local AVAILABLE=$(get_available_version "nginx")

    echo ""
    echo "===================================================="
    echo "             NGINX UPGRADE CHECK"
    echo "===================================================="
    echo ""
    echo "  Current version  : ${CURRENT:-Not installed}"
    echo "  Available version: ${AVAILABLE:-Unable to check}"
    echo ""

    if [ -z "$AVAILABLE" ]; then
        warn "Cannot check available version. Check dnf repos."
        return 1
    fi

    if [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "Already running the latest available version"
        return 1
    fi

    # Check policy
    load_policy
    check_version_allowed "nginx" "$AVAILABLE"
    local POLICY_RESULT=$?

    case $POLICY_RESULT in
        0) echo -e "  Policy status    : ${GREEN}ALLOWED${RESET}" ;;
        1) echo -e "  Policy status    : ${RED}BLOCKED${RESET}" ;;
        2) echo -e "  Policy status    : ${YELLOW}NOT IN LIST${RESET}" ;;
    esac

    echo ""
    return 0
}

do_upgrade(){
    local CURRENT=$(get_current_version "nginx")
    local AVAILABLE=$(get_available_version "nginx")

    if [ -z "$AVAILABLE" ] || [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "No upgrade available"
        return 0
    fi

    # Use the upgrade gate
    upgrade_service "nginx" "$AVAILABLE" "
        graceful_stop_service nginx
        dnf update -y nginx nginx-core 2>&1 && \
        systemctl start nginx
    "
}

while true; do
    clear
    echo "===================================================="
    echo "           NGINX UPGRADE MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Check for Upgrade"
    echo "  2) Upgrade Nginx"
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
