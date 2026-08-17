#!/bin/bash
# =====================================================
# ShieldPress Core - Shared Helpers
# Source this file for common domain/config operations.
# Provides a single, canonical implementation to avoid
# duplication across modules.
# =====================================================

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/paths.sh"

# =====================================================
# DOMAIN NAME HELPERS
# =====================================================

# Convert domain to clean folder/user name
# example.com → example_com (truncated to 30 chars)
clean_domain_name(){
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30
}

# Get domain path from domain name
domain_to_path(){
    local clean
    clean=$(clean_domain_name "$1")
    echo "$DOMAINS_ROOT/$clean"
}

# Get nginx config path from domain name
domain_to_nginx_conf(){
    local clean
    clean=$(clean_domain_name "$1")
    echo "/etc/nginx/conf.d/${clean}.conf"
}

# Get PHP version short form (8.4 → 84)
php_version_to_short(){
    echo "$1" | tr -d '.'
}

# =====================================================
# DOMAIN ENV READER (safe grep, never source)
# =====================================================

# Read a single value from domain.env
# Usage: env_val=$(read_domain_env "/path/to/domain.env" "DB_NAME")
read_domain_env(){
    local env_file="$1"
    local key="$2"
    [ -f "$env_file" ] || return 1
    grep "^${key}=" "$env_file" | cut -d'=' -f2- | tr -d '[:space:]'
}

# Load all standard domain variables from domain.env into shell vars.
# Usage: load_domain_env "/home/domains/example_com"
# Sets: DOMAIN, SYSTEM_USER, DB_NAME, DB_USER, DB_PASS, DB_CONNECTION,
#       APP_TYPE, ROOT, PHP_VERSION, SSL, CLEAN_DOMAIN, PHP_SHORT
load_domain_env(){
    local DPATH="$1"
    local ENV="$DPATH/config/domain.env"
    [ -f "$ENV" ] || return 1

    DOMAIN_PATH="$DPATH"
    DOMAIN=$(read_domain_env "$ENV" "DOMAIN")
    SYSTEM_USER=$(read_domain_env "$ENV" "SYSTEM_USER")
    DB_NAME=$(read_domain_env "$ENV" "DB_NAME")
    DB_USER=$(read_domain_env "$ENV" "DB_USER")
    DB_PASS=$(read_domain_env "$ENV" "DB_PASS")
    DB_CONNECTION=$(read_domain_env "$ENV" "DB_CONNECTION")
    APP_TYPE=$(read_domain_env "$ENV" "APP_TYPE")
    ROOT=$(read_domain_env "$ENV" "ROOT")
    PHP_VERSION=$(read_domain_env "$ENV" "PHP_VERSION")
    SSL=$(read_domain_env "$ENV" "SSL")
    CLEAN_DOMAIN=$(read_domain_env "$ENV" "CLEAN_DOMAIN")

    # Defaults
    DB_CONNECTION="${DB_CONNECTION:-mysql}"
    APP_TYPE="${APP_TYPE:-wordpress}"
    ROOT="${ROOT:-$DPATH/public_html}"
    CLEAN_DOMAIN="${CLEAN_DOMAIN:-$(clean_domain_name "$DOMAIN")}"
    PHP_SHORT=$(php_version_to_short "$PHP_VERSION")
}

# =====================================================
# DOMAIN SELECTOR (interactive)
# =====================================================

# Prompt user to select a domain from the list.
# Sets same variables as load_domain_env plus SELECTED_DOMAIN.
# Returns 1 if no domain selected or no domains found.
select_domain_interactive(){
    local _PATHS=()
    local _NAMES=()

    echo ""
    echo "Available Domains:"
    echo "--------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN
        DN=$(read_domain_env "$d/config/domain.env" "DOMAIN")
        [ -z "$DN" ] && continue
        echo "$i) $DN"
        _PATHS[$i]="$d"
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No domains found."; return 1; }

    echo "--------------------------------"
    read -p "Select domain number: " choice

    local selected_path="${_PATHS[$choice]}"
    [ -z "$selected_path" ] && { echo "Invalid selection"; return 1; }

    load_domain_env "$selected_path"
    SELECTED_DOMAIN="$DOMAIN"
    return 0
}

