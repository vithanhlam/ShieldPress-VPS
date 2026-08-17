#!/bin/bash
# ============================================================
#  Test Email - Send & Receive Test
#  1. Test outbound email (via relay or direct)
#  2. Test inbound email (Postfix + Dovecot pipeline)
#  3. Test authentication (SMTP login)
# ============================================================

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/email"
MAIL_DIR="/var/mail/vhosts"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

source "$BASE_DIR/core/ui.sh"
source "$MODULE_DIR/helpers.sh"

clear
sp_header "Test Email" "Send & receive test"

if ! mail_installed; then
    fail "Email server not installed"
    read -p "Press Enter..."
    exit 1
fi

# Load config
MAIL_DOMAIN=$(grep "^MAIL_DOMAIN=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
MAIL_HOSTNAME=$(grep "^MAIL_HOSTNAME=" "$EMAIL_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')

get_relay_info

echo ""
echo -e "  ${BOLD}Select test:${RESET}"
echo ""
echo -e "  ${GREEN}[1]${RESET} Test Send Email (outbound)"
echo -e "  ${BLUE}[2]${RESET} Test Receive Email (inbound)"
echo -e "  ${CYAN}[3]${RESET} Test SMTP Authentication"
echo -e "  ${MAGENTA}[4]${RESET} Full Diagnostics (all checks)"
echo -e "  ${YELLOW}[5]${RESET} Test WordPress SMTP (debug plugin config)"
echo -e "  ${WHITE}[0]${RESET} Back"
echo ""

read -p "  Select: " TEST_CHOICE

case $TEST_CHOICE in
# ============================================================
#  TEST 1: Send email
# ============================================================
1)
    echo ""
    sp_hr
    echo -e "  ${BOLD}Test Send Email${RESET}"
    sp_hr
    echo ""

    # Select sender from existing accounts
    echo "  From (sender account on this server):"
    SENDERS=()
    i=1
    while IFS=: read -r email _; do
        [ -z "$email" ] && continue
        printf "    %d) %s\n" "$i" "$email"
        SENDERS[$i]="$email"
        ((i++))
    done < /etc/dovecot/users

    if [ $i -eq 1 ]; then
        fail "No email accounts found"
        read -p "Press Enter..."
        exit 1
    fi

    echo ""
    read -p "  Select sender: " SENDER_CHOICE
    FROM="${SENDERS[$SENDER_CHOICE]}"
    [ -z "$FROM" ] && { fail "Invalid selection"; read -p "Press Enter..."; exit 1; }

    echo ""
    read -p "  To (external email, e.g. your@gmail.com): " TO

    if [ -z "$TO" ]; then
        fail "Recipient email required"
        read -p "Press Enter..."
        exit 1
    fi

    echo ""
    info "Sending test email..."
    info "From: $FROM → To: $TO"
    info "Relay: $RELAY_STATUS"
    echo ""

    # Send via sendmail (uses Postfix)
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    /usr/sbin/sendmail -f "$FROM" "$TO" <<EMAIL_EOF
From: $FROM
To: $TO
Subject: ShieldPress Email Test - $TIMESTAMP
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

This is a test email from ShieldPress VPS.

Server   : $MAIL_HOSTNAME
From     : $FROM
Time     : $TIMESTAMP
Relay    : $RELAY_STATUS

If you received this email, your outbound mail is working correctly!

--
ShieldPress VPS Mail Server
EMAIL_EOF

    if [ $? -eq 0 ]; then
        ok "Test email queued for delivery"
        echo ""

        # Check mail queue
        sleep 2
        QUEUE=$(postqueue -p 2>/dev/null | tail -1)
        if echo "$QUEUE" | grep -q "empty"; then
            ok "Mail queue is empty - email sent successfully"
        else
            info "Mail queue status:"
            postqueue -p 2>/dev/null | head -10
        fi

        echo ""
        echo -e "  ${DIM}Check the inbox of $TO for the test email${RESET}"
        echo -e "  ${DIM}If not received, check spam/junk folder${RESET}"
        echo ""

        # Show recent mail log
        echo -e "  ${BOLD}Recent mail log:${RESET}"
        echo -e "  ──────────────────────────────────────"
        tail -5 /var/log/maillog 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}$line${RESET}"
        done
    else
        fail "Failed to queue test email"
        echo ""
        echo -e "  ${BOLD}Check mail log:${RESET}"
        tail -10 /var/log/maillog 2>/dev/null
    fi
    ;;

