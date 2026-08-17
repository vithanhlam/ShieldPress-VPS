#!/bin/bash
# Unified auto-backup setup: choose type, then configure schedule

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Auto Backup Setup" "Schedule automated backups"

    echo ""
    echo "  Setup new schedule:"
    sp_menu_grid \
        "1|Auto Backup Database|blue" \
        "2|Auto Backup Files|cyan" \
        "3|Auto Full Backup|green"

    echo ""
    echo "  Manage:"
    sp_menu_grid \
        "4|View All Schedules|yellow" \
        "5|Remove a Schedule|red" \
        "0|Back|white"

    sp_prompt opt

    case $opt in
        1) bash "$BASE_DIR/modules/backup/auto-backup-db.sh" ;;
        2) bash "$BASE_DIR/modules/backup/auto-backup-files.sh" ;;
        3) bash "$BASE_DIR/modules/backup/auto-backup-full.sh" ;;
        4)
            clear
            echo "===================================================="
            echo "           ALL BACKUP SCHEDULES (crontab)"
            echo "===================================================="
            echo ""
            JOBS=$(crontab -l 2>/dev/null | grep -E "auto-backup|backup-telegram")
            if [ -n "$JOBS" ]; then
                echo "$JOBS" | while read -r line; do
                    echo "  $line"
                done
            else
                echo "  No backup schedules found."
            fi
            echo ""
            echo "===================================================="
            read -p "Press Enter..."
            ;;
        5)
            clear
            echo "===================================================="
            echo "           REMOVE BACKUP SCHEDULE"
            echo "===================================================="
            echo ""
            JOBS=()
            i=1
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "$i) $line"
                JOBS[$i]="$line"
                ((i++))
            done < <(crontab -l 2>/dev/null | grep -E "auto-backup|backup-telegram")

            if [ $i -eq 1 ]; then
                echo "  No backup schedules found."
                read -p "Press Enter..."
                continue
            fi

            echo ""
            read -p "Select schedule to remove (0=cancel): " choice
            [ "$choice" = "0" ] && continue
            SELECTED="${JOBS[$choice]}"
            [ -z "$SELECTED" ] && { echo "Invalid selection"; read -p "Enter..."; continue; }

            echo ""
            echo "Will remove:"
            echo "  $SELECTED"
            read -p "Confirm? (y/n): " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                ESCAPED=$(printf '%s\n' "$SELECTED" | sed 's/[[\.*^$()+?{|]/\\&/g')
                crontab -l 2>/dev/null | grep -vF "$SELECTED" | crontab -
                echo "[OK] Schedule removed."
            else
                echo "Cancelled."
            fi
            read -p "Press Enter..."
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
