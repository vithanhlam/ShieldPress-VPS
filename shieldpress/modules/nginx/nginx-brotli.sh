#!/bin/bash

CONF="/etc/nginx/conf.d/shieldpress-brotli.conf"
BACKUP="${CONF}.bak.$(date +%s)"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

check_brotli_module(){
    if nginx -V 2>&1 | grep -q "ngx_brotli\|brotli"; then
        return 0
    fi
    return 1
}

install_brotli(){
    echo ""
    echo "===================================================="
    echo "        INSTALL BROTLI MODULE"
    echo "===================================================="
    echo ""

    if check_brotli_module; then
        ok "Brotli module already available"
        return 0
    fi

    echo "Brotli module not found in current Nginx build."
    echo ""
    echo "Installing Brotli dynamic module..."
    echo ""

    # Try installing via package manager first
    if command -v dnf &>/dev/null; then
        dnf install -y nginx-mod-brotli 2>/dev/null && {
            ok "Brotli module installed via dnf"
            # Load the module
            if [ ! -f /etc/nginx/modules-enabled/brotli.conf ]; then
                mkdir -p /etc/nginx/modules-enabled
                echo "load_module modules/ngx_http_brotli_filter_module.so;" > /etc/nginx/modules-enabled/brotli.conf
                echo "load_module modules/ngx_http_brotli_static_module.so;" >> /etc/nginx/modules-enabled/brotli.conf
            fi
            return 0
        }
    fi

    # Alternative: try from nginx extras
    if command -v dnf &>/dev/null; then
        dnf install -y nginx-mod-http-brotli 2>/dev/null && {
            ok "Brotli module installed"
            return 0
        }
    fi

    warn "Could not install Brotli automatically."
    echo ""
    echo "Manual installation options:"
    echo "  1. Compile Nginx with --add-dynamic-module=brotli"
    echo "  2. Use a pre-built package for your distribution"
    echo ""
    return 1
}

enable_brotli(){
    echo ""
    echo "===================================================="
    echo "         ENABLE BROTLI COMPRESSION"
    echo "===================================================="
    echo ""

    if ! check_brotli_module; then
        warn "Brotli module not found in Nginx"
        read -p "Try to install Brotli module? (y/n): " install_confirm
        if [[ "$install_confirm" =~ ^[yY]$ ]]; then
            install_brotli || { fail "Installation failed"; return; }
        else
            return
        fi
    fi

    echo "Brotli offers ~20-30% better compression than Gzip"
    echo "for text-based content (HTML, CSS, JS, JSON, etc.)"
    echo ""

    read -p "Select compression level (1-11, recommended 6): " LEVEL
    [[ "$LEVEL" =~ ^[0-9]+$ ]] || LEVEL=6
    [ "$LEVEL" -lt 1 ] && LEVEL=1
    [ "$LEVEL" -gt 11 ] && LEVEL=11

    [ -f "$CONF" ] && cp "$CONF" "$BACKUP"

    cat > "$CONF" <<EOF
# ====================================================
# ShieldPress Brotli Compression
# ~20-30% better compression than Gzip
# ====================================================

brotli on;
brotli_comp_level $LEVEL;
brotli_min_length 256;
brotli_types
    text/plain
    text/css
    text/javascript
    text/xml
    application/javascript
    application/json
    application/xml
    application/xml+rss
    application/rss+xml
    application/atom+xml
    application/vnd.ms-fontobject
    application/x-font-ttf
    application/x-font-opentype
    font/opentype
    font/eot
    font/otf
    image/svg+xml
    image/x-icon;

# Static pre-compressed .br files (if available)
brotli_static on;
EOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Brotli compression enabled (level $LEVEL)"
    else
        fail "Nginx config error, rolling back..."
        [ -f "$BACKUP" ] && mv "$BACKUP" "$CONF" || rm -f "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

disable_brotli(){
    echo ""
    if [ ! -f "$CONF" ]; then
        warn "Brotli is not enabled"
        return
    fi

    read -p "Disable Brotli compression? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    cp "$CONF" "$BACKUP"
    rm -f "$CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Brotli compression disabled"
    else
        fail "Error, restoring..."
        mv "$BACKUP" "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

show_status(){
    echo ""
    echo "===================================================="
    echo "           BROTLI STATUS"
    echo "===================================================="
    echo ""

    if check_brotli_module; then
        ok "Brotli module: Available"
    else
        fail "Brotli module: Not found"
    fi

    if [ -f "$CONF" ]; then
        ok "Brotli config: Enabled"
        echo ""
        LEVEL=$(grep "brotli_comp_level" "$CONF" 2>/dev/null | awk '{print $2}' | tr -d ';')
        echo "  Compression level : ${LEVEL:-N/A}"
    else
        warn "Brotli config: Not configured"
    fi

    echo ""

    # Check if gzip is also enabled
    if grep -rq "gzip on" /etc/nginx/conf.d/ 2>/dev/null || grep -q "gzip on" /etc/nginx/nginx.conf 2>/dev/null; then
        ok "Gzip: Also enabled (Brotli takes priority for supported browsers)"
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "          NGINX BROTLI COMPRESSION"
    echo "===================================================="
    echo ""
    echo "1) Show Status"
    echo "2) Enable Brotli"
    echo "3) Disable Brotli"
    echo "4) Install Brotli Module"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) enable_brotli ;;
        3) disable_brotli ;;
        4) install_brotli ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
