#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/nginx"
OPTIMIZE_DIR="$BASE_DIR/modules/optimize"
CACHE_DIR="$BASE_DIR/modules/cache"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARNING]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

# =================================================
# EDIT NGINX CONFIG (per-domain)
# =================================================

edit_nginx(){
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    echo ""
    echo "Selected domain: $SELECTED_DOMAIN"
    echo ""

    NGINX_FILE="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

    if [ ! -f "$NGINX_FILE" ]; then
        fail "Nginx config not found: $NGINX_FILE"
        return
    fi

    echo "Opening Nginx config:"
    echo "$NGINX_FILE"
    echo ""

    if command -v nano &>/dev/null; then
        nano "$NGINX_FILE"
    elif command -v vim &>/dev/null; then
        vim "$NGINX_FILE"
    else
        vi "$NGINX_FILE"
    fi

    echo ""
    read -p "Test & reload Nginx now? (y/n): " confirm

    if [[ "$confirm" =~ ^[yY]$ ]]; then
        if nginx -t 2>/dev/null; then
            systemctl reload nginx \
                && ok "Nginx reloaded" \
                || fail "Reload failed"
        else
            fail "Nginx config test failed!"
            nginx -t
        fi
    fi
}

# =================================================
# RELOAD NGINX
# =================================================

reload_nginx(){
    echo "Testing Nginx config..."
    if nginx -t 2>&1; then
        echo ""
        systemctl reload nginx \
            && ok "Nginx reloaded" \
            || fail "Nginx reload failed"
    else
        echo ""
        fail "Nginx config test failed! Fix config before reloading."
    fi
}

# =================================================
# VIEW NGINX LOGS
# =================================================

view_nginx_logs(){
    echo ""
    echo "1) Global access log"
    echo "2) Global error log"
    echo "3) Domain-specific log"
    echo "0) Cancel"
    read -p "Select: " opt

    case $opt in
        1) tail -f /var/log/nginx/access.log ;;
        2) tail -f /var/log/nginx/error.log ;;
        3)
            DOMAINS_ROOT="/home/domains"
            echo ""
            echo "Available domains:"
            i=1
            declare -a DLIST
            for d in "$DOMAINS_ROOT"/*/; do
                [ -d "$d" ] || continue
                DN=$(grep "^DOMAIN=" "$d/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
                [ -z "$DN" ] && continue
                echo "$i) $DN"
                DLIST[$i]=$(basename "$d")
                ((i++))
            done
            read -p "Select domain: " DC
            DF="${DLIST[$DC]}"
            [ -z "$DF" ] && { warn "Invalid"; return; }
            LOG_DIR="/var/log/nginx/domains/$DF"
            echo "1) access.log  2) error.log"
            read -p "Choose: " LC
            case $LC in
                1) tail -f "$LOG_DIR/access.log" ;;
                2) tail -f "$LOG_DIR/error.log" ;;
            esac
            ;;
        0) return ;;
        *) warn "Invalid option" ;;
    esac
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "Nginx Manager" "Configuration, optimization & security"
    sp_menu_grid \
        "1|Optimize Nginx|green" \
        "2|Enable HTTP/3|green" \
        "3|Disable HTTP/3|yellow" \
        "4|Tune Laravel/Node Nginx|cyan" \
        "5|Enable FastCGI Cache|green" \
        "6|Disable FastCGI Cache|yellow" \
        "7|Upload Limit Manager|cyan" \
        "8|Security Headers|blue" \
        "9|Brotli Compression|green" \
        "10|Rate Limiting|blue" \
        "11|Password Protection|green" \
        "12|Nginx Status & Info|cyan" \
        "13|Edit Nginx Config|yellow" \
        "14|View Nginx Logs|magenta" \
        "15|Reload Nginx|yellow" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1)  bash "$OPTIMIZE_DIR/nginx-optimize.sh" ;;
        2)  bash "$OPTIMIZE_DIR/http3-enable.sh" ;;
        3)  bash "$OPTIMIZE_DIR/http3-disable.sh" ;;
        4)  bash "$OPTIMIZE_DIR/app-nginx-tune.sh" ;;
        5)  bash "$CACHE_DIR/enable-fastcgi-cache.sh" ;;
        6)  bash "$CACHE_DIR/disable-fastcgi-cache.sh" ;;
        7)  bash "$OPTIMIZE_DIR/upload-limit.sh" ;;
        8)  bash "$MODULE_DIR/nginx-security-headers.sh" ;;
        9)  bash "$MODULE_DIR/nginx-brotli.sh" ;;
        10) bash "$MODULE_DIR/nginx-rate-limit.sh" ;;
        11) bash "$MODULE_DIR/nginx-auth.sh" ;;
        12) bash "$MODULE_DIR/nginx-status.sh" ;;
        13) edit_nginx ;;
        14) view_nginx_logs ;;
        15) reload_nginx ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac

    pause
done
