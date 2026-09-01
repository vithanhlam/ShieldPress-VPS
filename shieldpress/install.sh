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

# Create global command
ln -sf "$BASE_DIR/shieldpress.sh" /usr/bin/shieldpress

# Create numeric shortcut scripts in /usr/bin/
declare -A SHORTCUTS=(
    [1]="menu"
    [2]="update"
    [3]="cache"
    [4]="domain"
    [5]="ssl"
    [6]="backup"
)

for NUM in "${!SHORTCUTS[@]}"; do
    cat > "/usr/bin/$NUM" <<SHORTCUT_EOF
#!/bin/bash
exec shieldpress ${SHORTCUTS[$NUM]}
SHORTCUT_EOF
    chmod +x "/usr/bin/$NUM"
done

# Show help guide on interactive VPS login (no auto-launch dashboard).
cat > /etc/profile.d/shieldpress.sh <<'PROFILE_EOF'
# ShieldPress VPS - show quick commands on root SSH login.
if [ -z "$SHIELDPRESS_HELP_SHOWN" ] && [ -t 1 ] && [ "$(id -u)" -eq 0 ] && command -v shieldpress >/dev/null 2>&1; then
    export SHIELDPRESS_HELP_SHOWN=1

    # Read current version
    _SP_VER="unknown"
    [ -f /opt/shieldpress/version.txt ] && _SP_VER=$(tr -d '[:space:]' < /opt/shieldpress/version.txt)

    echo ""
    echo -e "\e[1m\e[97mShieldPress VPS v${_SP_VER} - Quick Commands\e[0m"
    echo -e "\e[36m──────────────────────────────────────\e[0m"
    echo -e "  \e[36m[ 1]\e[0m Admin Menu              \e[33m[ 2]\e[0m Update"
    echo -e "  \e[35m[ 3]\e[0m Clear All Cache         \e[32m[ 4]\e[0m Add Domain"
    echo -e "  \e[34m[ 5]\e[0m Install SSL             \e[36m[ 6]\e[0m Backup"
    echo -e "\e[36m──────────────────────────────────────\e[0m"

    # Check for update (quick, 3s timeout)
    if command -v curl >/dev/null 2>&1; then
        _SP_VERSION_URL="https://raw.githubusercontent.com/vithanhlam/ShieldPress-VPS/main/shieldpress/version.txt"
        [ -f /etc/shieldpress/update.conf ] && . /etc/shieldpress/update.conf 2>/dev/null
        [ -n "$SHIELDPRESS_VERSION_URL" ] && _SP_VERSION_URL="$SHIELDPRESS_VERSION_URL"
        _SP_REMOTE=$(curl -fsSL --connect-timeout 3 --max-time 5 "$_SP_VERSION_URL" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$_SP_REMOTE" ] && [ "$_SP_REMOTE" != "$_SP_VER" ]; then
            echo -e "  \e[1m\e[33m⚡ Update available: v${_SP_REMOTE} (installed: v${_SP_VER})\e[0m"
            echo -e "  \e[2mRun: shieldpress update\e[0m"
            echo -e "\e[36m──────────────────────────────────────\e[0m"
        fi
    fi

    echo -e "  \e[2mType a number anytime for quick access\e[0m"
    echo -e "  \e[2mType 'shieldpress' for full dashboard\e[0m"
    echo ""

    unset _SP_VER _SP_REMOTE _SP_VERSION_URL
fi
PROFILE_EOF
chmod 644 /etc/profile.d/shieldpress.sh

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