# ============================================================
#  TEST 2: Receive email (local delivery test)
# ============================================================
2)
    echo ""
    sp_hr
    echo -e "  ${BOLD}Test Receive Email (Local Delivery)${RESET}"
    sp_hr
    echo ""

    # Select recipient from existing accounts
    echo "  Deliver test email to:"
    RECIPIENTS=()
    i=1
    while IFS=: read -r email _; do
        [ -z "$email" ] && continue
        printf "    %d) %s\n" "$i" "$email"
        RECIPIENTS[$i]="$email"
        ((i++))
    done < /etc/dovecot/users

    if [ $i -eq 1 ]; then
        fail "No email accounts found"
        read -p "Press Enter..."
        exit 1
    fi

    echo ""
    read -p "  Select recipient: " RCPT_CHOICE
    RCPT="${RECIPIENTS[$RCPT_CHOICE]}"
    [ -z "$RCPT" ] && { fail "Invalid selection"; read -p "Press Enter..."; exit 1; }

    RCPT_USER="${RCPT%%@*}"
    RCPT_DOMAIN="${RCPT##*@}"

    echo ""
    info "Sending local test email to $RCPT..."

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    /usr/sbin/sendmail "$RCPT" <<LOCAL_EOF
From: test@localhost
To: $RCPT
Subject: [TEST] Local Delivery Test - $TIMESTAMP
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

This is a local delivery test from ShieldPress.
Time: $TIMESTAMP

If you see this in your IMAP mailbox, local delivery is working!
LOCAL_EOF

    if [ $? -eq 0 ]; then
        ok "Test email sent to $RCPT"
        sleep 2

        # Check if email landed in Maildir
        NEW_DIR="$MAIL_DIR/$RCPT_DOMAIN/$RCPT_USER/Maildir/new"
        if [ -d "$NEW_DIR" ]; then
            NEW_COUNT=$(ls "$NEW_DIR" 2>/dev/null | wc -l)
            if [ "$NEW_COUNT" -gt 0 ]; then
                ok "Email delivered! ($NEW_COUNT message(s) in inbox)"
                echo ""
                echo -e "  ${DIM}Maildir: $NEW_DIR${RESET}"
                echo -e "  ${DIM}Latest email:${RESET}"
                LATEST=$(ls -t "$NEW_DIR" 2>/dev/null | head -1)
                if [ -n "$LATEST" ]; then
                    head -10 "$NEW_DIR/$LATEST" 2>/dev/null | while read -r line; do
                        echo -e "  ${DIM}  $line${RESET}"
                    done
                fi
            else
                warn "Email queued but not yet in Maildir"
                echo -e "  ${DIM}Check: systemctl status dovecot${RESET}"
            fi
        else
            warn "Maildir not found at $NEW_DIR"
            echo -e "  ${DIM}Dovecot may not have created the directory yet${RESET}"
        fi
    else
        fail "Failed to send local test email"
    fi

    echo ""
    echo -e "  ${BOLD}Recent mail log:${RESET}"
    echo -e "  ──────────────────────────────────────"
    tail -5 /var/log/maillog 2>/dev/null | while read -r line; do
        echo -e "  ${DIM}$line${RESET}"
    done
    ;;

