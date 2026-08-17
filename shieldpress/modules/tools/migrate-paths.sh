#!/bin/bash
# =====================================================
# ShieldPress - Path Migration Tool
# Migrates logs, data, backups from /opt/shieldpress
# to their new locations:
#   logs  → /var/shieldpress/logs
#   data  → /var/shieldpress/data
#   backups-global → /home/backup-all
#   per-domain nginx logs → /home/domains/{domain}/logs
#
# Safe to run multiple times (idempotent).
# Creates backward-compatible symlinks.
# =====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $1"; }

echo ""
echo "===================================================="
echo "       ShieldPress Path Migration"
echo "===================================================="
echo ""
echo "This will reorganize ShieldPress directories:"
echo ""
echo "  OLD                              →  NEW"
echo "  /opt/shieldpress/logs/           →  /var/shieldpress/logs/"
echo "  /opt/shieldpress/data/           →  /var/shieldpress/data/"
echo "  /opt/shieldpress/backups-global/ →  /home/backup-all/"
echo "  /var/log/nginx/domains/{domain}/ →  /home/domains/{domain}/logs/"
echo ""
echo "Backward-compatible symlinks will be created."
echo ""
read -p "Continue? (y/n): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; exit 0; }

echo ""
info "Step 1/5: Creating new directory structure..."
ensure_shieldpress_dirs
ok "Directory structure created"

echo ""
info "Step 2/5: Migrating logs & data with backward-compat symlinks..."
create_compat_symlinks
ok "Logs & data migrated with symlinks"

echo ""
info "Step 3/5: Migrating per-domain nginx logs..."

MIGRATED_DOMAINS=0
for DPATH in "$DOMAINS_ROOT"/*/; do
    [ -d "$DPATH" ] || continue
    [ -f "$DPATH/config/domain.env" ] || continue

    CLEAN=$(basename "$DPATH")
    DOMAIN_NAME=$(grep "^DOMAIN=" "$DPATH/config/domain.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    [ -z "$DOMAIN_NAME" ] && continue

    # Create per-domain logs directory
    DOMAIN_LOG_DIR="$DPATH/logs"
    mkdir -p "$DOMAIN_LOG_DIR" 2>/dev/null

    # Migrate nginx domain logs from /var/log/nginx/domains/{domain}/
    OLD_NGINX_LOG="/var/log/nginx/domains/$CLEAN"
    if [ -d "$OLD_NGINX_LOG" ] && [ ! -L "$OLD_NGINX_LOG" ]; then
        # Copy existing logs
        cp -a "$OLD_NGINX_LOG"/. "$DOMAIN_LOG_DIR"/ 2>/dev/null
        rm -rf "$OLD_NGINX_LOG"
        # Create symlink for backward compat
        ln -sfn "$DOMAIN_LOG_DIR" "$OLD_NGINX_LOG"
        ok "  $DOMAIN_NAME → $DOMAIN_LOG_DIR"
    elif [ ! -d "$OLD_NGINX_LOG" ]; then
        # No old logs, just ensure new dir and create symlink
        mkdir -p "$(dirname "$OLD_NGINX_LOG")" 2>/dev/null
        ln -sfn "$DOMAIN_LOG_DIR" "$OLD_NGINX_LOG"
        ok "  $DOMAIN_NAME (new)"
    else
        info "  $DOMAIN_NAME (already migrated)"
    fi

    # Set ownership to domain system user
    SUSER=$(grep "^SYSTEM_USER=" "$DPATH/config/domain.env" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    [ -n "$SUSER" ] && chown "$SUSER:$SUSER" "$DOMAIN_LOG_DIR" 2>/dev/null
    # nginx needs write access
    chown nginx:nginx "$DOMAIN_LOG_DIR"/*.log 2>/dev/null

    ((MIGRATED_DOMAINS++))
done

ok "$MIGRATED_DOMAINS domains processed"

echo ""
info "Step 4/5: Updating nginx configs to use new log paths..."

UPDATED_CONFIGS=0
for CONF in /etc/nginx/conf.d/*.conf; do
    [ -f "$CONF" ] || continue
    [[ "$(basename "$CONF")" == shieldpress-* ]] && continue
    [[ "$(basename "$CONF")" == cache-zone-* ]] && continue
    [[ "$(basename "$CONF")" == 000-* ]] && continue

    CLEAN=$(basename "$CONF" .conf)
    DPATH="$DOMAINS_ROOT/$CLEAN"
    [ -d "$DPATH" ] || continue

    DOMAIN_LOG_DIR="$DPATH/logs"

    # Check if config references old log path
    if grep -q "/var/log/nginx/domains/$CLEAN" "$CONF" 2>/dev/null; then
        cp "$CONF" "${CONF}.logmigrate.bak"
        sed -i "s|/var/log/nginx/domains/$CLEAN|$DOMAIN_LOG_DIR|g" "$CONF"
        ((UPDATED_CONFIGS++))
    fi
done

if [ $UPDATED_CONFIGS -gt 0 ]; then
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null
        ok "$UPDATED_CONFIGS nginx configs updated & reloaded"
    else
        fail "Nginx test failed after config update. Rolling back..."
        for BAK in /etc/nginx/conf.d/*.logmigrate.bak; do
            [ -f "$BAK" ] || continue
            ORIG="${BAK%.logmigrate.bak}"
            mv "$BAK" "$ORIG"
        done
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
        fail "Rollback complete. Nginx log path migration was NOT applied."
    fi
    # Cleanup backup files on success
    rm -f /etc/nginx/conf.d/*.logmigrate.bak 2>/dev/null
else
    ok "Nginx configs already up-to-date (or using symlinks)"
fi

echo ""
info "Step 5/5: Verifying..."

ERRORS=0
[ -d "$LOG_DIR" ]             || { fail "/var/shieldpress/logs missing"; ((ERRORS++)); }
[ -d "$DATA_DIR" ]            || { fail "/var/shieldpress/data missing"; ((ERRORS++)); }
[ -d "$BACKUP_GLOBAL_DIR" ]   || { fail "/home/backup-all missing"; ((ERRORS++)); }
[ -L "$BASE_DIR/logs" ]       || warn "/opt/shieldpress/logs symlink not created (may already be clean)"
[ -L "$BASE_DIR/data" ]       || warn "/opt/shieldpress/data symlink not created (may already be clean)"

if [ $ERRORS -eq 0 ]; then
    echo ""
    ok "Migration completed successfully!"
    echo ""
    echo "  New structure:"
    echo "  ├── /var/shieldpress/logs/      ← All ShieldPress logs"
    echo "  ├── /var/shieldpress/data/      ← Runtime data"
    echo "  ├── /home/backup-all/           ← Global backups"
    echo "  ├── /home/domains/*/logs/       ← Per-domain nginx logs"
    echo "  └── /opt/shieldpress/           ← Source code only"
    echo ""
    echo "  Symlinks for backward compatibility:"
    echo "  ├── /opt/shieldpress/logs → /var/shieldpress/logs"
    echo "  ├── /opt/shieldpress/data → /var/shieldpress/data"
    echo "  └── /var/log/nginx/domains/{d} → /home/domains/{d}/logs"
else
    fail "Migration completed with $ERRORS errors. Review above."
fi
