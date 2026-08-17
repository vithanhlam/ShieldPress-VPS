#!/bin/bash
# =====================================================
# ShieldPress - Nginx Password Protection (Basic Auth)
# Protect domains or specific URLs with username/password
# =====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
source "$BASE_DIR/core/helpers.sh"

AUTH_DIR="$NGINX_AUTH_DIR"
AUTH_DATA_DIR="$DATA_DIR_AUTH"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

# =====================================================
# INIT - Ensure directories and tools exist
# =====================================================
init_auth(){
    mkdir -p "$AUTH_DIR" "$AUTH_DATA_DIR"

    if ! command -v htpasswd &>/dev/null; then
        echo "Installing httpd-tools (htpasswd)..."
        if command -v yum &>/dev/null; then
            yum install -y httpd-tools &>/dev/null
        elif command -v apt-get &>/dev/null; then
            apt-get install -y apache2-utils &>/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y httpd-tools &>/dev/null
        fi

        if ! command -v htpasswd &>/dev/null; then
            fail "Could not install htpasswd. Please install httpd-tools manually."
            return 1
        fi
        ok "htpasswd installed"
    fi
    return 0
}

# =====================================================
# READ AUTH METADATA
# =====================================================
# Metadata file format (per domain): $AUTH_DATA_DIR/{CLEAN_DOMAIN}.auth
#   MODE=full|url
#   URL=/some/path        (only when MODE=url)
#   AUTH_USER=username
#   AUTH_PASS=password     (plaintext for display)
#   STATUS=on|off

read_auth_meta(){
    local clean_domain="$1"
    local meta_file="$AUTH_DATA_DIR/${clean_domain}.auth"
    [ -f "$meta_file" ] || return 1

    AUTH_MODE=$(grep "^MODE=" "$meta_file" | cut -d'=' -f2-)
    AUTH_URL=$(grep "^URL=" "$meta_file" | cut -d'=' -f2-)
    AUTH_USER=$(grep "^AUTH_USER=" "$meta_file" | cut -d'=' -f2-)
    AUTH_PASS=$(grep "^AUTH_PASS=" "$meta_file" | cut -d'=' -f2-)
    AUTH_STATUS=$(grep "^STATUS=" "$meta_file" | cut -d'=' -f2-)
    return 0
}

save_auth_meta(){
    local clean_domain="$1"
    local mode="$2"
    local url="$3"
    local user="$4"
    local pass="$5"
    local status="$6"
    local meta_file="$AUTH_DATA_DIR/${clean_domain}.auth"

    cat > "$meta_file" <<EOF
MODE=${mode}
URL=${url}
AUTH_USER=${user}
AUTH_PASS=${pass}
STATUS=${status}
EOF
    chmod 600 "$meta_file"
}

remove_auth_meta(){
    local clean_domain="$1"
    rm -f "$AUTH_DATA_DIR/${clean_domain}.auth"
}

# =====================================================
# SHOW STATUS - Overview of all domains
# =====================================================
show_status(){
    clear
    echo ""
    echo "===================================================="
    echo "       PASSWORD PROTECTION STATUS"
    echo "===================================================="
    echo ""

    local found=0

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        local dn clean_d
        dn=$(read_domain_env "$d/config/domain.env" "DOMAIN")
        clean_d=$(read_domain_env "$d/config/domain.env" "CLEAN_DOMAIN")
        [ -z "$clean_d" ] && clean_d=$(clean_domain_name "$dn")
        [ -z "$dn" ] && continue

        if read_auth_meta "$clean_d"; then
            found=1
            if [ "$AUTH_STATUS" = "on" ]; then
                echo -e "  ${GREEN}● ON ${RESET} $dn"
            else
                echo -e "  ${YELLOW}○ OFF${RESET} $dn"
            fi

            if [ "$AUTH_MODE" = "url" ]; then
                echo -e "         Mode: Protect URL ${CYAN}${AUTH_URL}${RESET}"
            else
                echo -e "         Mode: ${BOLD}Full domain${RESET}"
            fi
            echo -e "         User: ${AUTH_USER}"
            echo ""
        else
            echo -e "  ${DIM}  ---  $dn (no protection)${RESET}"
        fi
    done

    if [ $found -eq 0 ]; then
        echo "  No password protection configured on any domain."
    fi
    echo ""
}

