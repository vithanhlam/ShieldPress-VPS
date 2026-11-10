#!/bin/bash
# =====================================================
# ShieldPress Core - Quick Commands
# Single source for the quick-command list shown by
# "shieldpress --help" and by the SSH login banner.
# =====================================================

# Entries: "command|description|ANSI color code"
SP_QUICK_COMMANDS=(
    "shieldpress menu (1)|Admin Menu|36"
    "shieldpress update (2)|Update|33"
    "shieldpress cache (3)|Clear All Cache|35"
    "shieldpress domain (4)|Add Domain|32"
    "shieldpress ssl (5)|Install SSL|34"
    "shieldpress backup (6)|Backup|36"
    "shieldpress github|GitHub read-only deployment|36"
    "shieldpress autoupdate|Auto-Update (on/off, schedule)|33"
)

# Print the command table. Usage: sp_quick_commands_print
sp_quick_commands_print(){
    local entry cmd rest desc color
    for entry in "${SP_QUICK_COMMANDS[@]}"; do
        cmd="${entry%%|*}"
        rest="${entry#*|}"
        desc="${rest%%|*}"
        color="${rest##*|}"
        printf '  \e[%sm%-24s\e[0m %s\n' "$color" "$cmd" "$desc"
    done
}

# Short Auto-Update summary for banners, e.g. "ON - daily at 03:00" or "OFF".
sp_quick_commands_autoupdate_label(){
    local conf="${ETC_DIR:-/etc/shieldpress}/autoupdate.conf" lib="${BASE_DIR:-/opt/shieldpress}/core/autoupdate.sh"
    if [ -f "$lib" ] && [ -f "$conf" ]; then
        # shellcheck disable=SC1090
        source "$lib" && au_load && au_describe_short
    else
        echo "OFF"
    fi
}

# Full login banner. Runs in a subshell from /etc/profile.d/shieldpress.sh.
sp_quick_commands_login_banner(){
    local base="${BASE_DIR:-/opt/shieldpress}" ver="unknown" remote url line
    line=$'\e[36m──────────────────────────────────────\e[0m'
    [ -f "$base/version.txt" ] && ver=$(tr -d '[:space:]' < "$base/version.txt")

    echo ""
    echo -e "\e[1m\e[97mShieldPress VPS v${ver} - Quick Commands\e[0m"
    echo "$line"
    sp_quick_commands_print
    echo "$line"
    echo -e "  \e[2mAuto-Update: $(sp_quick_commands_autoupdate_label)\e[0m"

    if command -v curl >/dev/null 2>&1; then
        url="https://raw.githubusercontent.com/vithanhlam/ShieldPress-VPS/main/shieldpress/version.txt"
        [ -f /etc/shieldpress/update.conf ] && . /etc/shieldpress/update.conf 2>/dev/null
        [ -n "${SHIELDPRESS_VERSION_URL:-}" ] && url="$SHIELDPRESS_VERSION_URL"
        remote=$(curl -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$remote" ] && [ "$remote" != "$ver" ]; then
            echo "$line"
            echo -e "  \e[1m\e[33m⚡ Update available: v${remote} (installed: v${ver})\e[0m"
            echo -e "  \e[2mRun: shieldpress update\e[0m"
        fi
    fi
    echo "$line"
    echo -e "  \e[2mType 'shieldpress <command>' for quick access (e.g. shieldpress update)\e[0m"
    echo -e "  \e[2mType 'shieldpress' for full dashboard\e[0m"
    echo ""
}

# Install the thin SSH login hook. The text itself lives in this file, so an
# update only has to replace the source tree to change the banner.
sp_install_login_banner(){
    local target="/etc/profile.d/shieldpress.sh"
    cat > "$target" <<'PROFILE_EOF' || return 1
# ShieldPress VPS - show quick commands on root SSH login.
if [ -z "$SHIELDPRESS_HELP_SHOWN" ] && [ -t 1 ] && [ "$(id -u)" -eq 0 ] && command -v shieldpress >/dev/null 2>&1; then
    export SHIELDPRESS_HELP_SHOWN=1
    if [ -f /opt/shieldpress/core/quick-commands.sh ]; then
        ( . /opt/shieldpress/core/quick-commands.sh && sp_quick_commands_login_banner )
    fi
fi
PROFILE_EOF
    chmod 644 "$target" || return 1
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$target" 2>/dev/null || true
    fi
}
