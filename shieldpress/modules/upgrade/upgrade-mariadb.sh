#!/bin/bash
# ====================================================
# ShieldPress Controlled MariaDB Upgrade
# Dump database trước, upgrade, validate sau
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
    local CURRENT=$(get_current_version "mariadb")
    local AVAILABLE=$(get_available_version "mariadb")

    echo ""
    echo "===================================================="
    echo "           MARIADB UPGRADE CHECK"
    echo "===================================================="
    echo ""
    echo "  Current version  : ${CURRENT:-Not installed}"
    echo "  Available version: ${AVAILABLE:-Unable to check}"
    echo ""

    if [ -z "$CURRENT" ]; then
        warn "MariaDB not detected"
        return 1
    fi

    if [ -z "$AVAILABLE" ]; then
        warn "Cannot check available version"
        return 1
    fi

    if [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "Already running the latest available version"
        return 1
    fi

    # Check if this is a major version change
    local CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1-2)
    local AVA_MAJOR=$(echo "$AVAILABLE" | cut -d. -f1-2)

    if [ "$CUR_MAJOR" != "$AVA_MAJOR" ]; then
        warn "MAJOR VERSION CHANGE detected ($CUR_MAJOR → $AVA_MAJOR)"
        echo "  Major upgrades carry higher risk of breaking changes."
        echo "  A full database dump will be created before upgrade."
    fi

    # Check policy
    load_policy
    check_version_allowed "mariadb" "$AVAILABLE"
    case $? in
        0) echo -e "  Policy status    : ${GREEN}ALLOWED${RESET}" ;;
        1) echo -e "  Policy status    : ${RED}BLOCKED${RESET}" ;;
        2) echo -e "  Policy status    : ${YELLOW}NOT IN LIST${RESET}" ;;
    esac

    # Show database sizes
    echo ""
    echo -e "${BOLD}Databases:${RESET}"
    mysql -e "SELECT table_schema AS 'Database', ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)' FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length + index_length) DESC;" 2>/dev/null | sed 's/^/  /'

    echo ""
    return 0
}

do_upgrade(){
    local CURRENT=$(get_current_version "mariadb")
    local AVAILABLE=$(get_available_version "mariadb")

    if [ -z "$AVAILABLE" ] || [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "No upgrade available"
        return 0
    fi

    upgrade_service "mariadb" "$AVAILABLE" "
        # Stop MariaDB gracefully (wait for connections to drain)
        graceful_stop_service mariadb

        # Perform upgrade
        dnf update -y mariadb-server mariadb mariadb-common 2>&1

        # Start MariaDB
        systemctl start mariadb 2>/dev/null
        sleep 2

        # Run mysql_upgrade for schema compatibility
        if command -v mariadb-upgrade &>/dev/null; then
            echo 'Running mariadb-upgrade...'
            mariadb-upgrade --force 2>&1
        elif command -v mysql_upgrade &>/dev/null; then
            echo 'Running mysql_upgrade...'
            mysql_upgrade --force 2>&1
        fi

        # Restart to apply any changes from upgrade
        systemctl restart mariadb 2>/dev/null
    "
}

while true; do
    clear
    echo "===================================================="
    echo "          MARIADB UPGRADE MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Check for Upgrade"
    echo "  2) Upgrade MariaDB"
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