# =====================================================
# VIEW DETAILS for a specific domain
# =====================================================
view_details(){
    echo ""
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    local clean_d="$CLEAN_DOMAIN"

    echo ""
    echo "===================================================="
    echo "  Password Protection: $SELECTED_DOMAIN"
    echo "===================================================="
    echo ""

    if ! read_auth_meta "$clean_d"; then
        warn "No password protection configured for $SELECTED_DOMAIN"
        return
    fi

    if [ "$AUTH_STATUS" = "on" ]; then
        echo -e "  Status  : ${GREEN}${BOLD}ON${RESET}"
    else
        echo -e "  Status  : ${YELLOW}${BOLD}OFF${RESET}"
    fi

    if [ "$AUTH_MODE" = "url" ]; then
        echo -e "  Mode    : Protect URL"
        echo -e "  URL     : ${CYAN}${AUTH_URL}${RESET}"
    else
        echo -e "  Mode    : Full domain"
    fi

    echo -e "  Username: ${BOLD}${AUTH_USER}${RESET}"
    echo -e "  Password: ${BOLD}${AUTH_PASS}${RESET}"
    echo ""
}

# =====================================================
# ENABLE PROTECTION
# =====================================================
enable_protection(){
    init_auth || return

    echo ""
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    local clean_d="$CLEAN_DOMAIN"
    local domain_conf="/etc/nginx/conf.d/${clean_d}.conf"

    if [ ! -f "$domain_conf" ]; then
        fail "Nginx config not found: $domain_conf"
        return
    fi

    # Check if already has protection
    if read_auth_meta "$clean_d" && [ "$AUTH_STATUS" = "on" ]; then
        warn "Password protection is already ON for $SELECTED_DOMAIN"
        echo -e "  User: $AUTH_USER | Mode: $AUTH_MODE"
        read -p "  Disable first to reconfigure. Continue? (y/n): " c
        [[ "$c" =~ ^[yY]$ ]] || return
        disable_protection_for "$clean_d" "$domain_conf"
    fi

    echo ""
    echo "Protection mode:"
    echo "  1) Protect a specific URL (other URLs remain accessible)"
    echo "  2) Protect the entire domain"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " mode_choice

    local auth_mode=""
    local auth_url=""

    case "$mode_choice" in
        1)
            auth_mode="url"
            echo ""
            read -p "Enter the URL path to protect (e.g. /admin, /wp-login.php): " auth_url
            if [ -z "$auth_url" ]; then
                warn "URL cannot be empty"
                return
            fi
            # Ensure starts with /
            [[ "$auth_url" == /* ]] || auth_url="/$auth_url"
            ;;
        2)
            auth_mode="full"
            ;;
        0) return ;;
        *) warn "Invalid option"; return ;;
    esac

    echo ""
    read -p "Username: " auth_user
    if [ -z "$auth_user" ]; then
        warn "Username cannot be empty"
        return
    fi

    read -s -p "Password: " auth_pass
    echo ""
    if [ -z "$auth_pass" ]; then
        warn "Password cannot be empty"
        return
    fi

    read -s -p "Confirm password: " auth_pass2
    echo ""
    if [ "$auth_pass" != "$auth_pass2" ]; then
        fail "Passwords do not match"
        return
    fi

    # Create htpasswd file
    local htpasswd_file="$AUTH_DIR/${clean_d}.htpasswd"
    htpasswd -cb "$htpasswd_file" "$auth_user" "$auth_pass" 2>/dev/null
    chmod 640 "$htpasswd_file"
    chown root:nginx "$htpasswd_file" 2>/dev/null

    # Backup nginx config
    cp "$domain_conf" "${domain_conf}.auth.bak"

    # Inject auth directives into nginx config
    if [ "$auth_mode" = "full" ]; then
        inject_full_domain_auth "$domain_conf" "$htpasswd_file"
    else
        inject_url_auth "$domain_conf" "$htpasswd_file" "$auth_url"
    fi

    # Test nginx config
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        save_auth_meta "$clean_d" "$auth_mode" "$auth_url" "$auth_user" "$auth_pass" "on"
        echo ""
        ok "Password protection enabled for $SELECTED_DOMAIN"
        echo ""
        if [ "$auth_mode" = "url" ]; then
            echo -e "  Protected URL : ${CYAN}${auth_url}${RESET}"
        else
            echo -e "  Protection    : ${BOLD}Entire domain${RESET}"
        fi
        echo -e "  Username      : ${BOLD}${auth_user}${RESET}"
        echo -e "  Password      : ${BOLD}${auth_pass}${RESET}"
    else
        fail "Nginx config test failed! Rolling back..."
        mv "${domain_conf}.auth.bak" "$domain_conf"
        rm -f "$htpasswd_file"
        nginx -t 2>/dev/null && systemctl reload nginx
        fail "Password protection was NOT applied."
        echo ""
        echo "Nginx error details:"
        nginx -t 2>&1
    fi
}

# =====================================================
# INJECT AUTH INTO NGINX CONFIG
# =====================================================

inject_full_domain_auth(){
    local conf="$1"
    local htpasswd="$2"

    # Insert auth directives after the first 'server {' line,
    # before the first 'location' block
    sed -i "/^[[:space:]]*server[[:space:]]*{/,/location/ {
        /server[[:space:]]*{/ a\\
\\
    # >>> ShieldPress Auth Protection Start <<<\\
    auth_basic \"Restricted Access\";\\
    auth_basic_user_file ${htpasswd};\\
    # >>> ShieldPress Auth Protection End <<<
    }" "$conf"

    # Only inject once (in the first server block)
    # Remove duplicate injections if sed matched multiple times
    local count
    count=$(grep -c "ShieldPress Auth Protection Start" "$conf")
    if [ "$count" -gt 1 ]; then
        # Keep only the first occurrence, remove subsequent ones
        awk '
            /# >>> ShieldPress Auth Protection Start <<</ {
                if (seen) { skip=1; next }
                seen=1
            }
            /# >>> ShieldPress Auth Protection End <<</ {
                if (skip) { skip=0; next }
            }
            !skip { print }
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi
}

inject_url_auth(){
    local conf="$1"
    local htpasswd="$2"
    local url="$3"

    # Determine if url looks like a file (has extension) or a path
    local location_match
    if [[ "$url" == *.* ]]; then
        location_match="= $url"
    else
        location_match="$url"
    fi

    # Create temp file for the auth block
    local tmpblock
    tmpblock=$(mktemp /tmp/sp_auth_block_XXXXXX)

    # Detect PHP socket path from existing config
    local php_sock
    php_sock=$(grep -oP 'fastcgi_pass unix:\K[^;]+' "$conf" 2>/dev/null | head -1)

    if [ -n "$php_sock" ]; then
        # PHP app - use fastcgi
        cat > "$tmpblock" <<HEREDOC

    # >>> ShieldPress Auth Protection Start <<<
    location ${location_match} {
        auth_basic "Restricted Access";
        auth_basic_user_file ${htpasswd};
        try_files \$uri \$uri/ /index.php?\$query_string;

        location ~ \\.php\$ {
            include fastcgi_params;
            fastcgi_pass unix:${php_sock};
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        }
    }
    # >>> ShieldPress Auth Protection End <<<
HEREDOC
    else
        # Non-PHP app (Node.js proxy) - detect proxy_pass
        local proxy_target
        proxy_target=$(grep -oP 'proxy_pass\s+\K[^;]+' "$conf" 2>/dev/null | head -1)

        if [ -n "$proxy_target" ]; then
            cat > "$tmpblock" <<HEREDOC

    # >>> ShieldPress Auth Protection Start <<<
    location ${location_match} {
        auth_basic "Restricted Access";
        auth_basic_user_file ${htpasswd};
        proxy_pass ${proxy_target};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    # >>> ShieldPress Auth Protection End <<<
HEREDOC
        else
            # Fallback: simple auth without proxy/fastcgi
            cat > "$tmpblock" <<HEREDOC

    # >>> ShieldPress Auth Protection Start <<<
    location ${location_match} {
        auth_basic "Restricted Access";
        auth_basic_user_file ${htpasswd};
        try_files \$uri \$uri/ =404;
    }
    # >>> ShieldPress Auth Protection End <<<
HEREDOC
        fi
    fi

    # Insert the block before the last closing brace of the server block
    local last_brace_line
    last_brace_line=$(grep -n "^}" "$conf" | tail -1 | cut -d: -f1)

    if [ -z "$last_brace_line" ]; then
        fail "Could not find server block closing brace in config"
        rm -f "$tmpblock"
        return 1
    fi

    # Use awk for reliable multi-line insertion
    awk -v line="$last_brace_line" -v blockfile="$tmpblock" '
        NR == line {
            while ((getline blockline < blockfile) > 0) print blockline
            close(blockfile)
        }
        { print }
    ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"

    rm -f "$tmpblock"
}

# =====================================================
# DISABLE PROTECTION
# =====================================================
disable_protection(){
    echo ""
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    local clean_d="$CLEAN_DOMAIN"
    local domain_conf="/etc/nginx/conf.d/${clean_d}.conf"

    if ! read_auth_meta "$clean_d"; then
        warn "No password protection configured for $SELECTED_DOMAIN"
        return
    fi

    if [ "$AUTH_STATUS" != "on" ]; then
        warn "Password protection is already OFF for $SELECTED_DOMAIN"
        return
    fi

    read -p "Disable password protection for $SELECTED_DOMAIN? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    disable_protection_for "$clean_d" "$domain_conf"
}

disable_protection_for(){
    local clean_d="$1"
    local domain_conf="$2"

    # Backup
    cp "$domain_conf" "${domain_conf}.auth.bak"

    # Remove auth block (between markers)
    sed -i '/# >>> ShieldPress Auth Protection Start <<</,/# >>> ShieldPress Auth Protection End <<</d' "$domain_conf"

    # Clean up any resulting blank lines (max 2 consecutive)
    sed -i '/^$/N;/^\n$/d' "$domain_conf"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx

        # Remove htpasswd file
        rm -f "$AUTH_DIR/${clean_d}.htpasswd"

        # Remove metadata
        remove_auth_meta "$clean_d"

        ok "Password protection disabled for domain"
    else
        fail "Nginx config error after removal, rolling back..."
        mv "${domain_conf}.auth.bak" "$domain_conf"
        nginx -t 2>/dev/null && systemctl reload nginx
        fail "Could not disable protection safely"
    fi
}

# =====================================================
# TOGGLE ON/OFF (without removing config)
# =====================================================
toggle_protection(){
    echo ""
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    local clean_d="$CLEAN_DOMAIN"
    local domain_conf="/etc/nginx/conf.d/${clean_d}.conf"

    if ! read_auth_meta "$clean_d"; then
        warn "No password protection configured for $SELECTED_DOMAIN"
        return
    fi

    if [ "$AUTH_STATUS" = "on" ]; then
        echo "Current status: ON"
        read -p "Turn OFF password protection? (y/n): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || return

        # Backup
        cp "$domain_conf" "${domain_conf}.auth.bak"

        # Comment out auth directives (keep structure)
        sed -i '/# >>> ShieldPress Auth Protection Start <<</,/# >>> ShieldPress Auth Protection End <<</ {
            /# >>> ShieldPress Auth Protection/! s/^/# SP_AUTH_OFF# /
        }' "$domain_conf"

        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            save_auth_meta "$clean_d" "$AUTH_MODE" "$AUTH_URL" "$AUTH_USER" "$AUTH_PASS" "off"
            ok "Password protection turned OFF for $SELECTED_DOMAIN (config preserved)"
        else
            fail "Nginx error, rolling back..."
            mv "${domain_conf}.auth.bak" "$domain_conf"
            nginx -t 2>/dev/null && systemctl reload nginx
        fi
    else
        echo "Current status: OFF"
        read -p "Turn ON password protection? (y/n): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || return

        # Backup
        cp "$domain_conf" "${domain_conf}.auth.bak"

        # Uncomment auth directives
        sed -i 's/^# SP_AUTH_OFF# //' "$domain_conf"

        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            save_auth_meta "$clean_d" "$AUTH_MODE" "$AUTH_URL" "$AUTH_USER" "$AUTH_PASS" "on"
            ok "Password protection turned ON for $SELECTED_DOMAIN"
        else
            fail "Nginx error, rolling back..."
            mv "${domain_conf}.auth.bak" "$domain_conf"
            nginx -t 2>/dev/null && systemctl reload nginx
        fi
    fi
}

# =====================================================
# CHANGE USERNAME/PASSWORD
# =====================================================
change_credentials(){
    init_auth || return

    echo ""
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    local clean_d="$CLEAN_DOMAIN"

    if ! read_auth_meta "$clean_d"; then
        warn "No password protection configured for $SELECTED_DOMAIN"
        return
    fi

    echo ""
    echo "Current credentials:"
    echo -e "  Username: ${BOLD}${AUTH_USER}${RESET}"
    echo -e "  Password: ${BOLD}${AUTH_PASS}${RESET}"
    echo ""

    read -p "New username (Enter to keep '$AUTH_USER'): " new_user
    [ -z "$new_user" ] && new_user="$AUTH_USER"

    read -s -p "New password: " new_pass
    echo ""
    if [ -z "$new_pass" ]; then
        warn "Password cannot be empty"
        return
    fi

    read -s -p "Confirm password: " new_pass2
    echo ""
    if [ "$new_pass" != "$new_pass2" ]; then
        fail "Passwords do not match"
        return
    fi

    # Update htpasswd
    local htpasswd_file="$AUTH_DIR/${clean_d}.htpasswd"
    htpasswd -cb "$htpasswd_file" "$new_user" "$new_pass" 2>/dev/null
    chmod 640 "$htpasswd_file"
    chown root:nginx "$htpasswd_file" 2>/dev/null

    # Update metadata
    save_auth_meta "$clean_d" "$AUTH_MODE" "$AUTH_URL" "$new_user" "$new_pass" "$AUTH_STATUS"

    ok "Credentials updated for $SELECTED_DOMAIN"
    echo -e "  Username: ${BOLD}${new_user}${RESET}"
    echo -e "  Password: ${BOLD}${new_pass}${RESET}"
}

# =====================================================
# MENU
# =====================================================
while true; do
    clear
    sp_header "Password Protection" "Nginx Basic Auth"
    sp_menu_grid \
        "1|Overview Status|cyan" \
        "2|View Domain Details|blue" \
        "3|Enable Protection|green" \
        "4|Disable Protection|red" \
        "5|Toggle ON/OFF|yellow" \
        "6|Change Credentials|magenta" \
        "0|Back|white"
    sp_prompt choice

    case "$choice" in
        1) show_status ;;
        2) view_details ;;
        3) enable_protection ;;
        4) disable_protection ;;
        5) toggle_protection ;;
        6) change_credentials ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    echo ""
    read -p "Press Enter..."
done
