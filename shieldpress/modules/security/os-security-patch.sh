#!/bin/bash
# OS security updates, run automatically after every ShieldPress update.
# OS advisories plus installed kernel package updates, never a full `dnf update`.
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
    --exclude='nginx*'
    --exclude='php' --exclude='php-*' --exclude='php8*-*'
    --exclude='mariadb' --exclude='mariadb-*' --exclude='MariaDB-*'
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

# Kernel fixes can precede updateinfo metadata. Honor normal repository,
# signature, exclude and versionlock settings; never enable testing repositories.
update_kernel_packages(){
    local installed running default_kernel
    if ! installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null); then
        echo '[INFO] No kernel-core RPM installed; kernel updates belong to the host provider'
        return 0
    fi
    running=$(uname -r) || return 1
    echo "[INFO] Running kernel: $running"
    if ! run_with_loading "Updating installed kernel packages (including fixes without advisories)" "$DATA_DIR/os-security-kernel.time" 180 \
            logged dnf --refresh --setopt=timeout=20 --setopt=retries=1 --setopt=skip_if_unavailable=false \
            -y upgrade 'kernel*' "${MANAGED_EXCLUDES[@]}"; then
        echo '[FAIL] Kernel update failed; remediation remains pending'
        show_log_tail
        return 1
    fi
    if ! installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core); then
        echo '[FAIL] Cannot verify installed kernel packages'
        return 1
    fi
    echo "[INFO] Installed kernels: $installed"
    if command -v grubby >/dev/null; then
        if default_kernel=$(grubby --default-kernel); then
            echo "[INFO] Default boot kernel: $default_kernel"
            if [ "${default_kernel##*/}" != "vmlinuz-$running" ]; then
                echo '[WARN] Default boot kernel differs from the running kernel. Schedule a reboot and verify uname -r afterwards; no automatic reboot is performed'
            fi
        else
            echo '[FAIL] Cannot verify the default boot kernel; inspect boot configuration before rebooting'
            return 1
        fi
    else
        echo '[WARN] Cannot inspect the boot default with grubby. Verify provider boot settings before rebooting; no automatic reboot is performed'
    fi
    echo '[INFO] Kernel transaction completed under repository policy; retained locks/excludes can prevent updates. This is not certification of any CVE fix'
}

os_security_main(){
    local mode="${1:---audit}" status=0 before after candidate valkey_active=0 services advisories
    case "$mode" in --audit|--apply) ;; *) echo 'Usage: os-security-patch.sh --audit|--apply'; return 2 ;; esac
    command -v dnf >/dev/null || { echo '[WARN] DNF unavailable; OS security step skipped'; return 1; }

    if [ "$mode" = --audit ]; then
        before=$(valkey_version) && echo "[INFO] Valkey package: $before"
        if ! advisories=$(dnf -q --refresh --setopt=skip_if_unavailable=false updateinfo list --available --security "${MANAGED_EXCLUDES[@]}"); then
            echo '[FAIL] OS advisory query failed; security status is unknown'
            return 1
        fi
        if [ -n "$advisories" ]; then
            echo '[WARN] OS security advisories pending; they are applied on the next ShieldPress update'
            return 1
        fi
        if rpm -q kernel-core >/dev/null 2>&1; then
            local kernel_status=0
            dnf -q --refresh --setopt=skip_if_unavailable=false check-update 'kernel*' || kernel_status=$?
            case "$kernel_status" in
                0) ;;
                100) echo '[WARN] Kernel updates are pending, including possible fixes without advisory metadata'; return 1 ;;
                *) echo '[FAIL] Kernel update query failed; security status is unknown'; return 1 ;;
            esac
        fi
        echo '[INFO] No pending security advisories reported by enabled repositories; this does not prove the OS or email stack has no vulnerabilities'
        echo '[INFO] Version locks and excludes remain active. Verify the running kernel against vendor advisories after reboot'
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
            logged dnf --refresh --setopt=timeout=20 --setopt=retries=1 --setopt=skip_if_unavailable=false \
            -y upgrade-minimal --security "${MANAGED_EXCLUDES[@]}"; then
        echo "[OK] OS security advisories applied (details: $OS_SECURITY_LOG)"
    else
        echo '[FAIL] OS security transaction failed; inspect the log and DNF history for partial changes'
        show_log_tail
        status=1
    fi

    update_kernel_packages || status=1

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
