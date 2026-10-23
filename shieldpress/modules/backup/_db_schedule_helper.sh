#!/bin/bash
# Shared schedule prompts for individual and bulk database setup.
db_backup_read_number(){
    local name="$1" prompt="$2" default="$3" minimum="$4" maximum="$5" value
    while true; do
        read -rp "$prompt [$default]: " value || return 1
        value="${value:-$default}"
        if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]; then
            printf -v "$name" '%d' "$((10#$value))"
            return 0
        fi
        echo "Enter a number between $minimum and $maximum"
    done
}
db_backup_schedule(){
    if [ "$#" -eq 0 ]; then
        db_backup_read_number RETENTION "Keep how many local DB backups? (1-60)" 1 1 60 || return 1
        db_backup_read_number HOUR "Backup hour (0-23)" 23 0 23 || return 1
        echo ""
        echo "Frequency:"
        echo "1) Daily"
        echo "2) Weekly"
        echo "3) Monthly"
        db_backup_read_number FREQ "Select" 1 1 3 || return 1
        DOW=0
        DOM=1
        case "$FREQ" in
            2) db_backup_read_number DOW "Day of week (0=Sun, 6=Sat)" 0 0 6 || return 1 ;;
            3) db_backup_read_number DOM "Day of month (1-28)" 1 1 28 || return 1 ;;
        esac
    else
        RETENTION="$1" HOUR="$2" FREQ="$3" DOW="${4:-0}" DOM="${5:-1}"
        local spec value minimum maximum
        for spec in "$RETENTION:1:60" "$HOUR:0:23" "$FREQ:1:3" "$DOW:0:6" "$DOM:1:28"; do
            IFS=: read -r value minimum maximum <<< "$spec"
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
                echo "Invalid shared backup schedule."
                return 1
            fi
        done
    fi
    case "$FREQ" in
        1) CRON_TIME="0 $HOUR * * *" ;;
        2) CRON_TIME="0 $HOUR * * $DOW" ;;
        3) CRON_TIME="0 $HOUR $DOM * *" ;;
    esac
}
