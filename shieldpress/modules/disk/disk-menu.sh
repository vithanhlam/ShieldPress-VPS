#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
BACKUP_DIR="$BACKUP_GLOBAL_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BLUE="\e[34m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

ok(){   echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

# =================================================
# DISK OVERVIEW
# =================================================

disk_overview(){
    echo ""
    echo "========================================="
    echo "  DISK USAGE OVERVIEW"
    echo "========================================="
    echo ""

    # Main disk
    echo -e "${BOLD}Filesystem Usage:${RESET}"
    echo "-------------------------------------------"
    df -hT / | awk 'NR==1 {printf "  %-14s %-6s %-6s %-6s %-6s %s\n", $1,$2,$3,$4,$5,$6}
                    NR==2 {printf "  %-14s %-6s %-6s %-6s %-6s %s\n", $1,$2,$3,$4,$5,$6}'
    echo ""

    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

    # Color bar
    local COLOR="$GREEN"
    [ "$DISK_PERCENT" -ge 70 ] && COLOR="$YELLOW"
    [ "$DISK_PERCENT" -ge 85 ] && COLOR="$RED"

    local BAR_W=40
    local FILLED=$((DISK_PERCENT * BAR_W / 100))
    local EMPTY=$((BAR_W - FILLED))

    printf "  ${COLOR}["
    for ((i=0;i<FILLED;i++)); do printf "#"; done
    for ((i=0;i<EMPTY;i++)); do printf " "; done
    printf "]${RESET} %s%%\n" "$DISK_PERCENT"
    echo ""
    echo "  Used      : $DISK_USED"
    echo "  Available : $DISK_AVAIL"
    echo "  Total     : $DISK_TOTAL"

    # All mount points
    echo ""
    echo -e "${BOLD}All Mount Points:${RESET}"
    echo "-------------------------------------------"
    df -hT -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk '
        NR==1 {printf "  %-20s %-6s %6s %6s %6s %5s  %s\n", "Filesystem","Type","Size","Used","Avail","Use%","Mount"}
        NR>1  {printf "  %-20s %-6s %6s %6s %6s %5s  %s\n", $1,$2,$3,$4,$5,$6,$7}'

    # Inode usage
    echo ""
    echo -e "${BOLD}Inode Usage (root):${RESET}"
    echo "-------------------------------------------"
    INODE_PERCENT=$(df -i / | awk 'NR==2 {print $5}' | tr -d '%')
    INODE_USED=$(df -i / | awk 'NR==2 {print $3}')
    INODE_TOTAL=$(df -i / | awk 'NR==2 {print $2}')
    echo "  Used  : $INODE_USED / $INODE_TOTAL ($INODE_PERCENT%)"

    if [ "$INODE_PERCENT" -ge 80 ]; then
        echo -e "  ${RED}Warning: Inode usage is high!${RESET}"
    fi

    # Key directories
    echo ""
    echo -e "${BOLD}Key Directory Sizes:${RESET}"
    echo "-------------------------------------------"
    printf "  %-30s %s\n" "Directory" "Size"
    printf "  %-30s %s\n" "------------------------------" "------"

    for dir in "$DOMAINS_ROOT" "$BASE_DIR" /var/log /tmp /var/cache/nginx; do
        if [ -d "$dir" ]; then
            SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            printf "  %-30s %s\n" "$dir" "$SIZE"
        fi
    done
}

# =================================================
# TOP 10 FILES - SINGLE DOMAIN
# =================================================

top_files_domain(){
    source "$BASE_DIR/modules/domain/helpers.sh"
    select_domain || return

    echo ""
    echo "========================================="
    echo "  TOP 10 LARGEST FILES - $SELECTED_DOMAIN"
    echo "========================================="
    echo ""

    SITE_PATH="$DOMAIN_PATH/public_html"
    if [ ! -d "$SITE_PATH" ]; then
        SITE_PATH="$DOMAIN_PATH"
    fi

    echo "  Scanning: $SITE_PATH"
    echo "  (this may take a moment...)"
    echo ""
    printf "  %-10s  %s\n" "Size" "File"
    printf "  %-10s  %s\n" "----------" "--------------------------------------------"

    find "$SITE_PATH" -type f -exec du -h {} + 2>/dev/null \
        | sort -rh \
        | head -20 \
        | while read SIZE FILE; do
            # Truncate long paths
            DISPLAY_FILE="${FILE#$SITE_PATH/}"
            printf "  %-10s  %s\n" "$SIZE" "$DISPLAY_FILE"
        done

    # Total size
    echo ""
    TOTAL=$(du -sh "$SITE_PATH" 2>/dev/null | awk '{print $1}')
    echo -e "  ${BOLD}Total domain size: $TOTAL${RESET}"
}

# =================================================
# TOP 10 FILES - ALL DOMAINS
# =================================================

top_files_all(){
    echo ""
    echo "========================================="
    echo "  TOP 10 LARGEST FILES - ALL DOMAINS"
    echo "========================================="
    echo ""

    if [ ! -d "$DOMAINS_ROOT" ]; then
        fail "Domains directory not found: $DOMAINS_ROOT"
        return 1
    fi

    echo "  Scanning: $DOMAINS_ROOT"
    echo "  (this may take a while...)"
    echo ""

    # Show per-domain sizes first
    echo -e "  ${BOLD}Domain Sizes:${RESET}"
    printf "  %-30s %s\n" "Domain" "Size"
    printf "  %-30s %s\n" "------------------------------" "------"

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && DN=$(basename "$d")
        SIZE=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        printf "  %-30s %s\n" "$DN" "$SIZE"
    done

    echo ""
    echo -e "  ${BOLD}Top 20 Largest Files:${RESET}"
    printf "  %-10s  %s\n" "Size" "File"
    printf "  %-10s  %s\n" "----------" "--------------------------------------------"

    find "$DOMAINS_ROOT" -type f -exec du -h {} + 2>/dev/null \
        | sort -rh \
        | head -20 \
        | while read SIZE FILE; do
            DISPLAY_FILE="${FILE#$DOMAINS_ROOT/}"
            printf "  %-10s  %s\n" "$SIZE" "$DISPLAY_FILE"
        done

    # Total
    echo ""
    TOTAL=$(du -sh "$DOMAINS_ROOT" 2>/dev/null | awk '{print $1}')
    echo -e "  ${BOLD}Total all domains: $TOTAL${RESET}"
}

# =================================================
# SHIELDPRESS BACKUP SIZE
# =================================================

backup_size(){
    echo ""
    echo "========================================="
    echo "  SHIELDPRESS BACKUP STORAGE"
    echo "========================================="
    echo ""

    if [ ! -d "$BACKUP_DIR" ]; then
        warn "Backup directory not found: $BACKUP_DIR"
        return 1
    fi

    # Overview
    TOTAL_BACKUP=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
    BACKUP_COUNT=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l)
    echo -e "  ${BOLD}Backup Location:${RESET} $BACKUP_DIR"
    echo -e "  ${BOLD}Total Size:${RESET}     $TOTAL_BACKUP"
    echo -e "  ${BOLD}Total Files:${RESET}    $BACKUP_COUNT"
    echo ""

    # Breakdown by subfolder
    echo -e "  ${BOLD}Breakdown by Category:${RESET}"
    printf "  %-35s %-10s %s\n" "Folder" "Size" "Files"
    printf "  %-35s %-10s %s\n" "-----------------------------------" "----------" "-----"

    for sub in "$BACKUP_DIR"/*/; do
        [ -d "$sub" ] || continue
        NAME=$(basename "$sub")
        SIZE=$(du -sh "$sub" 2>/dev/null | awk '{print $1}')
        COUNT=$(find "$sub" -type f 2>/dev/null | wc -l)
        printf "  %-35s %-10s %s\n" "$NAME" "$SIZE" "$COUNT"
    done

    # Also check other ShieldPress data
    echo ""
    echo -e "  ${BOLD}Other ShieldPress Storage:${RESET}"
    printf "  %-35s %s\n" "Directory" "Size"
    printf "  %-35s %s\n" "-----------------------------------" "------"

    for dir in "$LOG_DIR" "$DATA_DIR" "$BASE_DIR/bin"; do
        if [ -d "$dir" ]; then
            SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
            printf "  %-35s %s\n" "${dir#$BASE_DIR/}" "$SIZE"
        fi
    done

    TOTAL_SP=$(du -sh "$BASE_DIR" 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "  ${BOLD}Total ShieldPress (/opt/shieldpress): $TOTAL_SP${RESET}"

    # Oldest and newest backup
    echo ""
    OLDEST=$(find "$BACKUP_DIR" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1)
    NEWEST=$(find "$BACKUP_DIR" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1)
    if [ -n "$OLDEST" ]; then
        echo "  Oldest backup: $(echo "$OLDEST" | cut -d' ' -f1 | cut -dT -f1)"
        echo "  Newest backup: $(echo "$NEWEST" | cut -d' ' -f1 | cut -dT -f1)"
    fi
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "Disk Manager" "Storage & file analysis"
    sp_menu_grid \
        "1|Disk Usage Overview|cyan" \
        "2|Top Files (Single Domain)|blue" \
        "3|Top Files (All Domains)|blue" \
        "4|Backup Storage Size|yellow" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) disk_overview ;;
        2) top_files_domain ;;
        3) top_files_all ;;
        4) backup_size ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
