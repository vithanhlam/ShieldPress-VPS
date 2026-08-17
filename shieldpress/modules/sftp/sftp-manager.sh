#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/sftp.log"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
RESET="\e[0m"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo -e "${GREEN}[OK]${RESET} $1";       log "[OK] $1"; }
fail(){ echo -e "${RED}[FAILED]${RESET} $1";     log "[FAILED] $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1";    log "[WARN] $1"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $1"; }

generate_pass(){
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

# ======================================
# SAFE SSH RESTART
# ======================================

safe_restart_ssh(){
    if sshd -t 2>/dev/null; then
        systemctl restart sshd
        ok "SSH restarted safely"
    else
        fail "SSH config invalid! Restart aborted."
        sshd -t
        return 1
    fi
}

# ======================================
# ENSURE SFTP CONFIG IN SSHD
# ======================================

ensure_sftp_config(){
    groupadd -f sftpusers

    if ! grep -q "Match Group sftpusers" /etc/ssh/sshd_config; then
        # Backup trước khi sửa
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"

        cat >> /etc/ssh/sshd_config <<'EOF'

Match Group sftpusers
    ChrootDirectory /home/domains/%u
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
EOF
        safe_restart_ssh && ok "SFTP isolation configured in sshd"
    fi
}

# ======================================
# SELECT DOMAIN HELPER
# ======================================

# Dùng array thường thay vì declare -A để tránh lỗi scope
DOMAIN_FOLDERS=()

list_domains_all(){
    DOMAIN_FOLDERS=()
    echo ""
    echo -e "${CYAN}Available Domains${RESET}"
    echo "--------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        # Đọc thẳng từ file tránh variable leak
        local DNAME
        DNAME=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DNAME" ] && continue

        printf "%-3s %s\n" "$i)" "$DNAME"
        DOMAIN_FOLDERS[$i]=$(basename "$d")
        ((i++))
    done
    echo "--------------------------------"
}

list_domains_sftp_enabled(){
    DOMAIN_FOLDERS=()
    echo ""
    echo -e "${CYAN}SFTP Accounts${RESET}"
    echo "--------------------------------------------"
    printf "%-4s %-25s %-10s\n" "No" "Domain" "Status"
    echo "--------------------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        local DNAME SFTP_ST
        DNAME=$(grep  "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        SFTP_ST=$(grep "^SFTP="   "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        [ "$SFTP_ST" = "enabled" ] || [ "$SFTP_ST" = "disabled" ] || continue

        printf "%-4s %-25s %-10s\n" "$i" "$DNAME" "$SFTP_ST"
        DOMAIN_FOLDERS[$i]=$(basename "$d")
        ((i++))
    done
    echo "--------------------------------------------"
}

# ======================================
# CREATE SFTP
# ======================================

create_sftp(){

    list_domains_all
    echo ""
    read -p "Select domain number: " CHOICE

    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; return; }

    local DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    local ENV_FILE="$DOMAIN_PATH/config/domain.env"

    local DOMAIN SFTP_ST
    DOMAIN=$(grep  "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_ST=$(grep "^SFTP="   "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    if [ "$SFTP_ST" = "enabled" ]; then
        warn "SFTP already enabled for $DOMAIN"; return
    fi

    if ! id "$FOLDER" &>/dev/null; then
        fail "System user '$FOLDER' not found"; return
    fi

    local PASS
    PASS=$(generate_pass)

    usermod -aG sftpusers "$FOLDER"
    echo "$FOLDER:$PASS" | chpasswd

    # Chroot requirement
    chown root:root "$DOMAIN_PATH"
    chmod 755 "$DOMAIN_PATH"

    mkdir -p "$DOMAIN_PATH/public_html"
    chown -R "$FOLDER:$FOLDER" "$DOMAIN_PATH/public_html"

    # ================================
    # AUTO GET SSH PORT
    # ================================
    local SFTP_PORT
    SFTP_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n1)

    # fallback nếu không có
    SFTP_PORT=${SFTP_PORT:-22}

    # ================================
    # SAVE ENV
    # ================================
    sed -i '/^SFTP=/d; /^SFTP_USER=/d; /^SFTP_PASS=/d; /^SFTP_PORT=/d' "$ENV_FILE"

    cat >> "$ENV_FILE" <<EOF
SFTP=enabled
SFTP_USER=$FOLDER
SFTP_PASS=$PASS
SFTP_PORT=$SFTP_PORT
EOF
    # Chỉ root đọc được file chứa SFTP password
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    log "SFTP created for $DOMAIN"
    ok "SFTP created for $DOMAIN"

    # ================================
    # GET WAN IP (ưu tiên chuẩn hơn)
    # ================================
    local SERVER_IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s api.ipify.org)

    # ================================
    # OUTPUT
    # ================================
    echo ""
    echo -e "${WHITE}================================${RESET}"
    echo -e "${CYAN}  SFTP ACCOUNT INFO${RESET}"
    echo -e "${WHITE}================================${RESET}"
    echo "Domain   : $DOMAIN"
    echo "Host     : $SERVER_IP"
    echo "Port     : $SFTP_PORT"
    echo "Username : $FOLDER"
    echo "Password : $PASS"
    echo ""
    echo -e "${GREEN}Quick connect:${RESET}"
    echo "${FOLDER}@${SERVER_IP}:${SFTP_PORT}"
    echo -e "${WHITE}================================${RESET}"
    echo ""

    warn "Save the password now — it won't be shown again!"
}
# ======================================
# VIEW ACCOUNT
# ======================================

view_account(){

    list_domains_sftp_enabled
    echo ""
    read -p "Select domain number: " CHOICE

    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; return; }

    local ENV_FILE="$DOMAINS_ROOT/$FOLDER/config/domain.env"

    local DOMAIN SFTP_ST SFTP_USER SFTP_PASS SFTP_PORT

    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_ST=$(grep "^SFTP=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_USER=$(grep "^SFTP_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_PASS=$(grep "^SFTP_PASS=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_PORT=$(grep "^SFTP_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    # ================================
    # FALLBACK PORT (nếu env lỗi)
    # ================================
    if [ -z "$SFTP_PORT" ]; then
        SFTP_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' | tail -n1)
        SFTP_PORT=${SFTP_PORT:-22}
    fi

    # ================================
    # GET WAN IP (chuẩn hơn LAN)
    # ================================
    local SERVER_IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s api.ipify.org)

    # fallback nếu fail
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${WHITE}================================${RESET}"
    echo -e "${CYAN}  SFTP ACCOUNT INFO${RESET}"
    echo -e "${WHITE}================================${RESET}"
    echo "Domain   : $DOMAIN"
    echo "Status   : $SFTP_ST"
    echo "Host     : $SERVER_IP"
    echo "Port     : $SFTP_PORT"
    echo "Username : $SFTP_USER"
    echo "Password : $SFTP_PASS"
    echo ""

    echo -e "${GREEN}Quick connect:${RESET}"
    echo "${SFTP_USER}@${SERVER_IP}:${SFTP_PORT}"

    echo -e "${WHITE}================================${RESET}"
    echo ""
}

# ======================================
# RESET PASSWORD
# ======================================

reset_password(){
    list_domains_sftp_enabled
    echo ""
    read -p "Select domain number: " CHOICE

    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; return; }

    local ENV_FILE="$DOMAINS_ROOT/$FOLDER/config/domain.env"
    local DOMAIN
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    local NEW_PASS
    NEW_PASS=$(generate_pass)

    echo "$FOLDER:$NEW_PASS" | chpasswd
    sed -i "s/^SFTP_PASS=.*/SFTP_PASS=$NEW_PASS/" "$ENV_FILE"
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    ok "Password reset for $DOMAIN"
    echo "New Password : $NEW_PASS"
    log "SFTP password reset for $DOMAIN"
}

