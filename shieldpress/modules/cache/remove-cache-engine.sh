#!/bin/bash
declare -F sp_header >/dev/null || source "${BASE_DIR:-/opt/shieldpress}/core/ui.sh"

clear
sp_header 'Remove Valkey'
echo ""
echo -e "\e[31mWARNING: This will remove Valkey and all cached data!\e[0m"
echo ""
read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }

systemctl stop    valkey 2>/dev/null
systemctl disable valkey 2>/dev/null
dnf remove -y valkey 2>/dev/null

echo "[OK] Valkey removed"
read -p "Press Enter..."
