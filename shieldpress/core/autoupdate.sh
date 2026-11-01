#!/bin/bash
# =====================================================
# ShieldPress Core - Auto-Update settings
# Shared by the Auto-Update menu, the "shieldpress
# autoupdate" command and the scheduled runner.
#
# Settings live in /etc/shieldpress/autoupdate.conf and the
# schedule in /etc/cron.d/shieldpress-autoupdate, both outside
# /opt/shieldpress, so they survive every update.
# Auto-Update is OFF until an administrator enables it.
# =====================================================

AU_BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
AU_ETC_DIR="${ETC_DIR:-/etc/shieldpress}"
AU_CONF="$AU_ETC_DIR/autoupdate.conf"
AU_CRON_FILE="/etc/cron.d/shieldpress-autoupdate"
AU_RUNNER="$AU_BASE_DIR/bin/shieldpress-autoupdate"
AU_STATUS_FILE="${DATA_DIR:-/var/shieldpress/data}/autoupdate.status"
AU_WEEKDAY_NAMES=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

AU_ENABLED=0
AU_FREQUENCY="daily"
AU_TIME="03:00"
AU_WEEKDAY=1
AU_MONTHDAY=1
AU_DELAY_HOURS=0

# Read one KEY from the config without executing the file.
au_conf_get(){
    [ -f "$AU_CONF" ] || return 1
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$AU_CONF" | tail -1
}

# Normalize "3:5", "03:05" or "3.05" to HH:MM. Returns 1 when invalid.
au_normalize_time(){
    local raw="${1//[[:space:]]/}" h m
    raw="${raw/./:}"
    [[ "$raw" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]] || return 1
    h=$((10#${BASH_REMATCH[1]})); m=$((10#${BASH_REMATCH[2]}))
    [ "$h" -le 23 ] && [ "$m" -le 59 ] || return 1
    printf '%02d:%02d\n' "$h" "$m"
}

# Load settings, falling back to safe defaults for missing or invalid values.
au_load(){
    local v
    AU_ENABLED=0; AU_FREQUENCY="daily"; AU_TIME="03:00"; AU_WEEKDAY=1; AU_MONTHDAY=1; AU_DELAY_HOURS=0

    v=$(au_conf_get AUTO_UPDATE_ENABLED || true);   [ "$v" = "1" ] && AU_ENABLED=1
    v=$(au_conf_get AUTO_UPDATE_FREQUENCY || true); case "$v" in daily|weekly|monthly) AU_FREQUENCY="$v" ;; esac
    v=$(au_conf_get AUTO_UPDATE_TIME || true);      v=$(au_normalize_time "$v" 2>/dev/null) && AU_TIME="$v"
    v=$(au_conf_get AUTO_UPDATE_WEEKDAY || true);   [[ "$v" =~ ^[0-6]$ ]] && AU_WEEKDAY="$v"
    v=$(au_conf_get AUTO_UPDATE_MONTHDAY || true);  [[ "$v" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] && AU_MONTHDAY="$v"
    v=$(au_conf_get AUTO_UPDATE_DELAY_HOURS || true); [[ "$v" =~ ^([0-9]|[1-9][0-9]{1,2})$ ]] && [ "$v" -le 720 ] && AU_DELAY_HOURS="$v"
    return 0
}

au_save(){
    mkdir -p "$AU_ETC_DIR" || return 1
    local tmp
    tmp=$(mktemp "$AU_ETC_DIR/.autoupdate.XXXXXX") || return 1
    cat > "$tmp" <<EOF
# ShieldPress VPS Auto-Update settings. Change them with: shieldpress autoupdate
AUTO_UPDATE_ENABLED="$AU_ENABLED"
AUTO_UPDATE_FREQUENCY="$AU_FREQUENCY"
AUTO_UPDATE_TIME="$AU_TIME"
AUTO_UPDATE_WEEKDAY="$AU_WEEKDAY"
AUTO_UPDATE_MONTHDAY="$AU_MONTHDAY"
AUTO_UPDATE_DELAY_HOURS="$AU_DELAY_HOURS"
EOF
    chmod 600 "$tmp" && mv -f "$tmp" "$AU_CONF"
}

# "daily at 03:00" / "every Monday at 03:00" / "monthly on day 1 at 03:00"
au_describe(){
    case "$AU_FREQUENCY" in
        weekly)  echo "every ${AU_WEEKDAY_NAMES[$AU_WEEKDAY]} at $AU_TIME" ;;
        monthly) echo "monthly on day $AU_MONTHDAY at $AU_TIME" ;;
        *)       echo "daily at $AU_TIME" ;;
    esac
}

au_describe_short(){
    if [ "$AU_ENABLED" = "1" ]; then echo "ON - $(au_describe)"; else echo "OFF"; fi
}

# "install releases immediately" / "wait 48h after a release is published"
au_describe_delay(){
    if [ "$AU_DELAY_HOURS" -gt 0 ]; then echo "wait ${AU_DELAY_HOURS}h after a release is published"; else echo "install releases immediately"; fi
}

# Five cron time fields for the current settings.
au_cron_fields(){
    local h=$((10#${AU_TIME%%:*})) m=$((10#${AU_TIME##*:}))
    case "$AU_FREQUENCY" in
        weekly)  echo "$m $h * * $AU_WEEKDAY" ;;
        monthly) echo "$m $h $AU_MONTHDAY * *" ;;
        *)       echo "$m $h * * *" ;;
    esac
}

# Make the cron file match the settings. Safe to run repeatedly.
au_apply(){
    if [ "$AU_ENABLED" != "1" ]; then
        rm -f "$AU_CRON_FILE"
        return 0
    fi
    cat > "$AU_CRON_FILE" <<EOF || return 1
# Managed by ShieldPress VPS Auto-Update. Change it with: shieldpress autoupdate
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$(au_cron_fields) root $AU_RUNNER >/dev/null 2>&1
EOF
    chmod 644 "$AU_CRON_FILE" || return 1
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$AU_CRON_FILE" 2>/dev/null || true
    fi
    # The schedule only fires while the cron daemon runs.
    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet crond 2>/dev/null; then
        systemctl enable --now crond >/dev/null 2>&1 || echo "[WARN] Cannot start crond; the schedule will not run until it is started."
    fi
    return 0
}

# Last run recorded by the runner: "epoch|result|message".
au_last_run(){
    local line epoch result msg
    [ -f "$AU_STATUS_FILE" ] || { echo "never"; return; }
    line=$(tail -1 "$AU_STATUS_FILE")
    epoch="${line%%|*}"; line="${line#*|}"
    result="${line%%|*}"; msg="${line#*|}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || { echo "never"; return; }
    echo "$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$epoch") - $result: $msg"
}
