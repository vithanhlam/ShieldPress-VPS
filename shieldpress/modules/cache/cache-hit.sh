#!/bin/bash

LOG_DIR="/var/log/nginx/domains"

clear
echo "========================================"
echo "           CACHE HIT RATIO"
echo "========================================"

# Tìm tất cả access log của domains
LOGS=$(find "$LOG_DIR" -name "access.log" 2>/dev/null)
[ -z "$LOGS" ] && LOGS=$(find /var/log/nginx -name "access.log" 2>/dev/null | head -1)

if [ -z "$LOGS" ]; then
    echo "No access logs found."
    read -p "Press Enter..."; exit 1
fi

TOTAL_HIT=0; TOTAL_MISS=0; TOTAL_BYPASS=0

echo ""
printf "%-30s %-8s %-8s %-8s %-10s\n" "Domain" "HIT" "MISS" "BYPASS" "HIT%"
echo "------------------------------------------------------------"

for LOG in $LOGS; do
    DOMAIN=$(echo "$LOG" | grep -oP '/domains/\K[^/]+')
    [ -z "$DOMAIN" ] && DOMAIN="global"

    HIT=$(grep -cE '"HIT"' "$LOG" 2>/dev/null) || HIT=0
    MISS=$(grep -cE '"MISS"' "$LOG" 2>/dev/null) || MISS=0
    BYPASS=$(grep -cE '"BYPASS"' "$LOG" 2>/dev/null) || BYPASS=0
    TOTAL=$((HIT + MISS + BYPASS))

    if [ "$TOTAL" -gt 0 ]; then
        RATE=$((HIT * 100 / TOTAL))
    else
        RATE=0
    fi

    printf "%-30s %-8s %-8s %-8s %-10s\n" "$DOMAIN" "$HIT" "$MISS" "$BYPASS" "${RATE}%"

    TOTAL_HIT=$((TOTAL_HIT + HIT))
    TOTAL_MISS=$((TOTAL_MISS + MISS))
    TOTAL_BYPASS=$((TOTAL_BYPASS + BYPASS))
done

GRAND=$((TOTAL_HIT + TOTAL_MISS + TOTAL_BYPASS))
[ "$GRAND" -gt 0 ] && GRAND_RATE=$((TOTAL_HIT * 100 / GRAND)) || GRAND_RATE=0

echo "------------------------------------------------------------"
printf "%-30s %-8s %-8s %-8s %-10s\n" "TOTAL" "$TOTAL_HIT" "$TOTAL_MISS" "$TOTAL_BYPASS" "${GRAND_RATE}%"
echo "========================================"

read -p "Press Enter..."
