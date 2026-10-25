#!/bin/bash
# Root control data must never share a writable ancestor with application users.
sp_domain_control(){
    python3 "$BASE_DIR/core/domain-security.py" "$1" "$DOMAINS_ROOT" "${2%/}"
}

sp_secure_domain_control(){
    local sp_path="${1%/}"
    [ "${sp_path%/*}" = "$DOMAINS_ROOT" ] || return 1
    sp_domain_control repair "${sp_path##*/}"
}

sp_load_domain_env(){
    local sp_path="${1%/}" sp_temp sp_key sp_value
    [ "${sp_path%/*}" = "$DOMAINS_ROOT" ] || return 1
    sp_temp=$(mktemp) || return 1
    if ! sp_domain_control env "${sp_path##*/}" > "$sp_temp"; then
        rm -f -- "$sp_temp"
        return 1
    fi
    while IFS= read -r -d '' sp_key && IFS= read -r -d '' sp_value; do
        printf -v "$sp_key" '%s' "$sp_value"
    done < "$sp_temp"
    rm -f -- "$sp_temp"
}

sp_backup_targets(){
    local sp_temp sp_target
    SP_BACKUP_TARGETS=()
    sp_temp=$(mktemp) || return 1
    if ! python3 "$BASE_DIR/core/domain-security.py" targets "$1" "$2" > "$sp_temp"; then
        rm -f -- "$sp_temp"
        return 1
    fi
    while IFS= read -r -d '' sp_target; do SP_BACKUP_TARGETS+=("$sp_target"); done < "$sp_temp"
    rm -f -- "$sp_temp"
    [ "${#SP_BACKUP_TARGETS[@]}" -gt 0 ]
}

sp_write_backup_job(){
    local sp_folder="$1" sp_kind="$2" sp_mode="$3" sp_keep="$4"
    [[ "$sp_folder" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,63}$ ]] || return 1
    [[ "$sp_kind" =~ ^(db|files|full)$ && "$sp_mode" =~ ^(full|incremental)$ ]] || return 1
    [[ "$sp_keep" =~ ^[0-9]+$ ]] && [ "$sp_keep" -ge 1 ] && [ "$sp_keep" -le 60 ] || return 1
    local sp_jobs="${ETC_DIR:-/etc/shieldpress}/jobs" sp_tmp
    [ ! -L "$sp_jobs" ] && [ ! -L "${sp_jobs%/*}" ] || return 1
    install -d -m 700 -o root -g root "$sp_jobs" || return 1
    AUTO_SCRIPT="$sp_jobs/$sp_folder-backup-$sp_kind.sh"
    sp_tmp=$(mktemp "$sp_jobs/.job.XXXXXX") || return 1
    {
        printf '#!/bin/bash\n'
        printf 'exec /bin/bash %q %q %q %q %q\n' "$BASE_DIR/bin/domain-backup" "$sp_folder" "$sp_kind" "$sp_mode" "$sp_keep"
    } > "$sp_tmp"
    chmod 700 "$sp_tmp" && chown root:root "$sp_tmp" && mv -fT -- "$sp_tmp" "$AUTO_SCRIPT"
}
