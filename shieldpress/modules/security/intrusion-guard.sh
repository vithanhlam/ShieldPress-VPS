#!/bin/bash
# =====================================================
# ShieldPress Intrusion Guard
# Detects account takeover: unknown user + sudo NOPASSWD + backdoor:
#   - new users / extra UID 0 / new login shells compared with the baseline
#   - sudoers NOPASSWD, sudo/wheel group members
#   - new authorized_keys entries, modified sshd_config
#   - console logins (tty/ttyS/hvc), logins by unknown users
#   - users without a useradd log (created outside the OS: console/rescue/panel/guest-agent)
#   - IOCs: backdoor domains/IPs/strings, injected cron/systemd/profile, connections to IOC IPs
#   - qemu-guest-agent running (the host can set passwords / write files inside the VM)
#
# Usage: intrusion-guard.sh            (menu)
#        intrusion-guard.sh --scan     (non-interactive, for the timer; exit 2 on CRIT)
#        intrusion-guard.sh --baseline (save the current state without asking)
# =====================================================

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
[ -f "$BASE_DIR/core/paths.sh" ] && source "$BASE_DIR/core/paths.sh"
LOG_DIR="${LOG_DIR:-/var/shieldpress/logs}"
DATA_DIR="${DATA_DIR:-/var/shieldpress/data}"
ETC_DIR="${ETC_DIR:-/etc/shieldpress}"

IG_DIR="$DATA_DIR/intrusion-baseline"
IG_LOG="$LOG_DIR/intrusion-guard.log"
IG_FLAG="$DATA_DIR/intrusion-alert.flag"       # line 1: CRIT|WARN|OK, line 2: summary
IG_IOC_FILE="$ETC_DIR/intrusion-ioc.list"      # one IOC per line (domain/IP/string), added by the admin
IG_TIMER="/etc/systemd/system/sp-intrusion-guard.timer"
IG_SERVICE="/etc/systemd/system/sp-intrusion-guard.service"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
mkdir -p "$LOG_DIR" "$IG_DIR" "$ETC_DIR" 2>/dev/null

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

# Built-in IOCs from a known intrusion (add more in $IG_IOC_FILE)
BUILTIN_IOC=(
    "vibepass.us"
    "79.124.56.242"
    "SERVER_ID=81144"
    "Linux Panel"
)

FINDINGS=()
add(){ FINDINGS+=("$1|$2"); }   # add CRIT|WARN|INFO "message"

# ---------------------------------------------------
# Collect the current state
# ---------------------------------------------------

# Users able to log in: UID 0, or UID >= 1000 with a real shell
login_users(){
    getent passwd | awk -F: '
        $7 !~ /(nologin|false|sync|shutdown|halt)$/ && ($3==0 || $3>=1000) && $1!="nobody" {print $1":"$3":"$7}' | sort
}

sudo_users(){
    local g u
    for g in wheel sudo admin; do
        getent group "$g" 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n'
    done | awk 'NF' | sort -u
    # users named directly in sudoers
    cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null \
        | grep -Ev '^[[:space:]]*(#|$|Defaults|Cmnd_Alias|Host_Alias|User_Alias|Runas_Alias|@include)' \
        | awk '{print $1}' | grep -Ev '^%|^ALL$' | sort -u
}

sudoers_nopasswd(){
    grep -HEs '^[[:space:]]*[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | sed 's/[[:space:]]\+/ /g'
}

key_fingerprints(){
    local u home f
    while IFS=: read -r u _ _ _ _ home _; do
        for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            [ -f "$f" ] || continue
            ssh-keygen -lf "$f" 2>/dev/null | awk -v u="$u" '{print u" "$2}'
        done
    done < <(getent passwd)
    # custom AuthorizedKeysFile locations
    ls /etc/ssh/authorized_keys* 2>/dev/null | while read -r f; do
        ssh-keygen -lf "$f" 2>/dev/null | awk -v u="$(basename "$f")" '{print u" "$2}'
    done
}

sshd_fingerprint(){
    cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sha256sum | awk '{print $1}'
}

shell_profile_fingerprint(){
    cat /etc/profile /etc/profile.d/*.sh /etc/rc.local /root/.bashrc /root/.profile /root/.bash_profile 2>/dev/null | sha256sum | awk '{print $1}'
}

persistence_list(){
    {
        ls -1 /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null
        ls -1 /var/spool/cron /var/spool/cron/crontabs 2>/dev/null
        ls -1 /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*/*.service 2>/dev/null
    } | sort -u
}

# ---------------------------------------------------
# Baseline
# ---------------------------------------------------

