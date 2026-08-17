#!/bin/bash

MODULE_DIR="/opt/shieldpress/modules/email"
ETC_DIR="/etc/shieldpress"
source "/opt/shieldpress/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

while true; do
clear

# Show install status in header
if mail_installed; then
    sp_header "Email Server" "Mail management"
else
    sp_header "Email Server" "Not installed"
fi

# Webmail label
if [ -f "$ETC_DIR/.webmail_installed" ]; then
    WEBMAIL_LABEL="Webmail (Installed)"
    WEBMAIL_COLOR="cyan"
else
    WEBMAIL_LABEL="Install Webmail"
    WEBMAIL_COLOR="green"
fi

sp_menu_grid \
    "1|Install Email Server|green" \
    "2|Add Email Account|green" \
    "3|Delete Email Account|red" \
    "4|List Email Accounts|cyan" \
    "5|Change Password|yellow" \
    "6|SMTP Relay (Brevo/SES)|blue" \
    "7|Test Send & Receive|magenta" \
    "8|Email Server Status|cyan" \
    "9|DNS Records Guide|blue" \
    "10|Client Setup Guide|magenta" \
    "11|${WEBMAIL_LABEL}|${WEBMAIL_COLOR}" \
    "12|Install SSL (mail)|blue" \
    "13|Uninstall Email Server|red" \
    "0|Back|white"
sp_prompt opt

case $opt in
    1) bash $MODULE_DIR/install-email.sh ;;
    2) bash $MODULE_DIR/add-email.sh ;;
    3) bash $MODULE_DIR/delete-email.sh ;;
    4) bash $MODULE_DIR/list-email.sh ;;
    5) bash $MODULE_DIR/change-password.sh ;;
    6) bash $MODULE_DIR/setup-relay.sh ;;
    7) bash $MODULE_DIR/test-email.sh ;;
    8) bash $MODULE_DIR/email-status.sh ;;
    9) bash $MODULE_DIR/dns-guide.sh ;;
    10) bash $MODULE_DIR/client-guide.sh ;;
    11)
        if [ -f "$ETC_DIR/.webmail_installed" ]; then
            bash $MODULE_DIR/webmail-info.sh
        else
            bash $MODULE_DIR/install-webmail.sh
        fi
        ;;
    12) bash $MODULE_DIR/install-ssl-mail.sh ;;
    13) bash $MODULE_DIR/uninstall-email.sh ;;
    0) break ;;
    *) sp_invalid ;;
esac

done
