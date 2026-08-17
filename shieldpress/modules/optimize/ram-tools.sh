#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/ram-tools.log"
mkdir -p "$LOG_DIR"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok()  { echo "[OK] $1";   log "[OK] $1"; }
warn(){ echo "[WARN] $1"; log "[WARN] $1"; }

if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

while true; do
clear
echo "===================================================="
echo "                     RAM TOOLS"
echo "===================================================="
echo " 1) Clear RAM Cache"
echo " 2) Install / Configure ZRAM"
echo " 3) Show RAM Usage"
echo " 0) Back"
echo "----------------------------------------------------"
read -p "Select: " CHOICE

case $CHOICE in

1)
    echo "Cleaning RAM cache..."
    sync
    echo 3 > /proc/sys/vm/drop_caches
    echo ""
    free -h
    ok "RAM cache cleared"
    read -p "Press Enter..."
    ;;

2)
    echo "Installing ZRAM..."
    if dnf install -y zram-generator >/dev/null 2>&1; then
        TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
        ZRAM_SIZE=$((TOTAL_RAM / 2))
        cat > /etc/systemd/zram-generator.conf <<ZEOF
[zram0]
zram-size = ${ZRAM_SIZE}M
compression-algorithm = zstd
ZEOF
        systemctl daemon-reexec
        systemctl restart systemd-zram-setup@zram0 2>/dev/null || true
        echo ""
        swapon --show
        ok "ZRAM enabled (${ZRAM_SIZE}MB)"
    else
        warn "zram-generator not available on this system"
    fi
    read -p "Press Enter..."
    ;;

3)
    echo "RAM STATUS"
    echo "--------------------------------"
    free -h
    echo ""
    echo "Top RAM processes:"
    ps -eo pid,user,comm,%mem --sort=-%mem | head -10
    echo ""
    read -p "Press Enter..."
    ;;

0) break ;;
*) echo "Invalid option"; sleep 1 ;;
esac
done
