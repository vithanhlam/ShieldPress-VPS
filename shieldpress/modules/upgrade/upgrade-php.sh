#!/bin/bash
# ====================================================
# ShieldPress Controlled PHP Upgrade
# Nâng cấp PHP patch/minor trong cùng major version
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

PHP_VERSIONS=("81" "82" "83" "84")

check_upgrade(){
    echo ""
    echo "===================================================="
    echo "             PHP UPGRADE CHECK"
    echo "===================================================="
    echo ""

    load_policy

    local HAS_UPDATE=0

    printf "  %-8s %-15s %-15s %-12s\n" "Version" "Current" "Available" "Policy"
    echo "  --------------------------------------------------------"

    for v in "${PHP_VERSIONS[@]}"; do
        local BIN="/opt/remi/php${v}/root/usr/bin/php"
        [ -x "$BIN" ] || continue

        local VER_DOT="${v:0:1}.${v:1}"
        local CURRENT=$("$BIN" -v 2>/dev/null | head -1 | awk '{print $2}')
        local AVAILABLE=$(dnf info "php${v}-php-fpm" 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1)

        local POLICY_STATUS=""
        if [ -n "$AVAILABLE" ]; then
            check_version_allowed "php" "$AVAILABLE"
            case $? in
                0) POLICY_STATUS="${GREEN}allowed${RESET}" ;;
                1) POLICY_STATUS="${RED}blocked${RESET}" ;;
                2) POLICY_STATUS="${YELLOW}unknown${RESET}" ;;
            esac
        fi

        local UPDATE_MARK=""
        if [ -n "$AVAILABLE" ] && [ "$CURRENT" != "$AVAILABLE" ]; then
            UPDATE_MARK="${YELLOW}*${RESET}"
            HAS_UPDATE=1
        fi

        printf "  %-8s %-15s %-15s %b\n" "PHP $VER_DOT" "$CURRENT" "${AVAILABLE:-N/A}$UPDATE_MARK" "$POLICY_STATUS"

        # Show domains using this version
        local COUNT=0
        for d in /home/domains/*/config/domain.env; do
            [ -f "$d" ] || continue
            local DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
            [ "$DPHP" = "$v" ] && ((COUNT++))
        done
        echo -e "           ${DIM}$COUNT domain(s) using${RESET}"
    done

    echo ""
    if [ "$HAS_UPDATE" -eq 1 ]; then
        echo -e "  ${YELLOW}*${RESET} = update available"
    else
        ok "All PHP versions are up to date"
    fi
}

do_upgrade(){
    echo ""
    echo "Select PHP version to upgrade:"

    local IDX=1
    declare -A MAP
    local HAS_UPGRADEABLE=0

    for v in "${PHP_VERSIONS[@]}"; do
        local BIN="/opt/remi/php${v}/root/usr/bin/php"
        [ -x "$BIN" ] || continue

        local VER_DOT="${v:0:1}.${v:1}"
        local CURRENT=$("$BIN" -v 2>/dev/null | head -1 | awk '{print $2}')
        local AVAILABLE=$(dnf info "php${v}-php-fpm" 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1)

        if [ -n "$AVAILABLE" ] && [ "$CURRENT" != "$AVAILABLE" ]; then
            echo "  $IDX) PHP $VER_DOT  ($CURRENT → $AVAILABLE)"
            MAP[$IDX]=$v
            HAS_UPGRADEABLE=1
        else
            echo -e "  ${DIM}$IDX) PHP $VER_DOT  ($CURRENT) - up to date${RESET}"
        fi
        ((IDX++))
    done

    echo "  A) Upgrade ALL"
    echo "  0) Cancel"
    echo ""

    if [ "$HAS_UPGRADEABLE" -eq 0 ]; then
        ok "All PHP versions are up to date"
        return
    fi

    read -p "Select: " CHOICE
    [ "$CHOICE" = "0" ] && return

    local TARGETS=()

    if [[ "$CHOICE" =~ ^[aA]$ ]]; then
        for v in "${PHP_VERSIONS[@]}"; do
            [ -x "/opt/remi/php${v}/root/usr/bin/php" ] && TARGETS+=("$v")
        done
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        local TARGET="${MAP[$CHOICE]}"
        [ -z "$TARGET" ] && { fail "Invalid selection"; return; }
        TARGETS=("$TARGET")
    else
        fail "Invalid"; return
    fi

    for v in "${TARGETS[@]}"; do
        local VER_DOT="${v:0:1}.${v:1}"
        local AVAILABLE=$(dnf info "php${v}-php-fpm" 2>/dev/null | grep "^Version" | awk '{print $3}' | head -1)

        [ -z "$AVAILABLE" ] && continue

        upgrade_service "php${v}" "$AVAILABLE" "
            graceful_stop_service php${v}
            dnf update -y php${v}-* 2>&1 && \
            systemctl start php${v}-php-fpm
        "
    done
}

while true; do
    clear
    echo "===================================================="
    echo "           PHP UPGRADE MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Check for Upgrades"
    echo "  2) Upgrade PHP Version"
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
