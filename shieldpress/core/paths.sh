#!/bin/bash
# =====================================================
# ShieldPress Core - Centralized Path Definitions
# Source this file in every module for consistent paths.
# ALL runtime data lives OUTSIDE /opt/shieldpress.
# /opt/shieldpress contains ONLY source code.
# =====================================================

# --- Source Code (read-only at runtime) ---
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"

# --- Runtime Data ---
VAR_DIR="${VAR_DIR:-/var/shieldpress}"
LOG_DIR="${LOG_DIR:-$VAR_DIR/logs}"
DATA_DIR="${DATA_DIR:-$VAR_DIR/data}"

# --- Per-Domain ---
DOMAINS_ROOT="${DOMAINS_ROOT:-/home/domains}"

# --- Global Backups ---
BACKUP_GLOBAL_DIR="${BACKUP_GLOBAL_DIR:-/home/backup-all}"

# --- Config (secrets, keys - outside source) ---
ETC_DIR="${ETC_DIR:-/etc/shieldpress}"

# --- Sub-directories under LOG_DIR ---
LOG_DIR_PHP_SLOW="$LOG_DIR/php-slow"
LOG_DIR_MALWARE="$LOG_DIR/malware"

# --- Sub-directories under DATA_DIR ---
DATA_DIR_AUTH="$DATA_DIR/auth"
DATA_DIR_LARAVEL_DB="$DATA_DIR/laravel-databases"
DATA_DIR_TMP_BACKUPS="$DATA_DIR/tmp-backups"

# --- Nginx ---
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_AUTH_DIR="/etc/nginx/auth"

# --- Per-Domain Path Helpers ---
# Usage: domain_log_dir "example_com" → /home/domains/example_com/logs
domain_log_dir(){
    echo "$DOMAINS_ROOT/$1/logs"
}

# Usage: domain_backup_dir "example_com" → /home/domains/example_com/backup
domain_backup_dir(){
    echo "$DOMAINS_ROOT/$1/backup"
}

# Usage: global_backup_dir "example_com" → /home/backup-all/example_com
global_backup_dir(){
    echo "$BACKUP_GLOBAL_DIR/$1"
}

# =====================================================
# ENSURE DIRECTORIES EXIST (called once at startup
# or by migrate-paths.sh)
# =====================================================
ensure_shieldpress_dirs(){
    mkdir -p "$LOG_DIR" "$LOG_DIR_PHP_SLOW" "$LOG_DIR_MALWARE" \
             "$DATA_DIR" "$DATA_DIR_AUTH" "$DATA_DIR_LARAVEL_DB" "$DATA_DIR_TMP_BACKUPS" \
             "$BACKUP_GLOBAL_DIR" \
             "$ETC_DIR" 2>/dev/null

    # Set ownership so nginx/php can write logs
    chown root:root "$VAR_DIR" 2>/dev/null
    chmod 755 "$VAR_DIR" "$LOG_DIR" "$DATA_DIR" 2>/dev/null
}

# =====================================================
# BACKWARD COMPATIBILITY SYMLINKS
# Create symlinks from old locations → new locations
# so that un-updated scripts or cron jobs still work.
# =====================================================
create_compat_symlinks(){
    local old_log="$BASE_DIR/logs"
    local old_data="$BASE_DIR/data"
    local old_backup_global="$BASE_DIR/backups-global"

    # /opt/shieldpress/logs → /var/shieldpress/logs
    if [ -d "$old_log" ] && [ ! -L "$old_log" ]; then
        cp -a "$old_log"/. "$LOG_DIR"/ 2>/dev/null || true
        rm -rf "$old_log"
    fi
    [ -L "$old_log" ] || [ -e "$old_log" ] || ln -sfn "$LOG_DIR" "$old_log" 2>/dev/null || true

    # /opt/shieldpress/data → /var/shieldpress/data
    if [ -d "$old_data" ] && [ ! -L "$old_data" ]; then
        cp -a "$old_data"/. "$DATA_DIR"/ 2>/dev/null || true
        rm -rf "$old_data"
    fi
    [ -L "$old_data" ] || [ -e "$old_data" ] || ln -sfn "$DATA_DIR" "$old_data" 2>/dev/null || true

    # /opt/shieldpress/backups-global → /home/backup-all
    if [ -d "$old_backup_global" ] && [ ! -L "$old_backup_global" ]; then
        cp -a "$old_backup_global"/. "$BACKUP_GLOBAL_DIR"/ 2>/dev/null || true
        rm -rf "$old_backup_global"
    fi
    [ -L "$old_backup_global" ] || [ -e "$old_backup_global" ] || ln -sfn "$BACKUP_GLOBAL_DIR" "$old_backup_global" 2>/dev/null || true

    return 0
}
