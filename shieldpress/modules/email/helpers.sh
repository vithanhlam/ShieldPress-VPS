#!/bin/bash
# ============================================================
#  Email Module - Shared Helper Functions
# ============================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

MODULE_DIR="$BASE_DIR/modules/email"
DOMAINS_ROOT="/home/domains"
MAIL_DIR="/var/mail/vhosts"
ETC_DIR="/etc/shieldpress"
EMAIL_CONFIG="$ETC_DIR/email.conf"

# Logging
LOG_FILE="$LOG_DIR/email.log"
mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BLUE="\e[34m"
MAGENTA="\e[35m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo -e "${GREEN}[OK]${RESET} $1";       log "[OK] $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1";        log "[FAIL] $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1";     log "[WARN] $1"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $1"; }

# ============================================================
#  Check if mail stack is installed
# ============================================================
mail_installed(){
    [ -f "$ETC_DIR/.mail_installed" ]
}

# ============================================================
#  Get server IP
# ============================================================
get_server_ip(){
    SERVER_IP=$(curl -s --connect-timeout 3 https://ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
}

# ============================================================
#  Get hostname for mail
# ============================================================
get_mail_hostname(){
    if [ -f "$EMAIL_CONFIG" ]; then
        MAIL_HOSTNAME=$(grep "^MAIL_HOSTNAME=" "$EMAIL_CONFIG" | cut -d'=' -f2 | tr -d '[:space:]')
    fi
    [ -z "$MAIL_HOSTNAME" ] && MAIL_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
}

# ============================================================
#  Validate email format
# ============================================================
validate_email(){
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# ============================================================
#  Validate domain format
# ============================================================
validate_domain(){
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

# ============================================================
#  List mail domains
# ============================================================
list_mail_domains(){
    local domains=()
    if [ -d "$MAIL_DIR" ]; then
        for d in "$MAIL_DIR"/*/; do
            [ -d "$d" ] || continue
            domains+=("$(basename "$d")")
        done
    fi
    echo "${domains[@]}"
}

# ============================================================
#  List email accounts for a domain
# ============================================================
list_domain_emails(){
    local domain="$1"
    local accounts=()
    if [ -d "$MAIL_DIR/$domain" ]; then
        for u in "$MAIL_DIR/$domain"/*/; do
            [ -d "$u" ] || continue
            accounts+=("$(basename "$u")@$domain")
        done
    fi
    echo "${accounts[@]}"
}

# ============================================================
#  Check if email account exists
# ============================================================
email_exists(){
    local user="$1"
    local domain="$2"
    [ -d "$MAIL_DIR/$domain/$user" ]
}

# ============================================================
#  Generate DKIM keys for domain
# ============================================================
generate_dkim(){
    local domain="$1"
    local dkim_dir="/etc/opendkim/keys/$domain"

    mkdir -p "$dkim_dir"

    if [ ! -f "$dkim_dir/mail.private" ]; then
        opendkim-genkey -b 2048 -d "$domain" -D "$dkim_dir" -s mail -v 2>/dev/null
        chown -R opendkim:opendkim "$dkim_dir"
        chmod 600 "$dkim_dir/mail.private"
        ok "DKIM key generated for $domain"
    else
        info "DKIM key already exists for $domain"
    fi
}

# ============================================================
#  Get DKIM value (clean single-line for DNS)
#  opendkim-genkey outputs: "v=DKIM1; k=rsa; " "p=MIIB..." "..."
#  We need clean:          v=DKIM1; k=rsa; p=MIIBIjAN...
# ============================================================
get_dkim_value(){
    local domain="$1"
    local dkim_file="/etc/opendkim/keys/$domain/mail.txt"

    if [ -f "$dkim_file" ]; then
        # Strip quotes, parentheses, tabs, newlines → single clean string
        sed -e '/^mail\._domainkey/d' -e 's/.*TXT.*( *//; s/ *).*//; s/"//g; s/\t//g; s/  */ /g' "$dkim_file" \
            | tr -d '\n' | sed 's/^ *//;s/ *$//' | tr -s ' '
    else
        echo ""
    fi
}

# ============================================================
#  Export DNS records to file (for Cloudflare import)
# ============================================================
export_dns_records(){
    local domain="$1"
    local export_dir="/home"
    local export_file="$export_dir/dns-records-${domain}.txt"
    local server_ip="$2"

    mkdir -p "$export_dir"

    local dkim_value
    dkim_value=$(get_dkim_value "$domain")

    cat > "$export_file" <<EXPORT_EOF
;; ============================================================
;; DNS Records for ${domain}
;; Generated: $(date '+%Y-%m-%d %H:%M:%S')
;; Import this file or copy each record manually
;; ============================================================

;; 1. MX Record - receive email
;; Type: MX | Name: @ | Content: mail.${domain} | Priority: 10
${domain}.	1	IN	MX	10 mail.${domain}.

;; 2. A Record - mail server IP
;; Type: A | Name: mail | Content: ${server_ip}
mail.${domain}.	1	IN	A	${server_ip}

;; 3. SPF Record - authorize sending
;; Type: TXT | Name: @ | Content: (copy below)
${domain}.	1	IN	TXT	"v=spf1 mx a ip4:${server_ip} ~all"

;; 4. DKIM Record - email signing
;; Type: TXT | Name: mail._domainkey | Content: (copy below)
mail._domainkey.${domain}.	1	IN	TXT	"${dkim_value}"

;; 5. DMARC Record - policy enforcement
;; Type: TXT | Name: _dmarc | Content: (copy below)
_dmarc.${domain}.	1	IN	TXT	"v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}"
EXPORT_EOF

    chmod 644 "$export_file"
    echo "$export_file"
}

# ============================================================
#  Select mail domain (interactive)
# ============================================================
select_mail_domain(){
    local _DOMAINS=()
    echo ""
    echo "Mail Domains:"
    echo "--------------------------------"

    local i=1
    for d in "$MAIL_DIR"/*/; do
        [ -d "$d" ] || continue
        local DN=$(basename "$d")
        local COUNT=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        printf "  %d) %-30s [%d accounts]\n" "$i" "$DN" "$COUNT"
        _DOMAINS[$i]="$DN"
        ((i++))
    done

    if [ $i -eq 1 ]; then
        echo "  No mail domains found."
        echo "--------------------------------"
        return 1
    fi

    echo "--------------------------------"
    read -p "Select domain: " choice
    SELECTED_DOMAIN="${_DOMAINS[$choice]}"

    if [ -z "$SELECTED_DOMAIN" ]; then
        fail "Invalid selection"
        return 1
    fi

    return 0
}

# ============================================================
#  Check relay configuration
# ============================================================
get_relay_info(){
    RELAY_TYPE="none"
    RELAY_STATUS="Not configured"

    if [ -f "$EMAIL_CONFIG" ]; then
        RELAY_TYPE=$(grep "^RELAY_TYPE=" "$EMAIL_CONFIG" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$RELAY_TYPE" ] && RELAY_TYPE="none"
    fi

    case "$RELAY_TYPE" in
        brevo)   RELAY_STATUS="Brevo (Sendinblue)" ;;
        ses)     RELAY_STATUS="Amazon SES" ;;
        *)       RELAY_STATUS="Direct (no relay)" ;;
    esac
}
