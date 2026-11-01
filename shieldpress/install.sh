#!/bin/bash

BASE_DIR="/opt/shieldpress"

echo "========================================="
echo "        Setting up ShieldPress VPS"
echo "========================================="

# Auto escalate to root
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Not running as root. Trying sudo..."
    exec sudo bash "$0" "$@"
    exit $?
fi

# Check main file exists
if [ ! -f "$BASE_DIR/shieldpress.sh" ]; then
    echo "shieldpress.sh not found in $BASE_DIR"
    exit 1
fi

# Normalize ownership and permissions after copying the source.  This matters
# when the installer ran from an archive created by a non-root user: preserving
# that archive's UID/GID could make root-executed code writable by another user.
chown -R root:root "$BASE_DIR"
find "$BASE_DIR" -type d -exec chmod 755 {} +
find "$BASE_DIR" -type f -name '*.sh' -exec chmod 755 {} +
find "$BASE_DIR" -type f ! -name '*.sh' -exec chmod 644 {} +

chmod 755 "$BASE_DIR/bin/laravel-pg-backup" "$BASE_DIR/bin/shieldpress-autoupdate"

# Create global command
ln -sf "$BASE_DIR/shieldpress.sh" /usr/bin/shieldpress

# Keep the shell shortcut for opening the admin menu. It only opens the UI.
for shortcut in /usr/bin/1 /usr/local/bin/1; do
    cat > "$shortcut" <<'SHORTCUT_EOF'
#!/bin/bash
exec /opt/shieldpress/shieldpress.sh menu "$@"
SHORTCUT_EOF
    chmod 755 "$shortcut"
done
restorecon /usr/bin/1 /usr/local/bin/1 2>/dev/null || true
restorecon -RF "$BASE_DIR" 2>/dev/null || true

# Install the numeric shortcuts: 2 update, 3 cache, 4 domain, 5 ssl, 6 backup.
source "$BASE_DIR/core/update-shortcut.sh" || exit 1
sp_install_update_shortcut || { echo "[ERROR] Cannot install numeric shortcuts"; exit 1; }

# Show the quick-command guide on interactive VPS login (no auto-launch dashboard).
source "$BASE_DIR/core/quick-commands.sh" || exit 1
sp_install_login_banner || { echo "[ERROR] Cannot install login banner"; exit 1; }

# Restore the Auto-Update schedule when it is enabled (settings live in /etc/shieldpress).
source "$BASE_DIR/core/autoupdate.sh" && au_load && au_apply || echo "[WARN] Cannot restore the Auto-Update schedule"
chmod 755 "$BASE_DIR/bin/shieldpress-autoupdate"

# Reload shell command cache
hash -r 2>/dev/null || true

# Ensure basic folders
mkdir -p /home/domains
chmod 755 /home
chmod 755 /home/domains

echo "-----------------------------------------"
echo "ShieldPress VPS Ready!"
echo "Run: shieldpress"
echo "Quick commands help shown on login"
echo "-----------------------------------------"
