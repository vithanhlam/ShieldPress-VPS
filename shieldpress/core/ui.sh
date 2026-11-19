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

# =====================================================
# Shared building blocks for consistent screens.
# Keep the 78-column width of sp_hr.
# =====================================================

sp_rule(){
    echo -e "  ${SP_DIM}──────────────────────────────────────────────────────────────────────────${SP_RESET}"
}

# Section title inside a screen: "▸ TITLE" with a rule underneath.
sp_title(){
    echo ""
    echo -e "  ${SP_BOLD}${SP_CYAN}▸ ${1^^}${SP_RESET}"
    sp_rule
}

sp_ok(){   echo -e "  ${SP_GREEN}✔${SP_RESET} $*"; }
sp_fail(){ echo -e "  ${SP_RED}✖${SP_RESET} $*"; }
sp_warn(){ echo -e "  ${SP_YELLOW}⚠${SP_RESET} $*"; }
sp_info(){ echo -e "  ${SP_CYAN}ℹ${SP_RESET} $*"; }
sp_skip(){ echo -e "  ${SP_DIM}– $*${SP_RESET}"; }

sp_pause(){
    echo ""
    read -r -p "  Press Enter to continue..." _ || true
}

# Numbered picker that always offers [0] Back and re-asks on invalid input.
# Usage: sp_pick "Title" item1 item2 ...   -> SP_PICK=1..n, returns 1 on Back.
sp_pick(){
    local title="$1" n choice i=1 item
    shift
    n=$#
    SP_PICK=""
    if [ "$n" -eq 0 ]; then
        sp_warn "Nothing to select."
        return 1
    fi
    sp_title "$title"
    for item in "$@"; do
        printf "  ${SP_CYAN}[%2d]${SP_RESET} %s\n" "$i" "$item"
        i=$((i + 1))
    done
    printf "  ${SP_DIM}[ 0] Back${SP_RESET}\n"
    sp_rule
    while true; do
        read -r -p "Select [0-$n]: " choice || return 1
        case "$choice" in
            0|"") return 1 ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
            SP_PICK="$choice"
            return 0
        fi
        sp_fail "Enter a number from 0 to $n."
    done
}

# Pick a managed domain. Sets SP_PICK_DOMAIN and SP_PICK_PATH (no trailing slash).
sp_pick_domain(){
    local root="${DOMAINS_ROOT:-/home/domains}" d name
    local -a names=() paths=()
    for d in "$root"/*/; do
        [ -f "$d/config/domain.env" ] || continue
        name=$(sed -n 's/^DOMAIN=//p' "$d/config/domain.env" | head -1 | tr -d '[:space:]"'"'")
        [ -n "$name" ] || continue
        names+=("$name")
        paths+=("${d%/}")
    done
    SP_PICK_DOMAIN=""
    SP_PICK_PATH=""
    if [ "${#names[@]}" -eq 0 ]; then
        sp_warn "No domains found. Add one from Domain Manager first."
        return 1
    fi
    sp_pick "${1:-Select domain}" "${names[@]}" || return 1
    SP_PICK_DOMAIN="${names[$((SP_PICK - 1))]}"
    SP_PICK_PATH="${paths[$((SP_PICK - 1))]}"
}