# =====================================================
# DOMAIN ITERATOR (non-interactive)
# =====================================================

# List all domain paths (one per line). Useful for loops:
#   list_domain_paths | while read -r dpath; do ... done
list_domain_paths(){
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        echo "$d"
    done
}

# List all domain names (one per line)
list_domain_names(){
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        read_domain_env "$d/config/domain.env" "DOMAIN"
    done
}

# =====================================================
# SAFE ENV WRITER
# =====================================================

# Update a key=value in a .env file (or append if missing)
# Usage: set_env_value "/path/to/file.env" "KEY" "value"
set_env_value(){
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# =====================================================
# MYSQL SAFE CONNECT
# =====================================================

# Create a temporary MySQL defaults file for safe password handling.
# Returns the temp file path. Caller must rm -f it when done.
# Usage:
#   MYCNF=$(mysql_defaults_file "$DB_USER" "$DB_PASS")
#   mysql --defaults-extra-file="$MYCNF" "$DB_NAME" < dump.sql
#   rm -f "$MYCNF"
mysql_defaults_file(){
    local user="$1"
    local pass="$2"
    local cnf
    cnf=$(mktemp /tmp/shieldpress_mycnf_XXXXXX)
    # chmod trước khi ghi để đóng cửa sổ race giữa tạo file và secure permissions
    chmod 600 "$cnf"
    # Dùng printf thay heredoc — tránh subshell expansion không mong muốn
    printf '[client]\nuser=%s\npassword=%s\n' "$user" "$pass" > "$cnf"
    echo "$cnf"
}

# =====================================================
# MISC UTILITIES
# =====================================================

# Check if a command exists
command_exists(){
    command -v "$1" >/dev/null 2>&1
}

# Get server public IP (with timeout)
get_server_ip(){
    curl -s --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 3 --max-time 5 api.ipify.org 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

# Safe pause (wait for Enter)
sp_pause(){
    echo ""
    read -p "Press Enter..."
}

# =====================================================
# WORDPRESS CACHE PURGE (silent, per-domain)
# =====================================================

# Purge all cache layers for a WordPress domain.
# Expects these vars to be set: DOMAIN_PATH, DOMAIN, PHP_VERSION, SYSTEM_USER
# Optional: CLEAN_DOMAIN (auto-derived if missing)
# Usage: purge_wp_cache
purge_wp_cache(){
    local _root="${ROOT:-$DOMAIN_PATH/public_html}"
    local _clean="${CLEAN_DOMAIN:-$(clean_domain_name "$DOMAIN")}"
    local _php_short=$(php_version_to_short "$PHP_VERSION")
    local _php_bin="/opt/remi/php${_php_short}/root/usr/bin/php"
    local _wp_cmd="sudo -u $SYSTEM_USER $_php_bin /usr/local/bin/wp"
    local _svc="php${_php_short}-php-fpm"

    [ -f "$_root/wp-config.php" ] || return 0

    echo ""
    echo "Clearing cache for $DOMAIN..."

    # 1. FastCGI cache
    local _cache_dir="/var/cache/nginx/${_clean}"
    if [ -d "$_cache_dir" ]; then
        find "$_cache_dir" -type f -delete 2>/dev/null
        echo "  [OK] FastCGI cache cleared"
    fi

    # 2. Valkey/Redis object cache
    if valkey-cli ping >/dev/null 2>&1 && [ -x "$_php_bin" ]; then
        $_wp_cmd redis flush --path="$_root" 2>/dev/null && echo "  [OK] Valkey object cache flushed" || true
    fi

    # 3. WP object cache
    if [ -x "$_php_bin" ]; then
        $_wp_cmd cache flush --path="$_root" 2>/dev/null && echo "  [OK] WP object cache flushed" || true
    fi

    # 4. OPcache - reload PHP-FPM
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
        systemctl reload "$_svc" 2>/dev/null && echo "  [OK] OPcache cleared (PHP-FPM reloaded)"
    fi
}
