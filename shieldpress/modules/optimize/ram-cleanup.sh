#!/bin/bash

echo "Cleaning RAM page cache..."
sync
echo 3 > /proc/sys/vm/drop_caches
echo ""
echo "[OK] RAM cache cleared!"
free -h
read -p "Press Enter..."
