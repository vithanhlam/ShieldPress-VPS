#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/ram-manager.log"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok()  { echo -e "${GREEN}[OK]${RESET} $1";   log "[OK] $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; log "[WARN] $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1";    log "[FAIL] $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

# ==============================
# SHOW RAM STATUS
# ==============================
show_ram_status(){
    echo ""
    echo "RAM STATUS"
    echo "================================"
    free -h
    echo ""

    echo "SWAP:"
    swapon --show 2>/dev/null || echo "  No swap active"
    echo ""

    echo "ZRAM:"
    if lsblk | grep -q zram; then
        lsblk | grep zram
    else
        echo "  ZRAM not active"
    fi
    echo ""

    echo "Top 10 RAM processes:"
    echo "--------------------------------"
    ps -eo pid,user,comm,%mem,rss --sort=-%mem | head -11
    echo ""
}

# ==============================
# CLEAR RAM CACHE
# ==============================
clear_ram_cache(){
    echo "Cleaning RAM cache..."
    sync
    echo 3 > /proc/sys/vm/drop_caches
    echo ""
    free -h
    ok "RAM cache cleared"
}

# ==============================
# INSTALL / CONFIGURE ZRAM
# ==============================
setup_zram(){
    echo "Installing ZRAM (compressed swap in RAM)..."
    echo ""

    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    DEFAULT_ZRAM=$((TOTAL_RAM / 2))

    echo "Total RAM: ${TOTAL_RAM}MB"
    echo "Default ZRAM size: ${DEFAULT_ZRAM}MB (50% of RAM)"
    echo ""
    read -p "ZRAM size in MB [${DEFAULT_ZRAM}]: " ZRAM_SIZE
    ZRAM_SIZE="${ZRAM_SIZE:-$DEFAULT_ZRAM}"

    if dnf install -y zram-generator >/dev/null 2>&1; then
        cat > /etc/systemd/zram-generator.conf <<ZEOF
[zram0]
zram-size = ${ZRAM_SIZE}M
compression-algorithm = zstd
ZEOF
        systemctl daemon-reexec
        systemctl restart systemd-zram-setup@zram0 2>/dev/null || true
        echo ""
        swapon --show
        ok "ZRAM enabled (${ZRAM_SIZE}MB, zstd compression)"
    else
        warn "zram-generator not available on this system"
    fi
}

# ==============================
# ADD SWAP FILE (Virtual RAM)
# ==============================
add_swap_file(){
    echo ""
    echo "Add Swap File (Virtual RAM)"
    echo "================================"

    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    echo "Total RAM: ${TOTAL_RAM}MB"
    echo ""

    # Check existing swap files
    if [ -f /swapfile ]; then
        CURRENT_SWAP=$(ls -lh /swapfile | awk '{print $5}')
        echo "Existing swap file: /swapfile ($CURRENT_SWAP)"
        echo ""
        read -p "Remove existing swap and create new? (y/n): " REMOVE_OLD
        if [[ "$REMOVE_OLD" == "y" ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
            sed -i '/\/swapfile/d' /etc/fstab
            ok "Old swap file removed"
        else
            warn "Keeping existing swap file"
            return
        fi
    fi

    echo "Recommended swap sizes:"
    echo "  1) 1 GB"
    echo "  2) 2 GB"
    echo "  3) 4 GB"
    echo "  4) 8 GB"
    echo "  5) Custom"
    echo ""
    read -p "Select [2]: " SWAP_OPT
    SWAP_OPT="${SWAP_OPT:-2}"

    case "$SWAP_OPT" in
        1) SWAP_SIZE=1 ;;
        2) SWAP_SIZE=2 ;;
        3) SWAP_SIZE=4 ;;
        4) SWAP_SIZE=8 ;;
        5)
            read -p "Enter swap size in GB: " SWAP_SIZE
            if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || [ "$SWAP_SIZE" -lt 1 ]; then
                fail "Invalid size"
                return 1
            fi
            ;;
        *) fail "Invalid option"; return 1 ;;
    esac

    echo ""
    echo "Creating ${SWAP_SIZE}GB swap file..."

    dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=progress || {
        fail "Failed to create swap file"
        return 1
    }

    chmod 600 /swapfile
    mkswap /swapfile || { fail "mkswap failed"; rm -f /swapfile; return 1; }
    swapon /swapfile || { fail "swapon failed"; rm -f /swapfile; return 1; }

    # Add to fstab for persistence
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    ok "Swap file created: ${SWAP_SIZE}GB"
    echo ""
    free -h
}

# ==============================
# REMOVE SWAP FILE
# ==============================
remove_swap_file(){
    echo ""
    if [ ! -f /swapfile ]; then
        warn "No swap file found at /swapfile"
        return
    fi

    CURRENT_SWAP=$(ls -lh /swapfile | awk '{print $5}')
    echo "Current swap file: /swapfile ($CURRENT_SWAP)"
    read -p "Remove swap file? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
        ok "Swap file removed"
        echo ""
        free -h
    else
        warn "Cancelled"
    fi
}

# ==============================
# TUNE SWAPPINESS
# ==============================
tune_swappiness(){
    echo ""
    CURRENT=$(cat /proc/sys/vm/swappiness)
    echo "Current swappiness: $CURRENT"
    echo ""
    echo "Recommended values:"
    echo "  10 = Prefer RAM, rarely swap (server/VPS)"
    echo "  30 = Light swap usage"
    echo "  60 = Default Linux"
    echo ""
    read -p "New swappiness value [10]: " NEW_SWAP
    NEW_SWAP="${NEW_SWAP:-10}"

    if ! [[ "$NEW_SWAP" =~ ^[0-9]+$ ]] || [ "$NEW_SWAP" -gt 100 ]; then
        fail "Invalid value (0-100)"
        return 1
    fi

    sysctl vm.swappiness=$NEW_SWAP
    # Persist
    if grep -q "^vm.swappiness" /etc/sysctl.conf; then
        sed -i "s/^vm.swappiness=.*/vm.swappiness=$NEW_SWAP/" /etc/sysctl.conf
    else
        echo "vm.swappiness=$NEW_SWAP" >> /etc/sysctl.conf
    fi

    ok "Swappiness set to $NEW_SWAP"
}

# ==============================
# RAM AUTO OPTIMIZER
# ==============================
ram_auto_optimize(){
    bash "$BASE_DIR/modules/optimize/ram-auto-optimize.sh"
}

# ==============================
# MAIN MENU
# ==============================

while true; do
    clear
    sp_header "RAM Manager" "Memory optimization and virtual RAM"
    sp_menu_grid \
        "1|Show RAM Status|cyan" \
        "2|Clear RAM Cache|green" \
        "3|Install / Configure ZRAM|blue" \
        "4|Add Swap File (Virtual RAM)|green" \
        "5|Remove Swap File|red" \
        "6|Tune Swappiness|yellow" \
        "7|RAM Auto Optimizer|magenta" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) show_ram_status ;;
        2) clear_ram_cache ;;
        3) setup_zram ;;
        4) add_swap_file ;;
        5) remove_swap_file ;;
        6) tune_swappiness ;;
        7) ram_auto_optimize ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