save_baseline(){
    login_users                > "$IG_DIR/users.list"
    sudo_users                 > "$IG_DIR/sudo-users.list"
    sudoers_nopasswd           > "$IG_DIR/sudoers-nopasswd.list"
    key_fingerprints | sort    > "$IG_DIR/keys.list"
    sshd_fingerprint           > "$IG_DIR/sshd.sha"
    shell_profile_fingerprint  > "$IG_DIR/profile.sha"
    persistence_list           > "$IG_DIR/persistence.list"
    date '+%F %T'              > "$IG_DIR/created-at"
    chmod 600 "$IG_DIR"/* 2>/dev/null
    chmod 700 "$IG_DIR"
}

have_baseline(){ [ -f "$IG_DIR/users.list" ] && [ -f "$IG_DIR/created-at" ]; }

# ---------------------------------------------------
# Checks
# ---------------------------------------------------

check_accounts(){
    # UID 0 accounts other than root
    local u
    while IFS=: read -r u _ uid _; do
        [ "$uid" = "0" ] && [ "$u" != "root" ] && add CRIT "UID 0 account other than root: $u"
    done < <(getent passwd)

    # accounts with an empty password
    awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null | while read -r u; do
        add CRIT "Account with an EMPTY password: $u"
    done

    local cur; cur=$(login_users)
    if have_baseline; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if ! grep -qxF "$line" "$IG_DIR/users.list"; then
                local name=${line%%:*}
                add CRIT "NEW login user compared with the baseline: $line"
            fi
        done <<< "$cur"
    fi

    # user without a useradd log => created outside the OS (console/rescue/panel/guest-agent)
    local name uid shell
    while IFS=: read -r name uid shell; do
        [ "$name" = "root" ] && continue
        if ! _has_useradd_log "$name"; then
            add WARN "User '$name' (uid $uid) has NO useradd log - may have been created outside the OS (console/rescue/panel)"
        fi
    done <<< "$cur"
}

_has_useradd_log(){
    local u="$1"
    grep -qsE "(new user: name=${u},|useradd.*${u})" /var/log/secure* /var/log/auth.log* 2>/dev/null && return 0
    journalctl -t useradd --no-pager -q 2>/dev/null | grep -q "name=${u}," && return 0
    return 1
}

check_sudo(){
    local nop; nop=$(sudoers_nopasswd)
    if [ -n "$nop" ]; then
        if have_baseline; then
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                grep -qxF "$l" "$IG_DIR/sudoers-nopasswd.list" 2>/dev/null || add CRIT "NEW sudo NOPASSWD entry: $l"
            done <<< "$nop"
        else
            while IFS= read -r l; do add WARN "sudo NOPASSWD: $l"; done <<< "$nop"
        fi
    fi
    if have_baseline; then
        local su
        while IFS= read -r su; do
            [ -z "$su" ] && continue
            grep -qxF "$su" "$IG_DIR/sudo-users.list" 2>/dev/null || add CRIT "NEW user with sudo rights: $su"
        done < <(sudo_users)
    fi
    # sudoers files modified in the last 7 days
    find /etc/sudoers /etc/sudoers.d -type f -mtime -7 2>/dev/null | while read -r f; do
        add WARN "Sudoers file modified recently (<7 days): $f"
    done
}

check_keys(){
    have_baseline || return
    local k
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        grep -qxF "$k" "$IG_DIR/keys.list" 2>/dev/null || add CRIT "NEW SSH key in authorized_keys: $k"
    done < <(key_fingerprints | sort)
}

check_sshd(){
    have_baseline || return
    [ "$(sshd_fingerprint)" = "$(cat "$IG_DIR/sshd.sha" 2>/dev/null)" ] || \
        add CRIT "sshd_config / sshd_config.d CHANGED since the baseline"
    [ "$(shell_profile_fingerprint)" = "$(cat "$IG_DIR/profile.sha" 2>/dev/null)" ] || \
        add WARN "/etc/profile, profile.d, rc.local or root .bashrc changed since the baseline"
}

check_logins(){
    command -v last >/dev/null 2>&1 || return
    local line user tty
    # physical/virtual console logins
    while IFS= read -r line; do
        user=$(awk '{print $1}' <<< "$line"); tty=$(awk '{print $2}' <<< "$line")
        [[ "$user" =~ ^(reboot|shutdown|runlevel|wtmp|btmp)$ ]] && continue
        [[ "$tty" =~ ^(tty[0-9]*|ttyS[0-9]+|hvc[0-9]+)$ ]] || continue
        local sev=WARN
        if have_baseline && ! grep -q "^${user}:" "$IG_DIR/users.list"; then sev=CRIT; fi
        add "$sev" "CONSOLE login ($tty) by user '$user': $(awk '{for(i=3;i<=NF;i++) printf $i" "; print ""}' <<< "$line" | cut -c1-70)"
    done < <(last -w -F 2>/dev/null | head -200)

    # SSH logins by users outside the baseline
    if have_baseline; then
        while IFS= read -r line; do
            user=$(awk '{print $1}' <<< "$line"); tty=$(awk '{print $2}' <<< "$line")
            [[ "$user" =~ ^(reboot|shutdown|runlevel|wtmp|btmp|)$ ]] && continue
            [[ "$tty" =~ ^pts/ ]] || continue
            grep -q "^${user}:" "$IG_DIR/users.list" || add CRIT "SSH login by a user outside the baseline: $user ($(awk '{print $3}' <<< "$line"))"
        done < <(last -w -F 2>/dev/null | head -200)
    fi
}

ioc_patterns(){
    printf '%s\n' "${BUILTIN_IOC[@]}"
    [ -f "$IG_IOC_FILE" ] && grep -Ev '^[[:space:]]*(#|$)' "$IG_IOC_FILE"
}

check_ioc(){
    local pat tmp; tmp=$(mktemp)
    ioc_patterns > "$tmp"

    # Do not scan /home recursively (large websites): only per-user persistence locations
    local targets=(/etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/crontab
        /var/spool/cron /etc/systemd/system /usr/lib/systemd/system /etc/profile /etc/profile.d /etc/rc.local
        /usr/local/bin /usr/local/sbin /tmp /var/tmp /dev/shm /etc/ssh /etc/sudoers.d /etc/init.d
        /root/.bashrc /root/.profile /root/.bash_profile /root/.ssh /root/.config/systemd /root/.config/autostart)
    local h
    for h in /home/*; do
        [ "$(basename "$h")" = "domains" ] && continue
        [ -d "$h" ] || continue
        targets+=("$h/.bashrc" "$h/.profile" "$h/.bash_profile" "$h/.ssh" "$h/.config/systemd" "$h/.local/bin")
    done
    local hits
    hits=$(timeout 60 grep -rIlsF -f "$tmp" --exclude-dir=shieldpress --exclude=known_hosts --max-filesize=2M --exclude-dir=node_modules --exclude-dir=.git \
           --exclude=intrusion-guard.sh --exclude=intrusion-ioc.list --exclude='*.log' \
           "${targets[@]}" 2>/dev/null | head -30)
    if [ -n "$hits" ]; then
        while IFS= read -r f; do add CRIT "Backdoor IOC found in file: $f"; done <<< "$hits"
    fi
    # shell history
    local hh
    hh=$(grep -lsF -f "$tmp" /root/.bash_history /home/*/.bash_history 2>/dev/null)
    [ -n "$hh" ] && while IFS= read -r f; do add CRIT "IOC found in command history: $f"; done <<< "$hh"

    # open network connections to IOC IPs
    local ip
    while IFS= read -r ip; do
        [[ "$ip" =~ ^[0-9.]+$ ]] || continue
        ss -tn 2>/dev/null | grep -qF "$ip" && add CRIT "ACTIVE network connection to IOC IP: $ip"
    done < "$tmp"
    rm -f "$tmp"

    # processes running from /tmp, /dev/shm or from a deleted file
    local p
    for p in /proc/[0-9]*; do
        local exe; exe=$(readlink "$p/exe" 2>/dev/null) || continue
        case "$exe" in
            /tmp/.mount_*) ;;   # legitimate AppImage mount
            /tmp/*|/var/tmp/*|/dev/shm/*|*"(deleted)"*)
                add CRIT "Process running from a suspicious location: PID ${p#/proc/} -> $exe" ;;
        esac
    done

    # new persistence
    if have_baseline; then
        local item
        while IFS= read -r item; do
            [ -z "$item" ] && continue
            grep -qxF "$item" "$IG_DIR/persistence.list" 2>/dev/null || add WARN "NEW cron/systemd unit compared with the baseline: $item"
        done < <(persistence_list)
    fi

    # curl|bash, wget|sh in cron/systemd
    grep -rEsl '(curl|wget)[^|]*\|[[:space:]]*(ba)?sh' /etc/cron* /var/spool/cron /etc/systemd/system 2>/dev/null \
        | while read -r f; do add WARN "Download-and-run script (curl|sh) in: $f"; done
}

check_guest_agent(){
    if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
        add WARN "qemu-guest-agent is RUNNING - the host/panel can set passwords and write files inside the VM without SSH (disable it if unused)"
    fi
    # getty autologin on the console
    if grep -rEqs 'autologin|--autologin' /etc/systemd/system/getty@*.service.d /etc/systemd/system/serial-getty@*.service.d /etc/systemd/system/getty.target.wants 2>/dev/null; then
        add CRIT "Console getty has AUTOLOGIN"
    fi
}

check_recent_users(){
    # /etc/passwd, /etc/shadow, /etc/group modified in the last 7 days
    local f
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
        find "$f" -mtime -7 2>/dev/null | grep -q . && \
            add INFO "$f last modified: $(stat -c '%y' "$f" | cut -d. -f1)"
    done
}

run_checks(){
    FINDINGS=()
    check_accounts
    check_sudo
    check_keys
    check_sshd
    check_logins
    check_ioc
    check_guest_agent
    check_recent_users
    have_baseline || add WARN "No baseline yet - run 'Save baseline' once you are sure the system is clean"
}

# ---------------------------------------------------
# Report
# ---------------------------------------------------

report(){
    local crit=0 warn=0 info=0 f sev msg col
    local seen=""
    echo ""
    echo "===================================================="
    echo "  INTRUSION GUARD - account takeover / backdoor check"
    echo "===================================================="
    for f in "${FINDINGS[@]}"; do
        sev=${f%%|*}; msg=${f#*|}
        case "$sev" in
            CRIT) col=$RED;    crit=$((crit+1)) ;;
            WARN) col=$YELLOW; warn=$((warn+1)) ;;
            *)    col=$CYAN;   info=$((info+1)) ;;
        esac
        printf "  ${col}%-5s${RESET} %s\n" "$sev" "$msg"
    done
    [ ${#FINDINGS[@]} -eq 0 ] && echo -e "  ${GREEN}No suspicious activity detected${RESET}"
    echo "----------------------------------------------------"
    echo -e "  CRIT: ${RED}$crit${RESET} | WARN: ${YELLOW}$warn${RESET} | INFO: $info"
    echo "===================================================="

    local state=OK; [ "$warn" -gt 0 ] && state=WARN; [ "$crit" -gt 0 ] && state=CRIT
    { echo "$state"; echo "$(date '+%F %T') CRIT=$crit WARN=$warn"; } > "$IG_FLAG" 2>/dev/null
    if [ "$crit" -gt 0 ] || [ "$warn" -gt 0 ]; then
        {
            echo "$(date '+%F %T') | $state | CRIT=$crit WARN=$warn"
            for f in "${FINDINGS[@]}"; do echo "    $f"; done
        } >> "$IG_LOG"
    fi
    [ "$crit" -gt 0 ] && return 2
    return 0
}

# ---------------------------------------------------
# Response (only after admin confirmation)
# ---------------------------------------------------

lock_user(){
    local u="$1"
    [ "$u" = "root" ] && { echo "Refusing to lock root."; return; }
    id "$u" >/dev/null 2>&1 || { echo "User does not exist."; return; }
    local cur_user="${SUDO_USER:-$(logname 2>/dev/null)}"
    [ "$u" = "$cur_user" ] && { echo -e "${RED}This is the account you are using - refusing.${RESET}"; return; }

    echo ""
    echo "For '$u' this will: lock the password, set the shell to nologin, expire the account,"
    echo "  remove authorized_keys (backed up), remove from sudo/wheel, disable sudoers.d files naming the user and kill its sessions."
    read -p "Confirm? (yes/no): " C
    [ "$C" = "yes" ] || { echo "Cancelled."; return; }

    local bk="$DATA_DIR/intrusion-quarantine/$(date +%Y%m%d%H%M%S)-$u"
    mkdir -p "$bk"; chmod 700 "$bk"
    getent passwd "$u" > "$bk/passwd.line"
    local home; home=$(getent passwd "$u" | cut -d: -f6)
    [ -d "$home/.ssh" ] && cp -a "$home/.ssh" "$bk/ssh" 2>/dev/null

    passwd -l "$u" >/dev/null 2>&1
    chage -E 0 "$u" 2>/dev/null
    usermod -s /sbin/nologin "$u" 2>/dev/null
    rm -f "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2" 2>/dev/null
    gpasswd -d "$u" wheel >/dev/null 2>&1; gpasswd -d "$u" sudo >/dev/null 2>&1
    local f
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        if grep -Eq "^[[:space:]]*${u}[[:space:]]" "$f"; then
            cp -a "$f" "$bk/"; mv "$f" "${f}.disabled-by-shieldpress"
        fi
    done
    pkill -KILL -u "$u" 2>/dev/null
    echo "$(date '+%F %T') | LOCKED user $u | backup: $bk" >> "$IG_LOG"
    echo -e "${GREEN}[OK]${RESET} Locked '$u'. Evidence backup: $bk"
    echo "     (The user is NOT deleted - keep it for investigation: home, history, crontab)"
}

disable_guest_agent(){
    systemctl is-active --quiet qemu-guest-agent 2>/dev/null || systemctl is-enabled --quiet qemu-guest-agent 2>/dev/null || {
        echo "qemu-guest-agent is not running."; return; }
    echo "Disabling the guest agent removes panel features: password reset from the provider panel, consistent snapshots, IP reporting."
    read -p "Disable and mask qemu-guest-agent? (yes/no): " C
    [ "$C" = "yes" ] || { echo "Cancelled."; return; }
    systemctl disable --now qemu-guest-agent 2>/dev/null
    systemctl mask qemu-guest-agent 2>/dev/null
    echo -e "${GREEN}[OK]${RESET} qemu-guest-agent disabled and masked"
}

# ---------------------------------------------------
# Timer
# ---------------------------------------------------

enable_timer(){
    cat > "$IG_SERVICE" <<EOF
[Unit]
Description=ShieldPress Intrusion Guard scan

[Service]
Type=oneshot
ExecStart=$SELF --scan
User=root
EOF
    cat > "$IG_TIMER" <<EOF
[Unit]
Description=ShieldPress Intrusion Guard timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now sp-intrusion-guard.timer 2>/dev/null
    echo -e "${GREEN}[OK]${RESET} Intrusion Guard runs every 5 minutes (and 1 minute after each reboot). Log: $IG_LOG"
}

disable_timer(){
    systemctl disable --now sp-intrusion-guard.timer 2>/dev/null
    rm -f "$IG_TIMER" "$IG_SERVICE"; systemctl daemon-reload
    echo -e "${GREEN}[OK]${RESET} Intrusion Guard timer disabled"
}

# ---------------------------------------------------
# Telegram notifications + realtime watch (logins / network)
# ---------------------------------------------------

IG_CONF="$ETC_DIR/intrusion-guard.conf"
IG_WATCH_SERVICE="/etc/systemd/system/sp-intrusion-watch.service"
NOTIFY="$BASE_DIR/modules/notification/telegram-notify.sh"

load_ig_conf(){
    # Defaults; override them in $IG_CONF
    LOGIN_ALERT_ALL=1          # 1 = alert on EVERY login; 0 = only unknown users / new IPs / console / unknown sudo
    NET_INTERVAL=15            # seconds between samples
    NET_MIN_MBPS=30            # never alert below this rate
    NET_ABS_MBPS=300           # alert above this rate (rx or tx)
    NET_FACTOR=5               # or N times the normal level (EWMA)
    NET_CONSECUTIVE=2          # consecutive samples above the threshold
    CONN_MIN=300               # never alert below this connection count
    CONN_ABS=3000              # total ESTABLISHED connections
    SYN_ABS=300                # SYN-RECV (suspected SYN flood)
    ALERT_COOLDOWN=900         # seconds between two alerts of the same kind
    [ -f "$IG_CONF" ] && source "$IG_CONF"
}

write_default_conf(){
    [ -f "$IG_CONF" ] && return
    cat > "$IG_CONF" <<'CONF'
# ShieldPress Intrusion Guard - alert thresholds
LOGIN_ALERT_ALL=1
NET_INTERVAL=15
NET_MIN_MBPS=30
NET_ABS_MBPS=300
NET_FACTOR=5
NET_CONSECUTIVE=2
CONN_MIN=300
CONN_ABS=3000
SYN_ABS=300
ALERT_COOLDOWN=900
CONF
    chmod 600 "$IG_CONF"
}

# Send Telegram in the background (non-blocking). $1=title $2=body
tg_send(){
    [ -f "$NOTIFY" ] || return 0
    local body="${2:0:3500}"
    ( bash "$NOTIFY" send security_alert "$1" "$body" >/dev/null 2>&1 & )
    echo "$(date '+%F %T') | NOTIFY | $1" >> "$IG_LOG"
}

# Send the same alert at most once per $4 seconds (default 1h)
tg_send_once(){
    local key="$1" title="$2" body="$3" ttl="${4:-3600}"
    local f="$IG_DIR/notified-$key" now last
    now=$(date +%s); last=$(cat "$f" 2>/dev/null || echo 0)
    [ $((now-last)) -ge "$ttl" ] || return 0
    echo "$now" > "$f"
    tg_send "$title" "$body"
}

notify_scan_findings(){
    local crit_lines sha
    crit_lines=$(printf '%s\n' "${FINDINGS[@]}" | grep '^CRIT|' | sort)
    [ -z "$crit_lines" ] && { rm -f "$IG_DIR/last-notified.sha"; return; }
    sha=$(sha256sum <<< "$crit_lines" | awk '{print $1}')
    [ "$sha" = "$(cat "$IG_DIR/last-notified.sha" 2>/dev/null)" ] && return
    echo "$sha" > "$IG_DIR/last-notified.sha"
    tg_send "🚨 Intrusion Guard: signs of INTRUSION" "$(sed 's/^CRIT|/• /' <<< "$crit_lines" | head -25)

Check: shieldpress > Security Center > 22 Intrusion Guard"
}

_rdns(){ timeout 2 getent hosts "$1" 2>/dev/null | awk '{print $2; exit}'; }

# $1=user $2=ip $3=method $4=note
login_event(){
    local user="$1" ip="$2" method="$3" extra="$4"
    local known="in the baseline" icon="🔐" newip="" flags=""
    if have_baseline && ! grep -q "^${user}:" "$IG_DIR/users.list"; then
        known="⚠ NOT in the baseline (UNKNOWN USER)"; icon="🚨"
    fi
    local seen="$IG_DIR/seen-logins.list"
    if [ -n "$ip" ] && [ "$ip" != "console" ]; then
        if ! grep -qxF "$user $ip" "$seen" 2>/dev/null; then
            newip="⚠ NEW IP never seen for this user"; echo "$user $ip" >> "$seen"
            [ "$icon" = "🔐" ] && icon="⚠️"
        fi
    fi
    [ "$method" = "console" ] && { icon="🚨"; flags="⚠ CONSOLE login (not over SSH)"; }
    [ "$method" = "password" ] && flags="${flags:+$flags; }logged in with a PASSWORD"

    # Filter when LOGIN_ALERT_ALL=0
    if [ "$LOGIN_ALERT_ALL" != "1" ] && [ "$icon" = "🔐" ]; then return; fi

    # anti-spam: same user+ip+method within 60s
    local key; key=$(echo "login-$user-$ip-$method" | tr -c 'A-Za-z0-9\n' '_')
    local f="$IG_DIR/notified-$key" now last
    now=$(date +%s); last=$(cat "$f" 2>/dev/null || echo 0)
    [ $((now-last)) -ge 60 ] || return
    echo "$now" > "$f"

    local ptr=""; [ -n "$ip" ] && [ "$ip" != "console" ] && ptr=$(_rdns "$ip")
    local sudoer="no"; sudo_users | grep -qx "$user" && sudoer="YES (sudo)"
    local sessions; sessions=$(who 2>/dev/null | awk '{printf "  %s %s %s %s %s\n",$1,$2,$3,$4,$5}' | head -8)

    tg_send "$icon Login: $user @ $(hostname)" "User     : $user
Source IP: ${ip:-n/a}${ptr:+ ($ptr)}
Method   : $method
${extra:+Details  : $extra
}Status   : $known
Sudo     : $sudoer
${newip:+$newip
}${flags:+Warning  : $flags
}Time     : $(date '+%F %T %Z')

Open sessions:
$sessions"
}

watch_handle_line(){
    local l="$1"
    local user ip method fp
    if [[ "$l" =~ Accepted\ ([a-z-]+(/[a-z]+)?)\ for\ ([^\ ]+)\ from\ ([0-9a-fA-F:.]+)\ port\ ([0-9]+) ]]; then
        method="${BASH_REMATCH[1]}"; user="${BASH_REMATCH[3]}"; ip="${BASH_REMATCH[4]}"; local port="${BASH_REMATCH[5]}"
        fp=""; [[ "$l" =~ (SHA256:[A-Za-z0-9+/=]+) ]] && fp="key ${BASH_REMATCH[1]}"
        login_event "$user" "$ip" "$method" "$fp port $port"
    elif [[ "$l" =~ pam_unix\(login:session\):\ session\ opened\ for\ user\ ([^\ \(]+) ]]; then
        login_event "${BASH_REMATCH[1]}" "console" "console" "tty console"
    elif [[ "$l" =~ ^[[:space:]]*([^\ ]+)\ :\ .*TTY=([^\ \;]+)\ \;\ PWD=([^\;]+)\ \;\ USER=([^\ ]+)\ \;\ COMMAND=(.*)$ ]]; then
        local su="${BASH_REMATCH[1]}" tty="${BASH_REMATCH[2]}" tu="${BASH_REMATCH[4]}" cmd="${BASH_REMATCH[5]}" pwd_="${BASH_REMATCH[3]}"
        local unknown=0
        have_baseline && ! grep -q "^${su}:" "$IG_DIR/users.list" && unknown=1
        # sensitive commands
        local sens=0
        [[ "$cmd" =~ (useradd|adduser|usermod|passwd|visudo|sudoers|sshd_config|authorized_keys|curl.*\|.*sh|wget.*\|.*sh|chattr|iptables|firewall-cmd|systemctl[[:space:]]+(stop|disable|mask)) ]] && sens=1
        if [ "$unknown" = 1 ] || [ "$sens" = 1 ]; then
            tg_send_once "sudo-$(echo "$su$cmd" | sha1sum | cut -c1-12)" \
                "$([ $unknown = 1 ] && echo '🚨' || echo '⚠️') sudo: $su → $tu" \
                "User : $su$([ $unknown = 1 ] && echo '  (UNKNOWN user - outside the baseline)')
TTY  : $tty
Ran  : $cmd
Dir  : $pwd_" 300
        fi
    elif [[ "$l" =~ new\ user:\ name=([^,]+),\ UID=([0-9]+) ]]; then
        tg_send "🚨 NEW USER CREATED: ${BASH_REMATCH[1]}" "A new user was created (useradd): ${BASH_REMATCH[1]} (UID ${BASH_REMATCH[2]})
If this was not you, the server may be compromised. Check: Intrusion Guard (menu 22)."
    elif [[ "$l" =~ add\ \'([^\']+)\'\ to\ (shadow\ )?group\ \'(wheel|sudo|admin|root)\' ]]; then
        tg_send "🚨 User added to a privileged group" "User '${BASH_REMATCH[1]}' was just added to group '${BASH_REMATCH[3]}'"
    elif [[ "$l" =~ password\ changed\ for\ ([^\ ]+) ]] || [[ "$l" =~ chauthtok.*password\ changed\ for\ ([^\ ]+) ]]; then
        tg_send_once "pw-${BASH_REMATCH[1]}" "⚠️ Password changed for user: ${BASH_REMATCH[1]}" "The password of '${BASH_REMATCH[1]}' was changed at $(date '+%F %T')." 120
    fi
}

_net_top(){
    echo "Top connected IPs:"
    ss -Htn state established 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' \
        | sort | uniq -c | sort -rn | head -5 | awk '{printf "  %s  (%s connections)\n",$2,$1}'
    echo "Most targeted ports:"
    ss -Htn state established 2>/dev/null | awk '{print $3}' | grep -oE '[0-9]+$' \
        | sort | uniq -c | sort -rn | head -3 | awk '{printf "  :%s  (%s connections)\n",$2,$1}'
    echo "Top CPU processes:"
    ps -eo pid,user:12,pcpu,comm --sort=-pcpu 2>/dev/null | head -4 | tail -3 | sed 's/^/  /'
}

net_sampler(){
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$iface" ] || { echo "Default network interface not found" >> "$IG_LOG"; return; }
    local rx0 tx0 rx1 tx1 rxm txm
    read -r rx0 tx0 < <(awk -v i="$iface:" '$1==i {print $2, $10}' /proc/net/dev)
    local ewrx=0 ewtx=0 ewconn=0 n=0 hit_rx=0 hit_tx=0 hit_conn=0
    while sleep "$NET_INTERVAL"; do
        read -r rx1 tx1 < <(awk -v i="$iface:" '$1==i {print $2, $10}' /proc/net/dev)
        [ -n "$rx1" ] || continue
        rxm=$(awk -v a="$rx0" -v b="$rx1" -v t="$NET_INTERVAL" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.1f", d*8/1e6/t}')
        txm=$(awk -v a="$tx0" -v b="$tx1" -v t="$NET_INTERVAL" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.1f", d*8/1e6/t}')
        rx0=$rx1; tx0=$tx1
        local conn syn
        conn=$(ss -Htn state established 2>/dev/null | wc -l)
        syn=$(ss -Htn state syn-recv 2>/dev/null | wc -l)

        local srx stx sconn
        srx=$(awk -v r="$rxm" -v e="$ewrx" -v mn="$NET_MIN_MBPS" -v ab="$NET_ABS_MBPS" -v f="$NET_FACTOR" -v n="$n" 'BEGIN{print (r>=mn && (r>=ab || (n>=20 && r>f*e)))?1:0}')
        stx=$(awk -v r="$txm" -v e="$ewtx" -v mn="$NET_MIN_MBPS" -v ab="$NET_ABS_MBPS" -v f="$NET_FACTOR" -v n="$n" 'BEGIN{print (r>=mn && (r>=ab || (n>=20 && r>f*e)))?1:0}')
        sconn=$(awk -v c="$conn" -v e="$ewconn" -v mn="$CONN_MIN" -v ab="$CONN_ABS" -v f="$NET_FACTOR" -v n="$n" 'BEGIN{print (c>=mn && (c>=ab || (n>=20 && c>f*e)))?1:0}')

        [ "$srx" = 1 ] && hit_rx=$((hit_rx+1)) || hit_rx=0
        [ "$stx" = 1 ] && hit_tx=$((hit_tx+1)) || hit_tx=0
        [ "$sconn" = 1 ] && hit_conn=$((hit_conn+1)) || hit_conn=0

        # only learn the normal level while traffic is NOT abnormal
        if [ "$srx$stx$sconn" = "000" ]; then
            ewrx=$(awk -v e="$ewrx" -v r="$rxm" 'BEGIN{printf "%.2f", e*0.9+r*0.1}')
            ewtx=$(awk -v e="$ewtx" -v r="$txm" 'BEGIN{printf "%.2f", e*0.9+r*0.1}')
            ewconn=$(awk -v e="$ewconn" -v r="$conn" 'BEGIN{printf "%.1f", e*0.9+r*0.1}')
            n=$((n+1))
        fi

        if [ "$hit_rx" -ge "$NET_CONSECUTIVE" ]; then
            tg_send_once "net-rx" "🚨 Inbound traffic spike ($iface)" "Inbound bandwidth: ${rxm} Mbps (normal ~${ewrx} Mbps)
Outbound bandwidth: ${txm} Mbps
ESTABLISHED connections: $conn | SYN-RECV: $syn
Suspected: DDoS / aggressive crawling / brute force.

$(_net_top)" "$ALERT_COOLDOWN"
        fi
        if [ "$hit_tx" -ge "$NET_CONSECUTIVE" ]; then
            tg_send_once "net-tx" "🚨 Outbound traffic spike ($iface)" "Outbound bandwidth: ${txm} Mbps (normal ~${ewtx} Mbps)
Inbound bandwidth: ${rxm} Mbps
ESTABLISHED connections: $conn
Suspected: the server is used for DDoS/spam, coin mining or data exfiltration.

$(_net_top)" "$ALERT_COOLDOWN"
        fi
        if [ "$hit_conn" -ge "$NET_CONSECUTIVE" ] || [ "$syn" -ge "$SYN_ABS" ]; then
            tg_send_once "net-conn" "🚨 Abnormal connection count" "ESTABLISHED: $conn (normal ~${ewconn}) | SYN-RECV: $syn
Inbound/outbound bandwidth: ${rxm}/${txm} Mbps
$([ "$syn" -ge "$SYN_ABS" ] && echo 'Suspected: SYN flood.')

$(_net_top)" "$ALERT_COOLDOWN"
        fi
    done
}

watch_loop(){
    load_ig_conf
    echo "$(date '+%F %T') | WATCH started" >> "$IG_LOG"
    net_sampler &
    local NS=$!
    trap 'kill $NS 2>/dev/null' EXIT TERM INT
    journalctl -f -n 0 -o cat _COMM=sshd _COMM=sshd-session _COMM=login _COMM=sudo \
        _COMM=useradd _COMM=usermod _COMM=gpasswd _COMM=passwd _COMM=chpasswd 2>/dev/null \
    | while IFS= read -r line; do
        watch_handle_line "$line"
    done
}

enable_watch(){
    write_default_conf
    command -v journalctl >/dev/null 2>&1 || { echo "systemd-journald is required"; return 1; }
    cat > "$IG_WATCH_SERVICE" <<EOF
[Unit]
Description=ShieldPress Intrusion Guard realtime watch (login + network)
After=network-online.target

[Service]
ExecStart=$SELF --watch
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sp-intrusion-watch.service 2>/dev/null
    systemctl is-active --quiet sp-intrusion-watch.service \
        && echo -e "${GREEN}[OK]${RESET} Realtime watch enabled (logins, sudo, new users, network). Thresholds: $IG_CONF" \
        || echo -e "${RED}[FAILED]${RESET} Failed to start: journalctl -u sp-intrusion-watch"
    [ -f "$BASE_DIR/config/telegram-notify.env" ] \
        || echo -e "${YELLOW}Telegram is not configured - enable it in Telegram Notifications (category security_alert).${RESET}"
}

disable_watch(){
    systemctl disable --now sp-intrusion-watch.service 2>/dev/null
    rm -f "$IG_WATCH_SERVICE"; systemctl daemon-reload
    echo -e "${GREEN}[OK]${RESET} Realtime watch disabled"
}

edit_thresholds(){
    write_default_conf; load_ig_conf
    echo "Current thresholds (Enter keeps the value):"
    local k v
    for k in NET_ABS_MBPS NET_MIN_MBPS NET_FACTOR CONN_ABS SYN_ABS LOGIN_ALERT_ALL; do
        read -p "  $k [${!k}]: " v
        if [ -n "$v" ]; then
            [[ "$v" =~ ^[0-9]+$ ]] || { echo "  skipped (not a number)"; continue; }
            sed -i -E "s/^${k}=.*/${k}=${v}/" "$IG_CONF"
        fi
    done
    systemctl is-active --quiet sp-intrusion-watch.service && systemctl restart sp-intrusion-watch.service
    echo "Saved: $IG_CONF"
}

