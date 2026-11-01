#!/bin/bash
# =====================================================
# ShieldPress VPS - Auto-Update manager
#   shieldpress autoupdate                      interactive menu
#   shieldpress autoupdate on|off|status|run
#   shieldpress autoupdate set <daily|weekly|monthly> <HH:MM> [weekday|day]
#     weekday: 0-6 or sun..sat   day: 1-28
# =====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
source "$BASE_DIR/core/autoupdate.sh"
source "$BASE_DIR/modules/helpers/task-progress.sh"

pause(){ echo ""; read -r -p "Press Enter..."; }

# Accepts 0-6 or a day name (sun, monday, ...). Prints 0-6.
parse_weekday(){
    local v="${1,,}" i
    [[ "$v" =~ ^[0-6]$ ]] && { echo "$v"; return 0; }
    for i in 0 1 2 3 4 5 6; do
        local name="${AU_WEEKDAY_NAMES[$i],,}"
        if [ -n "$v" ] && [ "${#v}" -ge 3 ] && [ "${name#"$v"}" != "$name" ]; then
            echo "$i"; return 0
        fi
    done
    return 1
}

save_and_apply(){
    au_save || { echo "[ERROR] Cannot write $AU_CONF"; return 1; }
    au_apply || { echo "[ERROR] Cannot update $AU_CRON_FILE"; return 1; }
}

show_status(){
    au_load
    local state schedule
    if [ "$AU_ENABLED" = "1" ]; then state="${SP_GREEN}ON${SP_RESET}"; else state="${SP_YELLOW}OFF${SP_RESET}"; fi
    schedule="$(au_describe)"
    echo -e "  Auto-Update : $state"
    echo -e "  Schedule    : $schedule (server time: $(date '+%Z %H:%M'))"
    echo -e "  Installed   : $(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo unknown)"
    echo -e "  Last run    : $(au_last_run)"
    echo -e "  Log         : $LOG_DIR/autoupdate.log"
    if [ "$AU_ENABLED" = "1" ] && [ ! -f "$AU_CRON_FILE" ]; then
        echo -e "  ${SP_YELLOW}[WARN]${SP_RESET} The schedule file is missing; choose any setting to recreate it."
    fi
}

set_enabled(){
    au_load
    AU_ENABLED="$1"
    save_and_apply || return 1
    if [ "$1" = "1" ]; then
        echo "[OK] Auto-Update is ON: $(au_describe)"
    else
        echo "[OK] Auto-Update is OFF"
    fi
}

choose_frequency(){
    local choice day
    au_load
    echo ""
    echo "  1) Daily"
    echo "  2) Weekly"
    echo "  3) Monthly"
    read -r -p "Frequency [1-3, Enter to keep $AU_FREQUENCY]: " choice
    case "$choice" in
        "") return 0 ;;
        1) AU_FREQUENCY="daily" ;;
        2)
            AU_FREQUENCY="weekly"
            read -r -p "Day of week [0=Sunday .. 6=Saturday, or a name; Enter keeps ${AU_WEEKDAY_NAMES[$AU_WEEKDAY]}]: " day
            if [ -n "$day" ]; then
                day=$(parse_weekday "$day") || { echo "[ERROR] Invalid day of week"; return 1; }
                AU_WEEKDAY="$day"
            fi
            ;;
        3)
            AU_FREQUENCY="monthly"
            read -r -p "Day of month [1-28, Enter keeps $AU_MONTHDAY]: " day
            if [ -n "$day" ]; then
                [[ "$day" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || { echo "[ERROR] Day must be 1-28"; return 1; }
                AU_MONTHDAY="$day"
            fi
            ;;
        *) echo "[ERROR] Invalid choice"; return 1 ;;
    esac
    save_and_apply && echo "[OK] Schedule: $(au_describe)"
}

choose_time(){
    local value
    au_load
    read -r -p "Time of day, 24h HH:MM [Enter keeps $AU_TIME]: " value
    [ -n "$value" ] || return 0
    value=$(au_normalize_time "$value") || { echo "[ERROR] Use 24-hour HH:MM, for example 03:30"; return 1; }
    AU_TIME="$value"
    save_and_apply && echo "[OK] Schedule: $(au_describe)"
}

run_check_now(){
    echo ""
    echo "Checking GitHub and updating if a newer version exists."
    echo "Details are written to $LOG_DIR/autoupdate.log"
    local timing_dir="${DATA_DIR:-/var/shieldpress/data}/autoupdate-timing"
    install -d -m 700 "$timing_dir"
    run_with_loading "Auto-Update check" "$timing_dir/run" 60 bash "$AU_RUNNER" --now
    local rc=$?
    echo "Result: $(au_last_run)"
    return "$rc"
}

# ---------- Non-interactive commands ----------
case "${1:-}" in
    "") ;;
    on)     set_enabled 1; exit $? ;;
    off)    set_enabled 0; exit $? ;;
    status) show_status; exit 0 ;;
    run)    run_check_now; exit $? ;;
    set)
        au_load
        case "${2:-}" in daily|weekly|monthly) AU_FREQUENCY="$2" ;; *)
            echo "Usage: shieldpress autoupdate set <daily|weekly|monthly> <HH:MM> [weekday|day]"; exit 1 ;;
        esac
        AU_TIME=$(au_normalize_time "${3:-}") || { echo "[ERROR] Time must be 24-hour HH:MM, for example 03:30"; exit 1; }
        if [ "$AU_FREQUENCY" = "weekly" ] && [ -n "${4:-}" ]; then
            AU_WEEKDAY=$(parse_weekday "$4") || { echo "[ERROR] Invalid day of week"; exit 1; }
        elif [ "$AU_FREQUENCY" = "monthly" ] && [ -n "${4:-}" ]; then
            [[ "$4" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || { echo "[ERROR] Day of month must be 1-28"; exit 1; }
            AU_MONTHDAY="$4"
        fi
        save_and_apply || exit 1
        echo "[OK] Schedule: $(au_describe) (Auto-Update is $([ "$AU_ENABLED" = 1 ] && echo ON || echo OFF))"
        exit 0
        ;;
    -h|--help|help)
        echo "Usage: shieldpress autoupdate [on|off|status|run]"
        echo "       shieldpress autoupdate set <daily|weekly|monthly> <HH:MM> [weekday|day]"
        exit 0
        ;;
    *) echo "Unknown option: $1. Run: shieldpress autoupdate help"; exit 1 ;;
esac

# ---------- Interactive menu ----------
while true; do
    clear
    au_load
    sp_header "Auto-Update" "Updates ShieldPress VPS itself"
    show_status
    sp_hr
    if [ "$AU_ENABLED" = "1" ]; then toggle_label="Turn OFF"; toggle_color="red"; else toggle_label="Turn ON"; toggle_color="green"; fi
    sp_menu_grid \
        "1|$toggle_label|$toggle_color" \
        "2|Frequency (daily/weekly/monthly)|yellow" \
        "3|Time of day|yellow" \
        "4|Check and update now|cyan" \
        "5|View log|blue" \
        "0|Back|white"
    sp_prompt CHOICE

    case "$CHOICE" in
        1) if [ "$AU_ENABLED" = "1" ]; then set_enabled 0; else set_enabled 1; fi; pause ;;
        2) choose_frequency; pause ;;
        3) choose_time; pause ;;
        4) run_check_now; pause ;;
        5) tail -n 40 "$LOG_DIR/autoupdate.log" 2>/dev/null || echo "No Auto-Update log yet."; pause ;;
        0) exit 0 ;;
        *) sp_invalid ;;
    esac
done
