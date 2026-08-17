#!/bin/bash

while true; do
    clear
    echo "===================================================="
    echo "              VALKEY SERVER MANAGER"
    echo "===================================================="

    STATUS=$(systemctl is-active valkey 2>/dev/null)
    MEM=$(valkey-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')

    echo "Status : $STATUS"
    echo "Memory : ${MEM:-N/A}"
    echo ""
    echo "1) Install Valkey"
    echo "2) Start Valkey"
    echo "3) Stop Valkey"
    echo "4) Restart Valkey"
    echo "5) Valkey Info (Memory + Stats)"
    echo "6) Flush All Valkey Data"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " CHOICE

    case $CHOICE in
        1)
            echo "Installing Valkey..."
            dnf install -y valkey
            systemctl enable valkey
            systemctl start valkey
            echo "[OK] Valkey installed and started"
            ;;
        2)
            systemctl start valkey && echo "[OK] Valkey started" || echo "[FAIL] Start failed"
            ;;
        3)
            systemctl stop valkey && echo "[OK] Valkey stopped"
            ;;
        4)
            systemctl restart valkey && echo "[OK] Valkey restarted"
            ;;
        5)
            echo ""
            echo "=== MEMORY ==="
            valkey-cli info memory 2>/dev/null
            echo ""
            echo "=== STATS ==="
            valkey-cli info stats 2>/dev/null | grep -E "total_commands|keyspace_hits|keyspace_misses|connected_clients"
            ;;
        6)
            echo -e "\e[31mWARNING: This will flush ALL Valkey data!\e[0m"
            read -p "Continue? (y/n): " CONFIRM
            [[ "$CONFIRM" =~ ^[Yy]$ ]] && valkey-cli FLUSHALL && echo "[OK] Valkey flushed" || echo "Cancelled."
            ;;
        0) break ;;
        *) echo "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