# ============================================================
#  TEST 3: SMTP Authentication
# ============================================================
3)
    echo ""
    sp_hr
    echo -e "  ${BOLD}Test SMTP Authentication${RESET}"
    sp_hr
    echo ""

    # Check if openssl is available
    if ! command -v openssl &>/dev/null; then
        fail "openssl not found"
        read -p "Press Enter..."
        exit 1
    fi

    # Select account to test
    echo "  Test login for:"
    ACCOUNTS=()
    i=1
    while IFS=: read -r email _; do
        [ -z "$email" ] && continue
        printf "    %d) %s\n" "$i" "$email"
        ACCOUNTS[$i]="$email"
        ((i++))
    done < /etc/dovecot/users

    echo ""
    read -p "  Select account: " ACC_CHOICE
    TEST_EMAIL="${ACCOUNTS[$ACC_CHOICE]}"
    [ -z "$TEST_EMAIL" ] && { fail "Invalid selection"; read -p "Press Enter..."; exit 1; }

    read -sp "  Password: " TEST_PASS
    echo ""
    echo ""

    info "Testing IMAP login on port 993..."

    # Test IMAP login via openssl
    IMAP_RESULT=$(echo -e "a1 LOGIN ${TEST_EMAIL} ${TEST_PASS}\na2 LOGOUT" | \
        openssl s_client -connect localhost:993 -quiet 2>/dev/null | \
        grep -E "^a1 " | head -1)

    if echo "$IMAP_RESULT" | grep -qi "OK"; then
        ok "IMAP login successful"
    else
        fail "IMAP login failed"
        echo -e "  ${DIM}Response: $IMAP_RESULT${RESET}"
        echo -e "  ${DIM}Check: doveadm auth test ${TEST_EMAIL}${RESET}"
    fi

    echo ""
    info "Testing SMTP AUTH on port 587..."

    # Test SMTP auth via openssl
    AUTH_STRING=$(echo -ne "\0${TEST_EMAIL}\0${TEST_PASS}" | base64)
    SMTP_RESULT=$(echo -e "EHLO localhost\nAUTH PLAIN ${AUTH_STRING}\nQUIT" | \
        openssl s_client -connect localhost:587 -starttls smtp -quiet 2>/dev/null | \
        grep "^235" | head -1)

    if [ -n "$SMTP_RESULT" ]; then
        ok "SMTP AUTH successful"
    else
        fail "SMTP AUTH failed"
        echo -e "  ${DIM}Check: postconf smtpd_sasl_auth_enable${RESET}"
    fi
    ;;

