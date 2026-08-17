#!/bin/bash

CONF="/etc/nginx/conf.d/shieldpress-rate-limit.conf"
BACKUP="${CONF}.bak.$(date +%s)"
DOMAINS_ROOT="/home/domains"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

show_status(){
    echo ""
    echo "===================================================="
    echo "           RATE LIMITING STATUS"
    echo "===================================================="
    echo ""

    if [ ! -f "$CONF" ]; then
        warn "Global rate limiting: NOT configured"
    else
        ok "Global rate limiting: ENABLED"
        echo ""
        echo "Configuration:"
        cat "$CONF" | grep -v "^$" | sed 's/^/  /'
    fi

    echo ""
    echo "Per-domain rate limit directives:"
    echo "----------------------------------------------------"
    for DOMAIN_CONF in /etc/nginx/conf.d/*.conf; do
        [ -f "$DOMAIN_CONF" ] || continue
        [[ "$DOMAIN_CONF" == *shieldpress-* ]] && continue
        [[ "$DOMAIN_CONF" == *cache-zone-* ]] && continue
        if grep -q "limit_req " "$DOMAIN_CONF" 2>/dev/null; then
            DNAME=$(basename "$DOMAIN_CONF" .conf)
            echo -e "  ${GREEN}✓${RESET} $DNAME"
        fi
    done
    echo ""
}

enable_global(){
    echo ""
    echo "===================================================="
    echo "       ENABLE GLOBAL RATE LIMITING"
    echo "===================================================="
    echo ""
    echo "Rate limiting protects against:"
    echo "  - Brute force attacks"
    echo "  - DDoS / flood attacks"
    echo "  - API abuse"
    echo "  - Resource exhaustion"
    echo ""
    echo "Preset options:"
    echo "  1) Light   - 30 req/s (general websites)"
    echo "  2) Medium  - 15 req/s (WordPress/CMS)"
    echo "  3) Strict  - 5 req/s  (API / login pages)"
    echo "  4) Custom"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " preset

    case "$preset" in
        1) RATE="30r/s"; BURST=60; ZONE_SIZE="20m" ;;
        2) RATE="15r/s"; BURST=30; ZONE_SIZE="20m" ;;
        3) RATE="5r/s";  BURST=10; ZONE_SIZE="10m" ;;
        4)
            read -p "Rate (e.g. 10r/s): " RATE
            read -p "Burst (e.g. 20): " BURST
            read -p "Zone size (e.g. 20m): " ZONE_SIZE
            ;;
        0) return ;;
        *) warn "Invalid"; return ;;
    esac

    [ -f "$CONF" ] && cp "$CONF" "$BACKUP"

    cat > "$CONF" <<EOF
# ====================================================
# ShieldPress Rate Limiting
# ====================================================

# General request rate limiting
limit_req_zone \$binary_remote_addr zone=shieldpress_general:${ZONE_SIZE} rate=${RATE};

# Login/admin rate limiting (stricter)
limit_req_zone \$binary_remote_addr zone=shieldpress_login:10m rate=3r/s;

# API rate limiting
limit_req_zone \$binary_remote_addr zone=shieldpress_api:10m rate=10r/s;

# Connection limiting
limit_conn_zone \$binary_remote_addr zone=shieldpress_conn:10m;

# Custom error page for rate-limited requests
limit_req_status 429;
limit_conn_status 429;

# Log rate-limited requests at warn level (not error)
limit_req_log_level warn;
limit_conn_log_level warn;
EOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Global rate limit zones created (rate=${RATE}, burst=${BURST})"
        echo ""
        echo "Note: Rate limit zones are created but NOT applied to domains yet."
        echo "Use 'Apply to Domain' to activate rate limiting per domain."
    else
        fail "Nginx config error, rolling back..."
        [ -f "$BACKUP" ] && mv "$BACKUP" "$CONF" || rm -f "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

apply_to_domain(){
    echo ""
    if [ ! -f "$CONF" ]; then
        warn "Enable global rate limiting first"
        return
    fi

    source /opt/shieldpress/modules/domain/helpers.sh
    select_domain || return

    DOMAIN_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    [ ! -f "$DOMAIN_CONF" ] && { fail "Domain config not found"; return; }

    if grep -q "limit_req zone=shieldpress" "$DOMAIN_CONF" 2>/dev/null; then
        warn "Rate limiting already applied to $SELECTED_DOMAIN"
        read -p "Update? (y/n): " update
        [[ "$update" =~ ^[yY]$ ]] || return
        # Remove existing rate limit directives
        sed -i '/# ShieldPress Rate Limit/d' "$DOMAIN_CONF"
        sed -i '/limit_req zone=shieldpress/d' "$DOMAIN_CONF"
        sed -i '/limit_conn shieldpress/d' "$DOMAIN_CONF"
    fi

    cp "$DOMAIN_CONF" "${DOMAIN_CONF}.ratelimit.bak"

    # Add rate limiting inside the first server block
    sed -i '/server {/,/location/ {
        /location/ i\
    # ShieldPress Rate Limit\
    limit_req zone=shieldpress_general burst=20 nodelay;\
    limit_conn shieldpress_conn 50;
    }' "$DOMAIN_CONF"

    # Add stricter limits for wp-login and wp-admin
    if grep -q "wp-login\|wp-admin" "$DOMAIN_CONF" 2>/dev/null; then
        echo "  WordPress login rate limiting already configured"
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Rate limiting applied to $SELECTED_DOMAIN"
    else
        fail "Config error, rolling back..."
        mv "${DOMAIN_CONF}.ratelimit.bak" "$DOMAIN_CONF"
        nginx -t && systemctl reload nginx
    fi
}

remove_from_domain(){
    echo ""
    source /opt/shieldpress/modules/domain/helpers.sh
    select_domain || return

    DOMAIN_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    [ ! -f "$DOMAIN_CONF" ] && { fail "Domain config not found"; return; }

    if ! grep -q "limit_req zone=shieldpress\|limit_conn shieldpress" "$DOMAIN_CONF" 2>/dev/null; then
        warn "No rate limiting found for $SELECTED_DOMAIN"
        return
    fi

    cp "$DOMAIN_CONF" "${DOMAIN_CONF}.ratelimit.bak"

    sed -i '/# ShieldPress Rate Limit/d' "$DOMAIN_CONF"
    sed -i '/limit_req zone=shieldpress/d' "$DOMAIN_CONF"
    sed -i '/limit_conn shieldpress/d' "$DOMAIN_CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Rate limiting removed from $SELECTED_DOMAIN"
    else
        fail "Config error, restoring..."
        mv "${DOMAIN_CONF}.ratelimit.bak" "$DOMAIN_CONF"
        nginx -t && systemctl reload nginx
    fi
}

disable_global(){
    echo ""
    if [ ! -f "$CONF" ]; then
        warn "Global rate limiting is not enabled"
        return
    fi

    read -p "Disable global rate limiting? This removes zones config. (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    cp "$CONF" "$BACKUP"
    rm -f "$CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Global rate limiting disabled"
        warn "Note: Per-domain limit_req directives may still reference removed zones."
        echo "  Run 'Remove from Domain' for each domain to clean up."
    else
        fail "Error, restoring..."
        mv "$BACKUP" "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "            NGINX RATE LIMITING"
    echo "===================================================="
    echo ""
    echo "1) Show Status"
    echo "2) Enable Global Rate Limiting"
    echo "3) Apply to Domain"
    echo "4) Remove from Domain"
    echo "5) Disable Global Rate Limiting"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) enable_global ;;
        3) apply_to_domain ;;
        4) remove_from_domain ;;
        5) disable_global ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
