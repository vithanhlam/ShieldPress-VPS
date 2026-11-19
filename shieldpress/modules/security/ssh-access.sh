#!/bin/bash
# =====================================================
# ShieldPress SSH Access
#   - inventory every SSH public key that can log in (all users), see where and
#     when it was last used, create / add / revoke / restore / delete keys
#   - persistent login history (who, from where, which method and which key)
#   - optional recording of commands typed in interactive SSH shells
#
# Usage: ssh-access.sh                       (menu)
#        ssh-access.sh --list [--tsv]
#        ssh-access.sh --show ID
#        ssh-access.sh --create USER COMMENT [FROM_CIDR]   (private key to stdout, no passphrase)
#        ssh-access.sh --add-pub USER "ssh-ed25519 AAAA... comment"
#        ssh-access.sh --revoke ID | --restore ID | --delete ID [--force]
#        ssh-access.sh --collect            (ingest logins/commands; run by the timer)
#        ssh-access.sh --history [USER|all] [N]
#        ssh-access.sh --activity [USER|all] [N]
#        ssh-access.sh --enable-history | --disable-history
#        ssh-access.sh --enable-activity | --disable-activity | --status
# =====================================================

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
[ -f "$BASE_DIR/core/paths.sh" ] && source "$BASE_DIR/core/paths.sh"
declare -F sp_header >/dev/null || source "${BASE_DIR:-/opt/shieldpress}/core/ui.sh"
LOG_DIR="${LOG_DIR:-/var/shieldpress/logs}"
DATA_DIR="${DATA_DIR:-/var/shieldpress/data}"

SA_DIR="${SA_DIR:-$DATA_DIR/ssh-access}"
SA_LOGINS="$SA_DIR/logins.tsv"          # epoch iso user ip port method fingerprint source
SA_CMDS="$SA_DIR/commands.tsv"          # epoch iso user ip session tty pwd command
SA_BACKUP="${SA_BACKUP:-$DATA_DIR/ssh-key-backups}"
SA_LOG="$LOG_DIR/ssh-access.log"
SA_CONF="${ETC_DIR:-/etc/shieldpress}/ssh-access.conf"
SA_TIMER="/etc/systemd/system/sp-ssh-access.timer"
SA_SERVICE="/etc/systemd/system/sp-ssh-access.service"
SA_PROFILE="/etc/profile.d/zz-shieldpress-ssh-audit.sh"
IG_KEYS="${IG_KEYS:-$DATA_DIR/intrusion-baseline/keys.list}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SA_RETENTION_DAYS=90
[ -f "$SA_CONF" ] && source "$SA_CONF"

RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"
ok(){ echo -e "  ${GREEN}[OK]${RESET}   $*"; }
warn(){ echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
fail(){ echo -e "  ${RED}[FAIL]${RESET} $*" >&2; }
info(){ echo -e "  ${CYAN}[INFO]${RESET} $*"; }
sa_log(){ mkdir -p "$LOG_DIR" 2>/dev/null; echo "$(date '+%F %T') | $*" >> "$SA_LOG" 2>/dev/null; }
sa_init(){ mkdir -p "$SA_DIR" "$SA_BACKUP" "$LOG_DIR" 2>/dev/null; chmod 700 "$SA_DIR" "$SA_BACKUP" 2>/dev/null; }

KEY_TYPES='ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'

# ---------------------------------------------------
# Key inventory
# ---------------------------------------------------

# "user<TAB>file" for every authorized_keys file that exists
sa_key_files(){
    local pats u h pat f
    pats=$(sshd -T 2>/dev/null | awk 'tolower($1)=="authorizedkeysfile"{for(i=2;i<=NF;i++)print $i}')
    [ -n "$pats" ] || pats=".ssh/authorized_keys .ssh/authorized_keys2"
    pats="$pats .ssh/authorized_keys2"
    while IFS=: read -r u _ _ _ _ h _; do
        [ -d "$h" ] && [ "$h" != "/" ] || continue
        for pat in $pats; do
            f="${pat//%h/$h}"; f="${f//%u/$u}"; f="${f//%%/%}"
            case "$f" in /*) ;; *) f="$h/$f" ;; esac
            [ -f "$f" ] && printf '%s\t%s\n' "$u" "$f"
        done
    done < <(getent passwd)
    for f in /etc/ssh/authorized_keys /etc/ssh/authorized_keys.d/*; do
        [ -f "$f" ] && printf '%s\t%s\n' "(system)" "$f"
    done
}

sa_key_id(){ printf '%s' "$1|$2|$3" | sha256sum | cut -c1-8; }

# Last time a fingerprint was used to log in (from the persistent login history)
sa_last_use(){
    local fp="$1"
    [ -f "$SA_LOGINS" ] || { echo "-"; return; }
    awk -F'\t' -v fp="$fp" '$7==fp {l=$2" from "$4} END{print (l?l:"never recorded")}' "$SA_LOGINS"
}

# Fingerprint of the key used by the current SSH session (empty when unknown)
sa_session_fp(){
    [ -n "$SSH_CLIENT" ] || return 0
    local ip port
    ip=$(awk '{print $1}' <<< "$SSH_CLIENT"); port=$(awk '{print $2}' <<< "$SSH_CLIENT")
    [ -f "$SA_LOGINS" ] || return 0
    awk -F'\t' -v ip="$ip" -v port="$port" '$4==ip && $5==port {fp=$7} END{print fp}' "$SA_LOGINS"
}

# TSV: id user file line state type bits fp options comment
sa_list_tsv(){
    local user file n line state raw fp bits type comment opts out id
    while IFS=$'\t' read -r user file; do
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n+1)); state="active"; raw="$line"
            case "$line" in
                "#REVOKED "*) state="revoked"; raw="${line#\#REVOKED }"; raw="${raw#* }" ;;
                ''|\#*) continue ;;
            esac
            out=$(ssh-keygen -lf - <<< "$raw" 2>/dev/null) || continue
            [ -n "$out" ] || continue
            bits=$(awk '{print $1}' <<< "$out")
            fp=$(awk '{print $2}' <<< "$out")
            type=$(sed -E 's/.*\(([^)]+)\)[[:space:]]*$/\1/' <<< "$out")
            comment=$(sed -E 's/^[0-9]+ [^ ]+ ?//; s/ ?\([^)]+\)[[:space:]]*$//' <<< "$out")
            opts=""
            if [[ "$raw" =~ ^(.*[[:space:]])?($KEY_TYPES)[[:space:]] ]]; then opts="${BASH_REMATCH[1]}"; fi
            opts="${opts%"${opts##*[![:space:]]}"}"
            id=$(sa_key_id "$user" "$file" "$fp")
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$id" "$user" "$file" "$n" "$state" "$type" "$bits" "$fp" "${opts:--}" "${comment:--}"
        done < "$file"
    done < <(sa_key_files | sort -u)
}

sa_baseline_has(){ [ -f "$IG_KEYS" ] && grep -qF "$2" "$IG_KEYS" 2>/dev/null; }

sa_flags(){   # user state type bits fp opts
    local user="$1" state="$2" type="$3" bits="$4" fp="$5" opts="$6" f=""
    [ "$state" = "revoked" ] && { echo "REVOKED"; return; }
    [ "$fp" = "$(sa_session_fp)" ] && [ -n "$fp" ] && f="$f IN-USE-BY-THIS-SESSION"
    { [ "$type" = "DSA" ] || { [ "$type" = "RSA" ] && [ "${bits:-0}" -lt 3072 ]; }; } && f="$f WEAK"
    [ "$user" = "root" ] && [[ "$opts" != *from=* ]] && f="$f ROOT-UNRESTRICTED"
    [ -f "$IG_KEYS" ] && ! sa_baseline_has "$user" "$fp" && f="$f NOT-IN-BASELINE"
    echo "${f# }"
}

sa_list(){
    sa_init
    if [ "$1" = "--tsv" ]; then sa_list_tsv; return; fi
    local rows; rows=$(sa_list_tsv)
    echo ""
    sp_title 'SSH Keys On This Server'
    local pw root
    pw=$(sshd -T 2>/dev/null | awk 'tolower($1)=="passwordauthentication"{print $2}')
    root=$(sshd -T 2>/dev/null | awk 'tolower($1)=="permitrootlogin"{print $2}')
    echo "  sshd: PasswordAuthentication=${pw:-?}  PermitRootLogin=${root:-?}"
    echo ""
    if [ -z "$rows" ]; then
        info "No SSH public keys found in any authorized_keys file."
        [ "$pw" = "yes" ] && info "Logins currently rely on passwords. Create a key from this menu before disabling passwords."
        return 0
    fi
    printf "  ${BOLD}%-9s %-10s %-8s %-8s %-9s %s${RESET}\n" ID USER TYPE STATE "LAST USE" "COMMENT / FLAGS"
    local id user file n state type bits fp opts comment flags last
    while IFS=$'\t' read -r id user file n state type bits fp opts comment; do
        flags=$(sa_flags "$user" "$state" "$type" "$bits" "$fp" "$opts")
        last=$(sa_last_use "$fp"); last="${last%% from*}"
        printf "  %-9s %-10s %-8s %-8s %-9s %s${YELLOW}%s${RESET}\n" \
            "$id" "$user" "${type}${bits:+/$bits}" "$state" "${last:0:10}" "$comment  " "$flags"
    done <<< "$rows"
    echo ""
    info "Flags: ROOT-UNRESTRICTED = no from= limit, WEAK = RSA<3072/DSA, NOT-IN-BASELINE = unknown to Intrusion Guard."
}

sa_find(){ sa_list_tsv | awk -F'\t' -v id="$1" '$1==id {print; exit}'; }

sa_show(){
    local rec; rec=$(sa_find "$1")
    [ -n "$rec" ] || { fail "No key with id '$1'"; return 1; }
    local id user file n state type bits fp opts comment
    IFS=$'\t' read -r id user file n state type bits fp opts comment <<< "$rec"
    echo ""
    printf "  %-14s: %s\n" "ID" "$id" "User" "$user" "File" "$file:$n" "State" "$state" \
        "Type" "$type $bits bits" "Fingerprint" "$fp" "Comment" "$comment" "Options" "$opts"
    printf "  %-14s: %s\n" "Last login" "$(sa_last_use "$fp")" "Flags" "$(sa_flags "$user" "$state" "$type" "$bits" "$fp" "$opts")"
    printf "  %-14s: %s\n" "File modified" "$(stat -c '%y' "$file" 2>/dev/null | cut -d. -f1)"
    if [ -f "$SA_LOGINS" ]; then
        echo "  Recent logins with this key:"
        awk -F'\t' -v fp="$fp" '$7==fp' "$SA_LOGINS" | tail -5 | awk -F'\t' '{printf "    %s  %s@%s  (%s)\n",$2,$3,$4,$6}'
    fi
}

# ---------------------------------------------------
# Changes (always back up the file first)
# ---------------------------------------------------

sa_backup_file(){
    sa_init
    local f="$1" dest
    dest="$SA_BACKUP/$(echo "$f" | tr '/' '_')-$(date +%Y%m%d%H%M%S)"
    cp -a "$f" "$dest" && chmod 600 "$dest" && echo "$dest"
}

sa_restore_context(){ command -v restorecon >/dev/null 2>&1 && restorecon -R "$(dirname "$1")" 2>/dev/null; return 0; }

# Refuse a change that would remove the last key while passwords are off.
sa_lockout_risk(){   # id
    local pw remaining
    pw=$(sshd -T 2>/dev/null | awk 'tolower($1)=="passwordauthentication"{print $2}')
    [ "$pw" = "no" ] || return 1
    remaining=$(sa_list_tsv | awk -F'\t' -v id="$1" '$1!=id && $5=="active"' | wc -l)
    [ "$remaining" -eq 0 ]
}

sa_modify(){   # action id [force]
    local action="$1" id="$2" force="$3" rec
    rec=$(sa_find "$id")
    [ -n "$rec" ] || { fail "No key with id '$id'"; return 1; }
    local _id user file n state type bits fp opts comment
    IFS=$'\t' read -r _id user file n state type bits fp opts comment <<< "$rec"
    case "$action" in
        revoke)  [ "$state" = "active" ]  || { info "Key $id is already revoked."; return 0; } ;;
        restore) [ "$state" = "revoked" ] || { info "Key $id is not revoked."; return 0; } ;;
    esac
    if [ "$action" != "restore" ] && [ "$state" = "active" ] && sa_lockout_risk "$id" && [ "$force" != "force" ]; then
        fail "Refusing: this is the last SSH key and PasswordAuthentication is off - you would lose SSH access."
        return 2
    fi
    local bk; bk=$(sa_backup_file "$file") || { fail "Cannot back up $file"; return 1; }
    # The line number is only trusted while the line still holds the same key
    local cur; cur=$(sed -n "${n}p" "$file" | sed -E 's/^#REVOKED [0-9]+ //')
    if [ "$(ssh-keygen -lf - <<< "$cur" 2>/dev/null | awk '{print $2}')" != "$fp" ]; then
        fail "The file changed while working; run the list again."
        return 1
    fi
    case "$action" in
        revoke)  sed -i "${n}s/^/#REVOKED $(date +%s) /" "$file" ;;
        restore) sed -i -E "${n}s/^#REVOKED [0-9]+ //" "$file" ;;
        delete)  sed -i "${n}d" "$file" ;;
        *) fail "Unknown action"; return 1 ;;
    esac || { fail "Cannot update $file"; return 1; }
    sa_restore_context "$file"
    sa_log "$action key id=$id user=$user fp=$fp file=$file backup=$bk"
    ok "Key $id ($comment) ${action}d. Backup: $bk"
    if [ "$action" != "restore" ]; then
        info "New logins with this key are refused immediately. Existing sessions stay open until they end."
        info "End sessions of '$user' with: pkill -KILL -u $user -t pts/N   (see: who)"
    fi
}

sa_register_baseline(){   # user fingerprint
    # Keys created or added here are intentional: tell Intrusion Guard so it
    # does not raise a "NEW SSH key" alert for them.
    [ -f "$IG_KEYS" ] && ! grep -qxF "$1 $2" "$IG_KEYS" && echo "$1 $2" >> "$IG_KEYS"
    return 0
}

sa_home(){ getent passwd "$1" | cut -d: -f6; }

sa_append_pub(){   # user "public key line" [from_cidr]
    local user="$1" pub="$2" from="$3" home grp file fp
    id "$user" >/dev/null 2>&1 || { fail "User '$user' does not exist"; return 1; }
    home=$(sa_home "$user"); grp=$(id -gn "$user")
    [ -d "$home" ] || { fail "Home directory of '$user' not found"; return 1; }
    [[ "$pub" =~ ^($KEY_TYPES)[[:space:]] ]] || { fail "Not an SSH public key line"; return 1; }
    fp=$(ssh-keygen -lf - <<< "$pub" 2>/dev/null | awk '{print $2}')
    [ -n "$fp" ] || { fail "Invalid public key"; return 1; }
    file="$home/.ssh/authorized_keys"
    mkdir -p "$home/.ssh" && chmod 700 "$home/.ssh" && chown "$user:$grp" "$home/.ssh"
    if [ -f "$file" ] && sa_list_tsv | awk -F'\t' -v u="$user" -v fp="$fp" '$2==u && $8==fp && $5=="active"{f=1} END{exit !f}'; then
        info "This key is already authorised for $user."
        return 3
    fi
    [ -f "$file" ] && sa_backup_file "$file" >/dev/null
    if [ -n "$from" ]; then
        [[ "$from" =~ ^[0-9a-fA-F:.,/*?!-]+$ ]] || { fail "Invalid from= value"; return 1; }
        pub="from=\"$from\" $pub"
    fi
    # Make sure the previous last line ends with a newline
    [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && echo >> "$file"
    echo "$pub" >> "$file"
    chmod 600 "$file"; chown "$user:$grp" "$file"
    sa_restore_context "$file"
    sa_register_baseline "$user" "$fp"
    sa_log "added key user=$user fp=$fp from=${from:--}"
    SA_LAST_FP="$fp"
    return 0
}

# Generate an ed25519 pair, authorise the public half, show the private half once.
# Mode "batch": no passphrase, private key written to stdout (tests / automation).
sa_create(){   # user comment [from] [batch]
    local user="${1:-root}" comment="${2:-shieldpress-$user@$(hostname)-$(date +%Y%m%d)}" from="$3" mode="$4" tmp rc
    id "$user" >/dev/null 2>&1 || { fail "User '$user' does not exist"; return 1; }
    sa_init
    tmp=$(mktemp -d /dev/shm/sp-key.XXXXXX 2>/dev/null || mktemp -d /tmp/sp-key.XXXXXX) || return 1
    chmod 700 "$tmp"
    if [ "$mode" = "batch" ]; then
        ssh-keygen -q -t ed25519 -a 64 -N "" -C "$comment" -f "$tmp/key" >/dev/null 2>&1 || { rm -rf "$tmp"; fail "ssh-keygen failed"; return 1; }
    else
        echo "  Choose a passphrase for the private key (recommended; press Enter for none)."
        ssh-keygen -t ed25519 -a 64 -C "$comment" -f "$tmp/key" || { rm -rf "$tmp"; fail "ssh-keygen failed"; return 1; }
    fi
    sa_append_pub "$user" "$(cat "$tmp/key.pub")" "$from"; rc=$?
    if [ $rc -ne 0 ]; then shred -u "$tmp/key" 2>/dev/null; rm -rf "$tmp"; return $rc; fi
    if [ "$mode" = "batch" ]; then
        cat "$tmp/key"
    else
        ok "Public key added to $(sa_home "$user")/.ssh/authorized_keys for user '$user'."
        echo ""
        echo -e "  ${YELLOW}${BOLD}COPY THE PRIVATE KEY below and save it on your computer (chmod 600). It is shown ONCE and is not kept on the server:${RESET}"
        echo "  ----------------------------------------------------"
        cat "$tmp/key"
        echo "  ----------------------------------------------------"
        local saved; read -p "  Have you saved the private key safely? (yes/no): " saved
        if [ "$saved" != "yes" ]; then
            warn "Not confirmed: removing the new public key so nothing is left that nobody can use."
            sa_modify delete "$(sa_key_id "$user" "$(sa_home "$user")/.ssh/authorized_keys" "$SA_LAST_FP")" force >/dev/null
        fi
    fi
    shred -u "$tmp/key" 2>/dev/null; rm -rf "$tmp"
    return 0
}

# ---------------------------------------------------
# Login history and command activity (persistent)
# ---------------------------------------------------

sa_epoch(){ date -d "$1" +%s 2>/dev/null; }

sa_collect(){
    sa_init
    touch "$SA_LOGINS" "$SA_CMDS"; chmod 600 "$SA_LOGINS" "$SA_CMDS"
    command -v journalctl >/dev/null 2>&1 || { fail "journalctl not available"; return 1; }
    local first=0 line ts epoch user ip port method fp tmp
    [ -f "$SA_DIR/.wtmp-imported" ] || first=1
    # 1) accepted logins from the sshd journal (continues from the saved cursor)
    journalctl _COMM=sshd _COMM=sshd-session -o short-iso --no-pager -q --cursor-file="$SA_DIR/cursor.sshd" 2>/dev/null \
      | grep -E ' Accepted [a-z-]+ for ' | while IFS= read -r line; do
        ts="${line%% *}"; epoch=$(sa_epoch "$ts"); [ -n "$epoch" ] || continue
        if [[ "$line" =~ Accepted\ ([a-z-]+(/[a-z]+)?)\ for\ ([^\ ]+)\ from\ ([0-9a-fA-F:.]+)\ port\ ([0-9]+) ]]; then
            method="${BASH_REMATCH[1]}"; user="${BASH_REMATCH[3]}"; ip="${BASH_REMATCH[4]}"; port="${BASH_REMATCH[5]}"
            fp=""; [[ "$line" =~ (SHA256:[A-Za-z0-9+/=]+) ]] && fp="${BASH_REMATCH[1]}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$ts" "$user" "$ip" "$port" "$method" "${fp:--}" "journal" >> "$SA_LOGINS"
        fi
    done
    # 2) one-time import of the existing wtmp history (older than the journal)
    if [ "$first" = 1 ] && command -v last >/dev/null 2>&1; then
        tmp=$(mktemp)
        last -F -w -i 2>/dev/null | awk '$1!="reboot" && $1!="wtmp" && $1!="" && $3 ~ /^[0-9a-fA-F:.]+$/ && $3 != "0.0.0.0" {
            printf "%s\t%s %s %s %s\t%s\t%s\n", $1, $4,$5,$6,$7,$8, $3, $2 }' > "$tmp"
        # awk output: user, "Day Mon dd HH:MM:SS", year, ip, tty
        while IFS=$'\t' read -r user dt year ip tty; do
            epoch=$(sa_epoch "$dt $year"); [ -n "$epoch" ] || continue
            # Skip when the journal already recorded this login (within 10 s)
            awk -F'\t' -v u="$user" -v ip="$ip" -v e="$epoch" '$3==u && $4==ip && ($1-e<=10 && e-$1<=10){f=1} END{exit !f}' "$SA_LOGINS" && continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$(date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z')" "$user" "$ip" "-" "unknown" "-" "wtmp" >> "$SA_LOGINS"
        done < "$tmp"
        rm -f "$tmp"; touch "$SA_DIR/.wtmp-imported"
    fi
    # 3) commands recorded by the optional profile.d hook (tag sp-shell)
    journalctl -t sp-shell -o short-iso --no-pager -q --cursor-file="$SA_DIR/cursor.cmd" 2>/dev/null \
      | grep ' sp-shell' | while IFS= read -r line; do
        ts="${line%% *}"; epoch=$(sa_epoch "$ts"); [ -n "$epoch" ] || continue
        if [[ "$line" =~ user=([^\ ]+)\ ip=([^\ ]*)\ sid=([0-9]+)\ tty=([^\ ]+)\ pwd=(.*)\ cmd=(.*)$ ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$ts" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]:--}" \
                "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]//$'\t'/ }" "${BASH_REMATCH[6]//$'\t'/ }" >> "$SA_CMDS"
        fi
    done
    # 4) keep sorted, unique and bounded
    local cutoff=$(( $(date +%s) - SA_RETENTION_DAYS*86400 ))
    for f in "$SA_LOGINS" "$SA_CMDS"; do
        tmp=$(mktemp); sort -n "$f" | uniq | awk -F'\t' -v c="$cutoff" '$1>=c' > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    done
}

sa_history(){   # user|all  limit
    local user="${1:-root}" limit="${2:-30}"
    [ -f "$SA_LOGINS" ] || { info "No history yet. Enable recording (Recording settings) or run --collect."; return 0; }
    echo ""
    echo "======================================"
    echo "  LOGIN HISTORY ($user)"
    echo "======================================"
    printf "  ${BOLD}%-19s %-9s %-16s %-10s %-8s %s${RESET}\n" TIME USER "SOURCE IP" METHOD SOURCE "KEY"
    local keymap; keymap=$(sa_list_tsv | awk -F'\t' '{print $8"\t"$10}')
    awk -F'\t' -v u="$user" '
        { key=$3" "$4; if(!(key in seen)){seen[key]=1; first[NR]=1} }
        u=="all" || $3==u { print $0 "\t" ((NR in first) ? "NEW-IP" : "") }' "$SA_LOGINS" | tail -n "$limit" \
    | while IFS=$'\t' read -r epoch iso usr ip port method fp src newip; do
        local kc=""
        [ "$fp" = "-" ] && fp=""
        [ -n "$fp" ] && kc=$(awk -F'\t' -v fp="$fp" '$1==fp {print $2; exit}' <<< "$keymap")
        printf "  %-19s %-9s %-16s %-10s %-8s %s${YELLOW}%s${RESET}\n" "${iso:0:19}" "$usr" "$ip" "$method" "$src" \
            "${fp:+${fp:0:20}... ${kc:+($kc)}}" "${newip:+  $newip}"
    done
    echo ""
    info "NEW-IP = first time this user was seen from that address in the recorded history."
}

sa_activity(){   # user|all limit
    local user="${1:-root}" limit="${2:-50}"
    [ -f "$SA_CMDS" ] && [ -s "$SA_CMDS" ] || { info "No commands recorded. Enable command recording first (Recording settings)."; return 0; }
    echo ""
    echo "======================================"
    echo "  COMMAND ACTIVITY ($user) - interactive SSH shells"
    echo "======================================"
    awk -F'\t' -v u="$user" 'u=="all" || $3==u' "$SA_CMDS" | tail -n "$limit" \
    | awk -F'\t' '{ s=$4"|"$5; if (s!=last) { printf "\n  == %s  %s from %s (session %s, %s)\n", substr($2,1,19), $3, $4, $5, $6; last=s }
                   printf "  %s  [%s] %s\n", substr($2,12,8), $7, $8 }'
    echo ""
}

# ---------------------------------------------------
# Recording on/off
# ---------------------------------------------------

sa_history_enabled(){ systemctl is-enabled --quiet sp-ssh-access.timer 2>/dev/null; }
sa_activity_enabled(){ [ -f "$SA_PROFILE" ]; }

sa_enable_history(){
    sa_init
    cat > "$SA_SERVICE" <<EOF
[Unit]
Description=ShieldPress SSH login history collector

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --collect
EOF
    cat > "$SA_TIMER" <<EOF
[Unit]
Description=ShieldPress SSH login history collector timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now sp-ssh-access.timer >/dev/null 2>&1 || { fail "Cannot enable sp-ssh-access.timer"; return 1; }
    # First collection now, so the existing history is available immediately
    bash "$SELF" --collect || warn "First collection failed; the timer will retry"
    sa_log "login history recording enabled"
    ok "Login history recording enabled (collected every 2 minutes, kept $SA_RETENTION_DAYS days)."
}

sa_disable_history(){
    systemctl disable --now sp-ssh-access.timer >/dev/null 2>&1
    rm -f "$SA_TIMER" "$SA_SERVICE"; systemctl daemon-reload 2>/dev/null
    sa_log "login history recording disabled"
    ok "Login history recording disabled (existing history is kept in $SA_DIR)."
}

sa_enable_activity(){
    cat > "$SA_PROFILE" <<'EOF'
# ShieldPress: record commands typed in interactive bash sessions opened over SSH.
# Written by `ssh-access.sh --enable-activity`; remove with `--disable-activity`.
if [ -n "$BASH_VERSION" ] && [ -n "$SSH_CONNECTION" ] && [[ $- == *i* ]] && command -v logger >/dev/null 2>&1; then
    __sp_last=""
    __sp_audit(){
        local n c
        n=$(HISTTIMEFORMAT= builtin history 1 | awk '{print $1}')
        [ -n "$n" ] && [ "$n" != "$__sp_last" ] || return 0
        __sp_last="$n"
        c=$(HISTTIMEFORMAT= builtin history 1 | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' \
            | sed -E 's/((--?(password|passwd|pass|token|secret|api[-_]?key)[= ]|-p)[^ ]*)/[REDACTED]/Ig; s/((PASSWORD|PASSWD|PWD|TOKEN|SECRET|KEY)[A-Z_]*=)[^ ]+/\1[REDACTED]/g')
        logger -t sp-shell -p authpriv.info -- "user=$USER ip=${SSH_CONNECTION%% *} sid=$$ tty=$(tty 2>/dev/null | sed 's|/dev/||') pwd=$PWD cmd=$c"
    }
    case ";$PROMPT_COMMAND;" in *";__sp_audit;"*) ;; *) PROMPT_COMMAND="__sp_audit${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;; esac
fi
EOF
    chmod 644 "$SA_PROFILE"; command -v restorecon >/dev/null 2>&1 && restorecon "$SA_PROFILE" 2>/dev/null
    sa_history_enabled || sa_enable_history
    sa_log "command recording enabled"
    ok "Command recording enabled for NEW interactive SSH bash sessions."
    info "Limits: it records typed commands only (not output, scp/sftp or 'ssh host command'), and a user with root"
    info "can bypass it. Passwords in common command-line forms are masked. Stored in $SA_DIR (mode 600)."
}

sa_disable_activity(){
    rm -f "$SA_PROFILE"
    sa_log "command recording disabled"
    ok "Command recording disabled for new sessions (existing records are kept)."
}

sa_status(){
    echo ""
    printf "  %-26s: %s\n" "Login history recording" "$(sa_history_enabled && echo enabled || echo disabled)"
    printf "  %-26s: %s\n" "Command recording" "$(sa_activity_enabled && echo enabled || echo disabled)"
    printf "  %-26s: %s\n" "Retention" "$SA_RETENTION_DAYS days"
    printf "  %-26s: %s\n" "Recorded logins" "$( [ -f "$SA_LOGINS" ] && wc -l < "$SA_LOGINS" || echo 0)"
    printf "  %-26s: %s\n" "Recorded commands" "$( [ -f "$SA_CMDS" ] && wc -l < "$SA_CMDS" || echo 0)"
}

# ---------------------------------------------------
# Menu
# ---------------------------------------------------

sa_pick_id(){
    local id; read -p "  Key ID (from the list): " id
    echo "$id"
}

sa_menu(){
    local sub id user comment from pub
    while true; do
        echo ""
        sp_title 'SSH Access'
        sa_status
        echo ""
        echo "  1) List SSH keys (all users)"
        echo "  2) Key details and last use"
        echo "  3) Create a new key pair"
        echo "  4) Add an existing public key"
        echo "  5) Revoke a key (disable, reversible)"
        echo "  6) Restore a revoked key"
        echo "  7) Delete a key permanently"
        echo "  8) Login history"
        echo "  9) Command activity"
        echo " 10) Recording settings"
        echo "  0) Back"
        echo ""
        read -p "Select: " sub
        case "${sub}" in 0|"") return 0 ;; esac
        case "$sub" in
            1) sa_list ;;
            2) sa_list; id=$(sa_pick_id); sa_show "$id" ;;
            3) read -p "  User to log in as [root]: " user; user="${user:-root}"
               read -p "  Comment [shieldpress-$user@$(hostname)]: " comment
               read -p "  Restrict to source IP/CIDR (from=, empty = anywhere): " from
               [ -z "$from" ] && [ "$user" = "root" ] && warn "No from= limit: this key can log in as root from any address."
               sa_create "$user" "${comment:-shieldpress-$user@$(hostname)}" "$from" ;;
            4) read -p "  User [root]: " user; user="${user:-root}"
               read -p "  Paste the public key: " pub
               read -p "  Restrict to source IP/CIDR (from=, empty = anywhere): " from
               sa_append_pub "$user" "$pub" "$from" && ok "Public key added for $user" ;;
            5) sa_list; id=$(sa_pick_id); sa_modify revoke "$id" ;;
            6) sa_list; id=$(sa_pick_id); sa_modify restore "$id" ;;
            7) sa_list; id=$(sa_pick_id)
               read -p "  Type DELETE to remove key $id permanently (a backup is kept): " pub
               [ "$pub" = "DELETE" ] && sa_modify delete "$id" || echo "  Cancelled." ;;
            8) read -p "  User [root] (or 'all'): " user; sa_history "${user:-root}" 40 ;;
            9) read -p "  User [root] (or 'all'): " user; sa_activity "${user:-root}" 60 ;;
            10) echo "  1) Enable login history   2) Disable login history"
                echo "  3) Enable command record  4) Disable command record"
                read -p "  Select: " pub
                case "$pub" in 1) sa_enable_history ;; 2) sa_disable_history ;; 3) sa_enable_activity ;; 4) sa_disable_activity ;; esac ;;
            0) break ;;
            *) echo "Invalid" ;;
        esac
        echo ""; read -p "Press Enter..."
    done
}

main(){
    [ "$EUID" -eq 0 ] || { fail "Run as root"; exit 1; }
    sa_init
    case "$1" in
        --list) sa_list "$2" ;;
        --show) sa_show "$2" ;;
        --create) sa_create "$2" "$3" "$4" batch ;;
        --add-pub) sa_append_pub "$2" "$3" "$4" && ok "Public key added for $2" ;;
        --revoke) sa_modify revoke "$2" "$3" ;;
        --restore) sa_modify restore "$2" "$3" ;;
        --delete) if [ "$3" = "--force" ]; then sa_modify delete "$2" force; else sa_modify delete "$2"; fi ;;
        --collect) sa_collect ;;
        --history) sa_history "${2:-root}" "${3:-30}" ;;
        --activity) sa_activity "${2:-root}" "${3:-50}" ;;
        --enable-history) sa_enable_history ;;
        --disable-history) sa_disable_history ;;
        --enable-activity) sa_enable_activity ;;
        --disable-activity) sa_disable_activity ;;
        --status) sa_status ;;
        "") sa_menu ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
}

# Allow tests to source the functions without running anything
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