# ============================================================
#  TEST 4: Full Diagnostics
# ============================================================
4)
    echo ""
    sp_hr
    echo -e "  ${BOLD}Full Email Diagnostics${RESET}"
    sp_hr
    echo ""

    PASS_COUNT=0
    FAIL_COUNT=0

    run_check(){
        local name="$1"
        local cmd="$2"
        if eval "$cmd" >/dev/null 2>&1; then
            printf "  %-40s ${GREEN}PASS${RESET}\n" "$name"
            ((PASS_COUNT++))
        else
            printf "  %-40s ${RED}FAIL${RESET}\n" "$name"
            ((FAIL_COUNT++))
        fi
    }

    # Services
    echo -e "  ${BOLD}Services:${RESET}"
    run_check "Postfix running"    "systemctl is-active --quiet postfix"
    run_check "Dovecot running"    "systemctl is-active --quiet dovecot"
    run_check "Rspamd running"     "systemctl is-active --quiet rspamd"
    run_check "OpenDKIM running"   "systemctl is-active --quiet opendkim"

    # Ports
    echo ""
    echo -e "  ${BOLD}Ports:${RESET}"
    run_check "SMTP (25) listening"        "ss -tlnp | grep -q ':25 '"
    run_check "Submission (587) listening"  "ss -tlnp | grep -q ':587 '"
    run_check "IMAPS (993) listening"       "ss -tlnp | grep -q ':993 '"

    # Config files
    echo ""
    echo -e "  ${BOLD}Configuration:${RESET}"
    run_check "Postfix main.cf exists"       "[ -f /etc/postfix/main.cf ]"
    run_check "Dovecot config exists"        "[ -f /etc/dovecot/dovecot.conf ]"
    run_check "Dovecot users file exists"    "[ -f /etc/dovecot/users ]"
    run_check "Virtual domains configured"   "[ -s /etc/postfix/virtual_domains ]"
    run_check "Virtual mailbox configured"   "[ -s /etc/postfix/virtual_mailbox ]"
    run_check "DKIM keys exist"              "ls /etc/opendkim/keys/*/mail.private >/dev/null 2>&1"

    # SSL
    echo ""
    echo -e "  ${BOLD}SSL:${RESET}"
    if [ -n "$MAIL_HOSTNAME" ]; then
        CERT_LE="/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem"
        CERT_SELF="/etc/pki/tls/certs/postfix.pem"
        if [ -f "$CERT_LE" ]; then
            EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_LE" 2>/dev/null | cut -d= -f2)
            printf "  %-40s ${GREEN}Let's Encrypt (exp: %s)${RESET}\n" "TLS Certificate" "$EXPIRY"
            ((PASS_COUNT++))
        elif [ -f "$CERT_SELF" ]; then
            printf "  %-40s ${YELLOW}Self-signed${RESET}\n" "TLS Certificate"
            ((PASS_COUNT++))
        else
            printf "  %-40s ${RED}MISSING${RESET}\n" "TLS Certificate"
            ((FAIL_COUNT++))
        fi
    fi

    # Relay
    echo ""
    echo -e "  ${BOLD}SMTP Relay:${RESET}"
    if [ "$RELAY_TYPE" = "brevo" ] || [ "$RELAY_TYPE" = "ses" ]; then
        run_check "Relay configured ($RELAY_STATUS)"  "[ -f /etc/postfix/sasl_passwd ]"
    else
        printf "  %-40s ${YELLOW}Direct (no relay)${RESET}\n" "Outbound sending"
    fi

    # DNS (if dig available)
    if command -v dig &>/dev/null && [ -n "$MAIL_DOMAIN" ]; then
        echo ""
        echo -e "  ${BOLD}DNS Records:${RESET}"
        get_server_ip

        MX=$(dig +short MX "$MAIL_DOMAIN" 2>/dev/null | head -1)
        run_check "MX record configured"  "[ -n '$MX' ]"

        A=$(dig +short A "mail.${MAIL_DOMAIN}" 2>/dev/null | head -1)
        if [ -n "$A" ] && [ "$A" = "$SERVER_IP" ]; then
            run_check "A record (mail) correct"  "true"
        elif [ -n "$A" ]; then
            printf "  %-40s ${YELLOW}MISMATCH ($A != $SERVER_IP)${RESET}\n" "A record (mail)"
            ((FAIL_COUNT++))
        else
            run_check "A record (mail) exists"  "false"
        fi

        SPF=$(dig +short TXT "$MAIL_DOMAIN" 2>/dev/null | grep "v=spf1")
        run_check "SPF record configured"  "[ -n '$SPF' ]"

        DKIM=$(dig +short TXT "mail._domainkey.${MAIL_DOMAIN}" 2>/dev/null | head -1)
        run_check "DKIM record configured"  "[ -n '$DKIM' ]"

        DMARC=$(dig +short TXT "_dmarc.${MAIL_DOMAIN}" 2>/dev/null | head -1)
        run_check "DMARC record configured"  "[ -n '$DMARC' ]"
    fi

    # Firewall
    if command -v firewall-cmd &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Firewall:${RESET}"
        run_check "SMTP port open"        "firewall-cmd --query-service=smtp 2>/dev/null"
        run_check "Submission port open"  "firewall-cmd --query-port=587/tcp 2>/dev/null"
        run_check "IMAPS port open"       "firewall-cmd --query-service=imaps 2>/dev/null"
    fi

    # Fail2Ban
    if command -v fail2ban-client &>/dev/null; then
        echo ""
        echo -e "  ${BOLD}Fail2Ban:${RESET}"
        run_check "Postfix jail active"      "fail2ban-client status postfix >/dev/null 2>&1"
        run_check "Dovecot jail active"      "fail2ban-client status dovecot >/dev/null 2>&1"
        run_check "Postfix-SASL jail active" "fail2ban-client status postfix-sasl >/dev/null 2>&1"
    fi

    # Summary
    echo ""
    sp_hr
    TOTAL=$((PASS_COUNT + FAIL_COUNT))
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}All $TOTAL checks passed!${RESET}"
    else
        echo -e "  ${YELLOW}${BOLD}$PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed${RESET}"
    fi
    sp_hr
    ;;

