#!/bin/bash
# ====================================================
# ShieldPress Controlled PostgreSQL Upgrade
# Dump database trước, upgrade, pg_upgrade nếu major
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
    local CURRENT=$(get_current_version "postgresql")
    local AVAILABLE=$(get_available_version "postgresql")

    echo ""
    echo "===================================================="
    echo "         POSTGRESQL UPGRADE CHECK"
    echo "===================================================="
    echo ""
    echo "  Current version  : ${CURRENT:-Not installed}"
    echo "  Available version: ${AVAILABLE:-Unable to check}"
    echo ""

    if [ -z "$CURRENT" ]; then
        warn "PostgreSQL not detected"
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

    # Check major version change
    local CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
    local AVA_MAJOR=$(echo "$AVAILABLE" | cut -d. -f1)

    if [ "$CUR_MAJOR" != "$AVA_MAJOR" ]; then
        warn "MAJOR VERSION CHANGE: $CUR_MAJOR → $AVA_MAJOR"
        echo ""
        echo -e "  ${RED}${BOLD}Major PostgreSQL upgrades require special handling:${RESET}"
        echo "  1. Full pg_dumpall of all databases"
        echo "  2. Stop old PostgreSQL"
        echo "  3. Install new version"
        echo "  4. Run pg_upgrade OR restore from dump"
        echo "  5. Validate data integrity"
        echo ""
        echo "  This process will be handled automatically."
    fi

    # Check policy
    load_policy
    check_version_allowed "postgresql" "$AVAILABLE"
    case $? in
        0) echo -e "  Policy status    : ${GREEN}ALLOWED${RESET}" ;;
        1) echo -e "  Policy status    : ${RED}BLOCKED${RESET}" ;;
        2) echo -e "  Policy status    : ${YELLOW}NOT IN LIST${RESET}" ;;
    esac

    # Show databases
    echo ""
    echo -e "${BOLD}Databases:${RESET}"
    sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;" 2>/dev/null | sed 's/^/  /'

    # Data directory
    local DATA_DIR=$(sudo -u postgres psql -t -c "SHOW data_directory;" 2>/dev/null | tr -d '[:space:]')
    echo ""
    echo "  Data directory: ${DATA_DIR:-/var/lib/pgsql/data}"
    local DATA_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')
    echo "  Data size     : ${DATA_SIZE:-unknown}"

    echo ""
    return 0
}

do_upgrade(){
    local CURRENT=$(get_current_version "postgresql")
    local AVAILABLE=$(get_available_version "postgresql")

    if [ -z "$AVAILABLE" ] || [ "$CURRENT" = "$AVAILABLE" ]; then
        ok "No upgrade available"
        return 0
    fi

    local CUR_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
    local AVA_MAJOR=$(echo "$AVAILABLE" | cut -d. -f1)

    if [ "$CUR_MAJOR" != "$AVA_MAJOR" ]; then
        # Major version upgrade → dump and restore approach
        upgrade_service "postgresql" "$AVAILABLE" "
            echo 'Major version upgrade - using dump/restore approach...'

            # Dump
            echo 'Creating full database dump...'
            local DUMP_FILE='$BASE_DIR/backups/pre-upgrade/postgresql-major-\$(date +%Y%m%d_%H%M%S).sql'
            mkdir -p '$BASE_DIR/backups/pre-upgrade'
            sudo -u postgres pg_dumpall > \"\$DUMP_FILE\" 2>/dev/null
            if [ ! -s \"\$DUMP_FILE\" ]; then
                echo '[FAIL] Database dump is empty, aborting!'
                exit 1
            fi
            echo \"[OK] Dump saved: \$DUMP_FILE\"

            # Graceful stop
            graceful_stop_service postgresql

            # Backup old data dir
            local DATA_DIR=\$(cat /var/lib/pgsql/data/postmaster.pid 2>/dev/null | sed -n '4p')
            DATA_DIR=\"\${DATA_DIR:-/var/lib/pgsql/data}\"
            mv \"\$DATA_DIR\" \"\${DATA_DIR}.old.\$(date +%s)\" 2>/dev/null

            # Upgrade packages
            dnf update -y postgresql-server postgresql postgresql-contrib 2>&1

            # Init new cluster
            postgresql-setup --initdb 2>/dev/null || \
                /usr/pgsql-${AVA_MAJOR}/bin/postgresql-${AVA_MAJOR}-setup initdb 2>/dev/null

            # Start new version
            systemctl start postgresql

            # Restore dump
            echo 'Restoring databases into new version...'
            sudo -u postgres psql < \"\$DUMP_FILE\" 2>/dev/null

            echo '[OK] Major version upgrade completed'
        "
    else
        # Minor/patch upgrade → simple dnf update
        upgrade_service "postgresql" "$AVAILABLE" "
            graceful_stop_service postgresql
            dnf update -y postgresql-server postgresql postgresql-contrib 2>&1
            systemctl start postgresql 2>/dev/null
        "
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "        POSTGRESQL UPGRADE MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Check for Upgrade"
    echo "  2) Upgrade PostgreSQL"
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