# ---------------------------------------------------
# Entry
# ---------------------------------------------------

case "${1:-}" in
    --scan)
        load_ig_conf
        run_checks; report >/dev/null; rc=$?
        notify_scan_findings
        exit $rc ;;
    --watch)
        watch_loop; exit 0 ;;
    --baseline)
        save_baseline; echo "Baseline saved: $IG_DIR"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

while true; do
    echo ""
    echo "===================================================="
    echo "  INTRUSION GUARD"
    echo "===================================================="
    if have_baseline; then echo -e "  Baseline : ${GREEN}$(cat "$IG_DIR/created-at")${RESET}"; else echo -e "  Baseline : ${YELLOW}not set${RESET}"; fi
    if systemctl is-active --quiet sp-intrusion-guard.timer 2>/dev/null; then echo -e "  Scheduler: ${GREEN}ENABLED (5 min)${RESET}"; else echo -e "  Scheduler: ${DIM}off${RESET}"; fi
    if systemctl is-active --quiet sp-intrusion-watch.service 2>/dev/null; then echo -e "  Realtime : ${GREEN}ENABLED (logins + network > Telegram)${RESET}"; else echo -e "  Realtime : ${DIM}off${RESET}"; fi
    echo ""
    echo "  1) Scan now"
    echo "  2) Save baseline (confirm the system is clean)"
    echo "  3) Enable scheduled scan (5 min)"
    echo "  4) Disable scheduled scan"
    echo "  5) Lock a suspicious user (evidence is backed up)"
    echo "  6) Disable qemu-guest-agent"
    echo "  7) View alert log"
    echo "  8) Add IOC (domain/IP/string)"
    echo "  9) Enable REALTIME watch + Telegram (logins, sudo, new users, traffic spikes)"
    echo " 10) Disable realtime watch"
    echo " 11) Change alert thresholds"
    echo " 12) Send a Telegram test message"
    echo "  0) Back"
    read -p "Select: " c
    case "$c" in
        1) run_checks; report ;;
        2)
            echo ""; echo "Users able to log in:"; login_users | sed 's/^/   /'
            echo "Users with sudo:"; sudo_users | sed 's/^/   /'
            echo "sudo NOPASSWD:"; sudoers_nopasswd | sed 's/^/   /'
            echo ""
            echo -e "${YELLOW}Only save the baseline if you are sure ALL entries above are yours.${RESET}"
            read -p "Save baseline? (yes/no): " C
            [ "$C" = "yes" ] && { save_baseline; echo -e "${GREEN}[OK]${RESET} Baseline saved"; } || echo "Cancelled." ;;
        3) have_baseline || echo -e "${YELLOW}Save a baseline first (option 2).${RESET}"; enable_timer ;;
        4) disable_timer ;;
        5) read -p "Username to lock: " U; lock_user "$U" ;;
        6) disable_guest_agent ;;
        7) tail -n 60 "$IG_LOG" 2>/dev/null || echo "No alerts yet." ;;
        8) read -p "IOC: " I; [ -n "$I" ] && echo "$I" >> "$IG_IOC_FILE" && echo "Added." ;;
        9) enable_watch ;;
        10) disable_watch ;;
        11) edit_thresholds ;;
        12) bash "$NOTIFY" test && echo "Sent (if Telegram is enabled)." ;;
        0) break ;;
        *) echo "Invalid" ;;
    esac
    echo ""; read -p "Press Enter..."
done