# ============================================================
#  TEST 5: WordPress SMTP Debug
# ============================================================
5)
    echo ""
    sp_hr
    echo -e "  ${BOLD}Test WordPress SMTP${RESET}"
    sp_hr
    echo ""

    if ! command -v openssl &>/dev/null; then
        fail "openssl not found"
        read -p "Press Enter..."
        exit 1
    fi

    # Select account
    echo "  Select email account to test:"
    ACCOUNTS=()
    i=1
    while IFS=: read -r email _; do
        [ -z "$email" ] && continue
        printf "    %d) %s\n" "$i" "$email"
        ACCOUNTS[$i]="$email"
        ((i++))
    done < /etc/dovecot/users

    echo ""
    read -p "  Select account: " ACC_CHOICE
    TEST_EMAIL="${ACCOUNTS[$ACC_CHOICE]}"
    [ -z "$TEST_EMAIL" ] && { fail "Invalid selection"; read -p "Press Enter..."; exit 1; }

    read -sp "  Password: " TEST_PASS
    echo ""
    echo ""

    echo -e "  ${BOLD}Correct settings for WordPress SMTP plugin:${RESET}"
    echo -e "  ──────────────────────────────────────────────────"
    echo -e "  SMTP Host     : ${GREEN}${MAIL_HOSTNAME}${RESET}"
    echo -e "  SMTP Port     : ${GREEN}587${RESET}"
    echo -e "  Encryption    : ${GREEN}TLS${RESET} (STARTTLS)  — NOT SSL"
    echo -e "  Authentication: ${GREEN}Yes/On${RESET}"
    echo -e "  Username      : ${GREEN}${TEST_EMAIL}${RESET}  — full email address"
    echo -e "  Password      : ${GREEN}(as entered)${RESET}"
    echo ""

    info "Test 1/3 — Checking port 587..."
    if ss -tlnp 2>/dev/null | grep -q ':587 '; then
        ok "Port 587 is listening"
    else
        fail "Port 587 is NOT listening — Postfix submission not enabled"
        echo -e "  ${DIM}Fix: check /etc/postfix/master.cf for 'submission' entry${RESET}"
    fi

    echo ""
    info "Test 2/3 — Checking SMTP STARTTLS..."
    EHLO_RESULT=$(echo -e "EHLO test\nQUIT" | \
        openssl s_client -connect localhost:587 -starttls smtp -quiet 2>/dev/null | \
        grep -E "^250|^220" | head -5)

    if [ -n "$EHLO_RESULT" ]; then
        ok "STARTTLS working"
        echo "$EHLO_RESULT" | while read -r line; do
            echo -e "  ${DIM}$line${RESET}"
        done
    else
        fail "STARTTLS failed"
        echo -e "  ${DIM}Check: postconf smtpd_tls_security_level${RESET}"
    fi

    echo ""
    info "Test 3/3 — SMTP AUTH (same as WordPress login)..."
    AUTH_STRING=$(echo -ne "\0${TEST_EMAIL}\0${TEST_PASS}" | base64)
    SMTP_RESULT=$(echo -e "EHLO localhost\nAUTH PLAIN ${AUTH_STRING}\nQUIT" | \
        openssl s_client -connect localhost:587 -starttls smtp -quiet 2>/dev/null | \
        grep "^235" | head -1)

    if [ -n "$SMTP_RESULT" ]; then
        ok "SMTP AUTH successful — server config is correct"
        echo ""
        echo -e "  ${GREEN}${BOLD}Server OK. If WordPress still fails, check:${RESET}"
        echo -e "  1. Encryption must be ${BOLD}TLS${RESET} (not SSL)"
        echo -e "  2. Username must be ${BOLD}${TEST_EMAIL}${RESET} (full email, not just the local part)"
        echo -e "  3. If SSL certificate error: disable 'Verify SSL' in the plugin"
        echo -e "  4. ${BOLD}Cloudflare:${RESET} the ${BOLD}mail${RESET} A record must be ${BOLD}grey cloud (DNS only)${RESET}"
        echo -e "     Orange cloud (proxy) blocks port 587 — SMTP will fail even if server is fine"
    else
        fail "SMTP AUTH failed"
        echo ""
        echo -e "  ${BOLD}Possible causes:${RESET}"
        echo -e "  - Wrong password"
        echo -e "  - Account not found in /etc/dovecot/users"
        echo -e "  - Dovecot SASL not connected to Postfix"
        echo ""
        echo -e "  ${DIM}Debug: doveadm auth test ${TEST_EMAIL}${RESET}"
        echo -e "  ${DIM}Check: postconf smtpd_sasl_auth_enable${RESET}"
    fi
    ;;

0|*)
    exit 0
    ;;
esac

echo ""
read -p "Press Enter..."
