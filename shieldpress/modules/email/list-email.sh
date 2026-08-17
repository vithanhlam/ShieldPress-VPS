#!/bin/bash
# ============================================================
#  List Email Accounts
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Email Accounts" "All mailboxes"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

echo ""

TOTAL=0

for d in "$MAIL_DIR"/*/; do
    [ -d "$d" ] || continue
    DOMAIN=$(basename "$d")

    echo -e "  ${BOLD}${CYAN}$DOMAIN${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────${RESET}"

    HAS_ACCOUNTS=false
    for u in "$d"/*/; do
        [ -d "$u" ] || continue
        UNAME=$(basename "$u")
        SIZE=$(du -sh "$u" 2>/dev/null | awk '{print $1}')

        # Count emails
        MAIL_COUNT=0
        [ -d "$u/Maildir/new" ] && MAIL_COUNT=$((MAIL_COUNT + $(ls "$u/Maildir/new/" 2>/dev/null | wc -l)))
        [ -d "$u/Maildir/cur" ] && MAIL_COUNT=$((MAIL_COUNT + $(ls "$u/Maildir/cur/" 2>/dev/null | wc -l)))

        printf "  %-35s %8s  %d emails\n" "${UNAME}@${DOMAIN}" "$SIZE" "$MAIL_COUNT"
        HAS_ACCOUNTS=true
        ((TOTAL++))
    done

    if ! $HAS_ACCOUNTS; then
        echo -e "  ${DIM}(no accounts)${RESET}"
    fi

    echo ""
done

if [ $TOTAL -eq 0 ]; then
    echo -e "  ${DIM}No email accounts found${RESET}"
    echo -e "  ${DIM}Use 'Add Email Account' to create one${RESET}"
fi

echo ""
echo -e "  ${DIM}Total: $TOTAL account(s)${RESET}"
echo ""

read -p "Press Enter..."