# ======================================
# ENABLE / DISABLE
# ======================================

toggle_sftp(){
    list_domains_sftp_enabled
    echo ""
    read -p "Select domain number: " CHOICE

    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; return; }

    local ENV_FILE="$DOMAINS_ROOT/$FOLDER/config/domain.env"
    local DOMAIN SFTP_ST
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    SFTP_ST=$(grep "^SFTP="  "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    if [ "$SFTP_ST" = "enabled" ]; then
        usermod -L "$FOLDER"
        sed -i 's/^SFTP=.*/SFTP=disabled/' "$ENV_FILE"
        ok "SFTP disabled for $DOMAIN"
        log "SFTP disabled for $DOMAIN"
    else
        usermod -U "$FOLDER"
        sed -i 's/^SFTP=.*/SFTP=enabled/' "$ENV_FILE"
        ok "SFTP enabled for $DOMAIN"
        log "SFTP enabled for $DOMAIN"
    fi
}

# ======================================
# DELETE SFTP
# ======================================

delete_sftp(){
    list_domains_sftp_enabled
    echo ""
    read -p "Select domain number: " CHOICE

    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"
    [ -z "$FOLDER" ] && { fail "Invalid selection"; return; }

    local ENV_FILE="$DOMAINS_ROOT/$FOLDER/config/domain.env"
    local DOMAIN
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    echo ""
    echo -e "\e[31mWARNING: This will remove SFTP access for $DOMAIN!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; return; }

    gpasswd -d "$FOLDER" sftpusers &>/dev/null
    sed -i '/^SFTP=/d; /^SFTP_USER=/d; /^SFTP_PASS=/d; /^SFTP_PORT=/d' "$ENV_FILE"

    ok "SFTP removed for $DOMAIN"
    log "SFTP deleted for $DOMAIN"
}

# ======================================
# MENU
# ======================================

ensure_sftp_config

while true; do
    clear
    sp_header "SFTP Manager" "Isolated SFTP accounts"
    sp_menu_grid \
        "1|Create SFTP Account|green" \
        "2|View Account Info|cyan" \
        "3|List All Accounts|blue" \
        "4|Enable / Disable|yellow" \
        "5|Reset Password|yellow" \
        "6|Delete SFTP Account|red" \
        "0|Back|white"
    sp_prompt CHOICE

    case $CHOICE in
        1) create_sftp;               echo ""; read -p "Press Enter..." ;;
        2) view_account;              echo ""; read -p "Press Enter..." ;;
        3) list_domains_sftp_enabled; echo ""; read -p "Press Enter..." ;;
        4) toggle_sftp;               echo ""; read -p "Press Enter..." ;;
        5) reset_password;            echo ""; read -p "Press Enter..." ;;
        6) delete_sftp;               echo ""; read -p "Press Enter..." ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
