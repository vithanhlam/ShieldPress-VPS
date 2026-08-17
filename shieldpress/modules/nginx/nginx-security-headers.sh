#!/bin/bash

CONF="/etc/nginx/conf.d/shieldpress-security-headers.conf"
BACKUP="${CONF}.bak.$(date +%s)"

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
    echo "           SECURITY HEADERS STATUS"
    echo "===================================================="
    echo ""

    if [ ! -f "$CONF" ]; then
        warn "Security headers NOT configured"
        echo ""
        return
    fi

    echo "Current configuration ($CONF):"
    echo "----------------------------------------------------"
    cat "$CONF" | grep -v "^#" | grep -v "^$" | sed 's/^/  /'
    echo ""
}

enable_headers(){
    echo ""
    echo "===================================================="
    echo "        ENABLE SECURITY HEADERS"
    echo "===================================================="
    echo ""
    echo "This will add the following security headers:"
    echo "  - X-Frame-Options (clickjacking protection)"
    echo "  - X-Content-Type-Options (MIME sniffing protection)"
    echo "  - X-XSS-Protection (XSS filter)"
    echo "  - Referrer-Policy (referrer information control)"
    echo "  - Permissions-Policy (browser feature restrictions)"
    echo "  - Strict-Transport-Security (HSTS)"
    echo "  - Content-Security-Policy (basic CSP)"
    echo ""

    read -p "Enable all security headers? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    [ -f "$CONF" ] && cp "$CONF" "$BACKUP"

    cat > "$CONF" <<'EOF'
# ====================================================
# ShieldPress Security Headers
# ====================================================

# Prevent clickjacking - allow same origin framing
add_header X-Frame-Options "SAMEORIGIN" always;

# Prevent MIME type sniffing
add_header X-Content-Type-Options "nosniff" always;

# Enable XSS filter in browsers
add_header X-XSS-Protection "1; mode=block" always;

# Control referrer information
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Restrict browser features/APIs
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;

# HTTP Strict Transport Security (1 year, include subdomains)
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

# Basic Content Security Policy
# Note: Adjust this based on your application needs
# add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data: https:;" always;
EOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Security headers enabled and Nginx reloaded"
    else
        fail "Nginx config error, rolling back..."
        [ -f "$BACKUP" ] && mv "$BACKUP" "$CONF" || rm -f "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

disable_headers(){
    echo ""
    if [ ! -f "$CONF" ]; then
        warn "Security headers are not enabled"
        return
    fi

    read -p "Disable all security headers? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    cp "$CONF" "$BACKUP"
    rm -f "$CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        ok "Security headers disabled"
    else
        fail "Error after removing, restoring..."
        mv "$BACKUP" "$CONF"
        nginx -t && systemctl reload nginx
    fi
}

edit_headers(){
    if [ ! -f "$CONF" ]; then
        warn "Security headers not configured. Enable them first."
        return
    fi

    if command -v nano &>/dev/null; then
        nano "$CONF"
    elif command -v vim &>/dev/null; then
        vim "$CONF"
    else
        vi "$CONF"
    fi

    echo ""
    read -p "Test & reload Nginx? (y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        if nginx -t 2>/dev/null; then
            systemctl reload nginx && ok "Nginx reloaded"
        else
            fail "Nginx config test failed!"
            nginx -t
        fi
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "           NGINX SECURITY HEADERS"
    echo "===================================================="
    echo ""
    echo "1) Show Current Status"
    echo "2) Enable Security Headers"
    echo "3) Disable Security Headers"
    echo "4) Edit Headers Config"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) enable_headers ;;
        3) disable_headers ;;
        4) edit_headers ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
