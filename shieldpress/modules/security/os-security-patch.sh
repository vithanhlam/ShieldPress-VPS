#!/bin/bash
# OS security updates, run automatically after every ShieldPress update.
# Security advisories only (upgrade-minimal), never a full `dnf update`.
# Nginx/PHP/MariaDB/PostgreSQL/Node.js are excluded: they go through the
# Upgrade Manager (backup + version policy) and php-security-patch.sh.
# Valkey stays on its installed major branch and is restarted only if updated.
# Opt out: OS_SECURITY_AUTO_UPDATE="no" in config/upgrade-policy.conf.
set -uo pipefail

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/task-progress.sh"
POLICY_FILE="$BASE_DIR/config/upgrade-policy.conf"
OS_SECURITY_LOG="$LOG_DIR/os-security.log"
MANAGED_EXCLUDES=(
    --exclude='nginx' --exclude='nginx-core' --exclude='nginx-mod-*'
    --exclude='php8*-*'
    --exclude='mariadb' --exclude='mariadb-*'
    --exclude='postgresql*'
    --exclude='nodejs' --exclude='nodejs-*' --exclude='npm'
)

os_security_enabled(){
    local value=""
    [ -f "$POLICY_FILE" ] && value=$(sed -n 's/^OS_SECURITY_AUTO_UPDATE="\{0,1\}\([A-Za-z]*\)"\{0,1\}$/\1/p' "$POLICY_FILE" | tail -1)
    [ "${value,,}" != "no" ]
}

# DNF output goes to the log so the loading indicator stays readable.
logged(){
    echo "=== $(date '+%F %T') $*" >>"$OS_SECURITY_LOG"
    "$@" >>"$OS_SECURITY_LOG" 2>&1
}

show_log_tail(){
    tail -n 15 "$OS_SECURITY_LOG" 2>/dev/null | sed 's/^/  /'
}

valkey_version(){
    rpm -q valkey >/dev/null 2>&1 || return 1
    rpm -q --qf '%{VERSION}-%{RELEASE}' valkey
}

os_security_main(){
    local mode="${1:---audit}" status=0 before after candidate valkey_active=0 services
    case "$mode" in --audit|--apply) ;; *) echo 'Usage: os-security-patch.sh --audit|--apply'; return 2 ;; esac
    command -v dnf >/dev/null || { echo '[WARN] DNF unavailable; OS security step skipped'; return 1; }

    if [ "$mode" = --audit ]; then
        before=$(valkey_version) && echo "[INFO] Valkey package: $before"
        if dnf -q updateinfo list --security "${MANAGED_EXCLUDES[@]}" 2>/dev/null | grep -q .; then
            echo '[WARN] OS security advisories pending; they are applied on the next ShieldPress update'
            return 1
        fi
        echo '[OK] No pending OS security advisories'
        return 0
    fi

    [ "$EUID" -eq 0 ] || { echo '[FAIL] Root is required'; return 1; }
    if ! os_security_enabled; then
        echo '[INFO] OS security auto-update disabled by upgrade policy'
        return 0
    fi
    exec 8>/run/shieldpress-os-security.lock
    flock -n 8 || { echo '[WARN] Another OS security update is running'; return 1; }

    before=$(valkey_version || true)
    systemctl is-active --quiet valkey 2>/dev/null && valkey_active=1

    mkdir -p "$LOG_DIR"
    if run_with_loading "Applying OS security advisories" "$DATA_DIR/os-security.time" 120 \
            logged dnf --refresh --setopt=timeout=20 --setopt=retries=1 --setopt=skip_if_unavailable=true \
            -y upgrade-minimal --security "${MANAGED_EXCLUDES[@]}"; then
        echo "[OK] OS security advisories applied (details: $OS_SECURITY_LOG)"
    else
        echo '[FAIL] OS security transaction failed; DNF rolls back incomplete transactions'
        show_log_tail
        status=1
    fi

    # Some repositories (e.g. EPEL) ship Valkey fixes without advisory metadata.
    if [ -n "$before" ]; then
        candidate=$(dnf -q repoquery --upgrades --latest-limit=1 --qf '%{version}' valkey 2>/dev/null | tail -1)
        if [ -n "$candidate" ]; then
            if [ "${candidate%%.*}" = "${before%%.*}" ]; then
                if ! run_with_loading "Updating Valkey to ${candidate}" "$DATA_DIR/os-security-valkey.time" 30 \
                        logged dnf -y upgrade "valkey-${candidate}"; then
                    echo '[FAIL] Valkey package update failed'
                    show_log_tail
                    status=1
                fi
            else
                echo "[WARN] Valkey ${candidate} is a new major branch; not applied automatically"
            fi
        fi
    fi

    after=$(valkey_version || true)
    if [ -n "$before" ] && [ "$after" != "$before" ]; then
        echo "[OK] Valkey package: $before -> $after"
        if [ "$valkey_active" -eq 1 ]; then
            if systemctl restart valkey && systemctl is-active --quiet valkey; then
                echo '[OK] Valkey restarted'
            else
                echo '[FAIL] Valkey failed to restart; check: journalctl -u valkey'
                status=1
            fi
        fi
    fi

    # Report (never perform) restarts that updated libraries still need.
    if dnf needs-restarting --help >/dev/null 2>&1; then
        services=$(dnf -q needs-restarting -s 2>/dev/null | grep -v '^valkey' | tr '\n' ' ')
        [ -n "${services// }" ] && echo "[INFO] Services using updated libraries (restart when convenient): $services"
        dnf -q needs-restarting -r >/dev/null 2>&1 || echo '[INFO] A reboot is required to finish kernel/core library updates'
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    os_security_main "$@"
fi
