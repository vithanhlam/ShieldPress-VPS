#!/bin/bash
# Service-local entrypoint; each transaction remains interactive and confirmed.
set -uo pipefail
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
service="${1:-}"
case "$service" in nginx|php|mariadb|postgresql) ;; *) echo '[FAIL] Unknown service'; exit 2 ;; esac
python=/usr/bin/python3
if ! "$python" -c 'import dnf, rpm' 2>/dev/null; then
    echo '[FAIL] System Python DNF/RPM bindings are required; restore the AlmaLinux package tools.'
    exit 1
fi
mkdir -p "$DATA_DIR" "$LOG_DIR" || exit 1
export SHIELDPRESS_UPDATE_TTY=0
[ ! -t 1 ] || export SHIELDPRESS_UPDATE_TTY=1
service_update_run(){
    PYTHONUNBUFFERED=1 "$python" "$BASE_DIR/modules/upgrade/service-updates.py" "$service" "$action" \
        2>&1 | tee -a "$LOG_DIR/service-updates.log"
    return "${PIPESTATUS[0]}"
}
while true; do
    clear
    sp_header "$service Version & Security Updates" "Repository advisories and same-branch updates"
    sp_menu_grid \
        "1|Check Versions & CVE Advisories|cyan" \
        "2|Apply Repository Security Updates|green" \
        "3|Apply All Same-Branch Updates|yellow" \
        "0|Back|white"
    sp_prompt choice
    case "$choice" in
        1) action=check ;;
        2) action=security ;;
        3) action=update ;;
        0) break ;;
        *) sp_invalid; continue ;;
    esac
    # Keep stdin attached for branch selection and transaction confirmation.
    status=0
    service_update_run || status=$?
    if [ "$status" -ne 0 ]; then
        echo "[WARN] Check/update did not complete (exit $status). Review the errors above."
    fi
    read -r -p 'Press Enter...'
done
