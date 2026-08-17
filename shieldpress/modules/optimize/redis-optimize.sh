#!/bin/bash

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
MAXMEM=$((TOTAL_RAM / 4))
[ "$MAXMEM" -gt 2048 ] && MAXMEM=2048

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }

VALKEY_CONF="/etc/valkey/valkey.conf"
REDIS_CONF="/etc/redis.conf"

if [ -f "$VALKEY_CONF" ]; then

    echo "Optimizing Valkey..."
    sed -i '/^maxmemory /d'        "$VALKEY_CONF"
    sed -i '/^maxmemory-policy /d' "$VALKEY_CONF"
    echo "maxmemory ${MAXMEM}mb"        >> "$VALKEY_CONF"
    echo "maxmemory-policy allkeys-lru" >> "$VALKEY_CONF"

    systemctl restart valkey 2>/dev/null && ok "Valkey optimized (${MAXMEM}mb)" || warn "Valkey restart failed"

    echo "Flushing Valkey..."
    valkey-cli FLUSHALL 2>/dev/null && ok "Valkey flushed"

elif [ -f "$REDIS_CONF" ]; then

    echo "Optimizing Redis..."
    sed -i '/^maxmemory /d'        "$REDIS_CONF"
    sed -i '/^maxmemory-policy /d' "$REDIS_CONF"
    echo "maxmemory ${MAXMEM}mb"        >> "$REDIS_CONF"
    echo "maxmemory-policy allkeys-lru" >> "$REDIS_CONF"

    systemctl restart redis 2>/dev/null && ok "Redis optimized (${MAXMEM}mb)" || warn "Redis restart failed"

    echo "Flushing Redis..."
    redis-cli FLUSHALL 2>/dev/null && ok "Redis flushed"

else
    warn "No Valkey/Redis config found"
fi

echo ""
echo "Cache server optimized."
read -p "Press Enter..."
