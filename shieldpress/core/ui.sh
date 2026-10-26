#!/bin/bash

SP_GREEN="${SP_GREEN:-\e[32m}"
SP_RED="${SP_RED:-\e[31m}"
SP_YELLOW="${SP_YELLOW:-\e[33m}"
SP_CYAN="${SP_CYAN:-\e[36m}"
SP_BLUE="${SP_BLUE:-\e[34m}"
SP_MAGENTA="${SP_MAGENTA:-\e[35m}"
SP_WHITE="${SP_WHITE:-\e[97m}"
SP_BOLD="${SP_BOLD:-\e[1m}"
SP_DIM="${SP_DIM:-\e[2m}"
SP_RESET="${SP_RESET:-\e[0m}"

sp_hr(){
    echo -e "${SP_CYAN}+----------------------------------------------------------------------------+${SP_RESET}"
}

sp_header(){
    local title="$1"
    local subtitle="${2:-ShieldPress VPS}"
    sp_hr
    if [ "${#title}" -le 42 ] && [ "${#subtitle}" -le 31 ]; then
        printf "${SP_CYAN}|${SP_RESET} ${SP_BOLD}${SP_WHITE}%-42s${SP_RESET} ${SP_DIM}%-31s${SP_RESET} ${SP_CYAN}|${SP_RESET}\n" "$title" "$subtitle"
    else
        local line
        while IFS= read -r line; do
            printf "${SP_CYAN}|${SP_RESET} %-74s ${SP_CYAN}|${SP_RESET}\n" "$line"
        done < <(printf '%s\n%s\n' "$title" "$subtitle" | fold -s -w 74)
    fi
    sp_hr
}

sp_section(){
    printf "${SP_CYAN}|${SP_RESET} ${SP_BOLD}%-74s${SP_RESET} ${SP_CYAN}|${SP_RESET}\n" "$1"
}

sp_color(){
    case "$1" in
        red|danger) echo "$SP_RED" ;;
        yellow|warn) echo "$SP_YELLOW" ;;
        green|ok) echo "$SP_GREEN" ;;
        blue) echo "$SP_BLUE" ;;
        magenta) echo "$SP_MAGENTA" ;;
        cyan) echo "$SP_CYAN" ;;
        white) echo "$SP_WHITE" ;;
        *) echo "$SP_CYAN" ;;
    esac
}

sp_button(){
    local num="$1"
    local label="$2"
    local color_name="${3:-cyan}"
    local color
    color=$(sp_color "$color_name")
    printf "${color}[%2s]${SP_RESET} %-29s" "$num" "$label"
}

sp_menu_grid(){
    local item num label color rest i=0 columns=2 width="${COLUMNS:-78}"
    [[ "$width" =~ ^[0-9]+$ ]] || width=78
    [ "$width" -ge 78 ] || columns=1
    for item in "$@"; do
        rest="${item#*|}"
        label="${rest%%|*}"
        [ "${#label}" -le 29 ] || columns=1
    done
    for item in "$@"; do
        num="${item%%|*}"
        rest="${item#*|}"
        label="${rest%%|*}"
        color="${rest##*|}"
        [ "$color" = "$label" ] && color="cyan"
        [ $((i % columns)) -eq 0 ] && printf "  "
        sp_button "$num" "$label" "$color"
        if [ $((i % columns)) -eq $((columns - 1)) ]; then
            echo ""
        fi
        i=$((i + 1))
    done
    [ $((i % columns)) -ne 0 ] && echo ""
    sp_hr
}

sp_prompt(){
    read -r -p "Select: " "$1"
}

sp_invalid(){
    echo -e "${SP_RED}[FAIL]${SP_RESET} Invalid option"
    sleep 0.2
}
