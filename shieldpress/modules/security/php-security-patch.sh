#!/bin/bash
# PHP CVE-2026-109618 / CVE-2026-109619. No exploit traffic is sent.
# Only update existing Remi branches; preserve versionlocks and inactive services.
set -uo pipefail

php_security_fixed(){
    local version="$1" minimum
    case "$version" in
        8.2.*) minimum=8.2.35 ;;
        8.3.*) minimum=8.3.36 ;;
        8.4.*) minimum=8.4.27 ;;
        8.5.*) minimum=8.5.12 ;;
        *) return 1 ;;
    esac
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [ "$(printf '%s\n' "$minimum" "$version" | sort -V | head -1)" = "$minimum" ]
}

php_security_main(){
    local mode="${1:---audit}" bin version branch svc active status=0 found=0 updated
    case "$mode" in --audit|--apply) ;; *) echo 'Usage: php-security-patch.sh --audit|--apply'; return 2 ;; esac
    if [ "$mode" = --apply ]; then
        [ "$EUID" -eq 0 ] || { echo '[FAIL] Root is required'; return 1; }
        command -v dnf >/dev/null || { echo '[FAIL] DNF unavailable'; return 1; }
        # Serialize with other invocations without changing persistent versionlocks.
        exec 9>/run/shieldpress-php-security.lock
        flock -n 9 || { echo '[WARN] Another PHP security patch is running'; return 1; }
    fi
    for bin in /opt/remi/php*/root/usr/bin/php; do
        [ -x "$bin" ] || continue
        found=1
        branch=${bin#/opt/remi/php}; branch=${branch%%/*}
        [[ "$branch" =~ ^[0-9]{2}$ ]] || continue
        # Reapply managed entrypoints after RPM transactions, or promote an already tested build.
        if [ "$mode" = --apply ] && [ "$branch" = 84 ] && { [ -f /var/shieldpress/data/php-source-84/active ] || [ -x /opt/shieldpress-php/8.4.27/bin/php ]; }; then
            if bash /opt/shieldpress/modules/security/php84-source-patch.sh; then
                continue
            else
                status=1
                continue
            fi
        fi
        version=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null) || { status=1; continue; }
        if php_security_fixed "$version"; then
            echo "[OK] PHP $version meets the upstream security baseline"
            continue
        fi
        echo "[WARN] PHP $version: fixes not verified for CVE-2026-109618 / CVE-2026-109619; vendor backports need separate verification"
        if [ "$mode" = --audit ]; then status=1; continue; fi
        case "$branch" in 82|83|84|85) ;; *) echo '[WARN] Unsupported branch: migrate to a supported PHP branch'; status=1; continue ;; esac
        svc="php${branch}-php-fpm"
        active=0
        systemctl is-active --quiet "$svc" && active=1
        updated=0
        # The glob is passed literally to DNF; no global unlock or branch switch.
        if dnf --refresh --setopt=timeout=20 --setopt=retries=1 --disableplugin=versionlock upgrade -y "php${branch}-*"; then
            updated=1
        else
            echo "[FAIL] Package transaction failed for PHP $branch"
        fi
        # Also recover workers after a partially failed package transaction.
        if [ "$active" -eq 1 ]; then
            if "/opt/remi/php${branch}/root/usr/sbin/php-fpm" -t && systemctl restart "$svc" && systemctl is-active --quiet "$svc"; then
                echo "[OK] $svc workers restarted"
            else
                echo "[FAIL] $svc requires immediate service recovery"
                status=1
            fi
        fi
        version=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null) || version=unknown
        if [ "$branch" = 84 ] && ! php_security_fixed "$version"; then
            echo '[INFO] Remi security baseline unavailable; building the official PHP 8.4 source release'
            if bash /opt/shieldpress/modules/security/php84-source-patch.sh; then
                version=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null) || version=unknown
                updated=1
            fi
        fi
        if [ "$updated" -eq 1 ] && php_security_fixed "$version"; then
            echo "[OK] PHP $version security baseline verified"
        else
            echo "[WARN] PHP $version remains unverified; repository fix may be unavailable. Retry after the repository publishes it."
            status=1
        fi
    done
    [ "$found" -eq 1 ] || echo '[INFO] No Remi PHP installation found'
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    php_security_main "$@"
fi
