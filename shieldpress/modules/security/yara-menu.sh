#!/bin/bash
# Report-only malware scanning. Never remove or quarantine website files.
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/paths.sh"
export BASE_DIR DOMAINS_ROOT LOG_DIR ETC_DIR
SCANNER="$BASE_DIR/modules/security/yara-scan.py"

install_yara(){
    if command -v yara >/dev/null && command -v yarac >/dev/null; then
        echo "YARA $(yara --version) is installed."
        return
    fi
    echo "Install the YARA CLI and compiler from configured OS repositories."
    echo "No background scanner is installed or enabled by this action."
    local answer
    read -r -p "Install YARA? [y/N]: " answer
    [[ "${answer,,}" = y || "${answer,,}" = yes ]] || return 0
    if command -v dnf >/dev/null; then
        dnf install -y yara || return 1
    elif command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y yara || return 1
    else
        echo "[FAIL] Install yara and yarac using your OS package manager."
        return 1
    fi
    command -v yara >/dev/null && command -v yarac >/dev/null || return 1
    echo "[OK] YARA installed. Automatic scanning remains disabled until configured."
}

choose_scan(){
    local choice folder domain stack i=1
    local -a folders=()
    echo "0) All registered domains"
    while IFS=$'\t' read -r folder domain stack; do
        [ -n "$folder" ] || continue
        folders[$i]="$folder"
        printf '%s) %s (%s)\n' "$i" "$domain" "$stack"
        ((i++))
    done < <(python3 "$SCANNER" list)
    read -r -p "Select domain number (blank cancels): " choice
    [ -n "$choice" ] || return 0
    if [ "$choice" = 0 ]; then
        python3 "$SCANNER" scan all
    elif [[ "$choice" =~ ^[1-9][0-9]{0,4}$ ]] && [ -n "${folders[$choice]:-}" ]; then
        python3 "$SCANNER" scan "${folders[$choice]}"
    else
        echo "[FAIL] Invalid domain selection."
    fi
}

configure_scan(){
    local schedule hour answer
    echo "1) Daily (default)"
    echo "2) Weekly (Sunday)"
    echo "0) Disable scheduled scans"
    read -r -p "Schedule [1]: " schedule
    case "${schedule:-1}" in
        1) schedule=daily ;;
        2) schedule=weekly ;;
        0) python3 "$SCANNER" configure off; return ;;
        *) echo "[FAIL] Invalid schedule."; return 1 ;;
    esac
    read -r -p "Hour in server timezone (0-23) [3]: " hour
    hour="${hour:-3}"
    [[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { echo "[FAIL] Invalid hour."; return 1; }
    echo "Telegram requires Notifications > Telegram enabled with Security Alerts enabled."
    read -r -p "Send a Telegram summary after each scan? [y/N]: " answer
    local -a args=(configure "$schedule" --hour "$hour")
    [[ "${answer,,}" = y || "${answer,,}" = yes ]] && args+=(--notify)
    python3 "$SCANNER" "${args[@]}"
}

while true; do
    echo ""
    echo "================ YARA MALWARE SCAN ================"
    echo "Report only: no deletion, quarantine, or file uploads."
    echo "Starter rules have limited coverage; review all findings."
    echo "Default limits: 16 MiB/file, 256 MiB/engine, 15 minutes/run."
    echo "Reports: $LOG_DIR/yara (latest 30 reports retained)."
    echo "Configuration: $ETC_DIR/yara.json"
    echo "1) Install / check YARA"
    echo "2) Scan now (domain or all)"
    echo "3) Configure automatic scans and reports"
    echo "4) View latest report"
    echo "5) View schedule status"
    echo "0) Back"
    read -r -p "Select: " choice || break
    case "$choice" in
        1) install_yara ;;
        2)
            # Findings (1) and incomplete scans (2) are expected scanner outcomes.
            # Handle them explicitly so inherited errexit cannot close the menu.
            if choose_scan; then
                :
            else
                status=$?
                case "$status" in
                    1) echo "[WARN] Findings detected. Review the saved report." ;;
                    *) echo "[WARN] Scan did not complete (exit $status). Review the error and latest report; you can retry from this menu." ;;
                esac
            fi
            ;;
        3) configure_scan ;;
        4) python3 "$SCANNER" report ;;
        5) systemctl list-timers --all shieldpress-yara.timer --no-pager ;;
        0) break ;;
        *) echo "[FAIL] Invalid selection." ;;
    esac
    read -r -p "Press Enter to continue..." || break
done
