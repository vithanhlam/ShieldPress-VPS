#!/bin/bash
# =====================================================
# ShieldPress Backup Encryption Manager
# AES-256-CBC encryption for backups
# =====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
KEY_FILE="$ETC_DIR/backup.key"
ENCRYPT_CONF="$ETC_DIR/backup-encrypt.env"
LOG_FILE="$LOG_DIR/backup.log"

source "$BASE_DIR/core/ui.sh"
source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$ETC_DIR" "$LOG_DIR"

log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

# =====================================================
# KEY MANAGEMENT
# =====================================================

generate_key(){
    if [ -f "$KEY_FILE" ]; then
        echo ""
        echo -e "\e[33mWARNING: Encryption key already exists!\e[0m"
        echo "Generating a new key will make OLD encrypted backups UNRECOVERABLE."
        echo ""
        read -p "Continue? (yes/no): " CONFIRM
        [ "$CONFIRM" != "yes" ] && { echo "Cancelled."; return; }

        # Backup old key
        cp "$KEY_FILE" "${KEY_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
        echo "[OK] Old key backed up"
    fi

    openssl rand -base64 32 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    chown root:root "$KEY_FILE"

    echo "[OK] Encryption key generated: $KEY_FILE"
    echo ""
    echo -e "\e[31m=== IMPORTANT ===\e[0m"
    echo "Save this key somewhere safe OUTSIDE this server."
    echo "If you lose this key, encrypted backups CANNOT be recovered."
    echo ""
    echo "Key: $(cat "$KEY_FILE")"
    echo ""

    log "Backup encryption key generated"
}

show_key(){
    if [ ! -f "$KEY_FILE" ]; then
        echo "No encryption key found. Generate one first."
        return 1
    fi
    echo ""
    echo "Current encryption key:"
    echo "--------------------------------"
    cat "$KEY_FILE"
    echo ""
    echo "--------------------------------"
    echo "File: $KEY_FILE"
    echo ""
}

import_key(){
    echo ""
    echo "Import an existing encryption key (e.g. from another server)."
    echo "Paste the base64 key below:"
    echo ""
    read -p "Key: " IMPORT_KEY

    if [ -z "$IMPORT_KEY" ]; then
        echo "Empty key. Cancelled."
        return 1
    fi

    # Validate base64
    if ! echo "$IMPORT_KEY" | base64 -d >/dev/null 2>&1; then
        echo "Invalid base64 key!"
        return 1
    fi

    if [ -f "$KEY_FILE" ]; then
        cp "$KEY_FILE" "${KEY_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
        echo "[OK] Old key backed up"
    fi

    echo "$IMPORT_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    chown root:root "$KEY_FILE"

    echo "[OK] Key imported successfully"
    log "Backup encryption key imported"
}

# =====================================================
# ENCRYPTION SETTINGS
# =====================================================

get_encrypt_enabled(){
    [ -f "$ENCRYPT_CONF" ] || { echo "0"; return; }
    grep "^ENCRYPT_ENABLED=" "$ENCRYPT_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]'
}

enable_encryption(){
    if [ ! -f "$KEY_FILE" ]; then
        echo "No encryption key found. Generating one..."
        generate_key
    fi

    mkdir -p "$(dirname "$ENCRYPT_CONF")"
    echo "ENCRYPT_ENABLED=1" > "$ENCRYPT_CONF"
    chmod 600 "$ENCRYPT_CONF"

    echo ""
    echo "[OK] Backup encryption ENABLED"
    echo "All new backups will be encrypted with AES-256-CBC."
    log "Backup encryption enabled"
}

disable_encryption(){
    if [ -f "$ENCRYPT_CONF" ]; then
        sed -i 's/^ENCRYPT_ENABLED=.*/ENCRYPT_ENABLED=0/' "$ENCRYPT_CONF"
    fi
    echo "[OK] Backup encryption DISABLED"
    echo "New backups will NOT be encrypted."
    log "Backup encryption disabled"
}

# =====================================================
# ENCRYPT / DECRYPT FILES
# =====================================================

# Encrypt a file in-place (replaces original with .enc version)
# Usage: encrypt_backup "/path/to/backup.tar.gz"
# Result: /path/to/backup.tar.gz.enc (original deleted)
encrypt_backup(){
    local FILE="$1"

    [ ! -f "$FILE" ] && { echo "[FAIL] File not found: $FILE"; return 1; }
    [ ! -f "$KEY_FILE" ] && { echo "[FAIL] Encryption key not found"; return 1; }

    local ENC_FILE="${FILE}.enc"
    local KEY
    KEY=$(cat "$KEY_FILE")

    if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$FILE" -out "$ENC_FILE" -pass "pass:$KEY" 2>/dev/null; then
        rm -f "$FILE"
        echo "[OK] Encrypted: $(basename "$ENC_FILE")"
        log "Encrypted backup: $ENC_FILE"
        # Return the new path
        echo "$ENC_FILE"
        return 0
    else
        rm -f "$ENC_FILE"
        echo "[FAIL] Encryption failed: $FILE"
        log "FAILED to encrypt: $FILE"
        return 1
    fi
}

# Decrypt a .enc file (replaces .enc with decrypted version)
# Usage: decrypt_backup "/path/to/backup.tar.gz.enc"
# Result: /path/to/backup.tar.gz (.enc deleted)
decrypt_backup(){
    local ENC_FILE="$1"

    [ ! -f "$ENC_FILE" ] && { echo "[FAIL] File not found: $ENC_FILE"; return 1; }
    [ ! -f "$KEY_FILE" ] && { echo "[FAIL] Encryption key not found"; return 1; }

    local DEC_FILE="${ENC_FILE%.enc}"
    local KEY
    KEY=$(cat "$KEY_FILE")

    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$ENC_FILE" -out "$DEC_FILE" -pass "pass:$KEY" 2>/dev/null; then
        rm -f "$ENC_FILE"
        echo "[OK] Decrypted: $(basename "$DEC_FILE")"
        log "Decrypted backup: $DEC_FILE"
        return 0
    else
        rm -f "$DEC_FILE"
        echo "[FAIL] Decryption failed. Wrong key or corrupted file."
        log "FAILED to decrypt: $ENC_FILE"
        return 1
    fi
}

# Check if encryption is enabled and key exists.
# Returns 0 if should encrypt, 1 if not.
should_encrypt(){
    [ "$(get_encrypt_enabled)" = "1" ] && [ -f "$KEY_FILE" ]
}

# Encrypt if enabled, otherwise do nothing. Returns final file path.
# Usage: FINAL=$(maybe_encrypt "$BACKUP_FILE")
maybe_encrypt(){
    local FILE="$1"
    if should_encrypt; then
        encrypt_backup "$FILE" | tail -1
    else
        echo "$FILE"
    fi
}

# =====================================================
# MANUAL ENCRYPT / DECRYPT
# =====================================================

manual_encrypt(){
    echo ""
    echo "Select a backup file to encrypt:"
    echo ""

    local FILES=()
    local i=1
    for f in "$DOMAINS_ROOT"/*/backup/*/*.tar.gz "$DOMAINS_ROOT"/*/backup/*/*.sql.gz; do
        [ -f "$f" ] || continue
        local SIZE
        SIZE=$(du -h "$f" | awk '{print $1}')
        echo "$i) $(basename "$f")  [$SIZE]"
        FILES[$i]="$f"
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No unencrypted backup files found."; return; }

    echo ""
    read -p "Select file number: " choice
    local SELECTED="${FILES[$choice]}"
    [ -z "$SELECTED" ] && { echo "Invalid selection"; return; }

    encrypt_backup "$SELECTED"
}

manual_decrypt(){
    echo ""
    echo "Select an encrypted backup to decrypt:"
    echo ""

    local FILES=()
    local i=1
    for f in "$DOMAINS_ROOT"/*/backup/*/*.enc; do
        [ -f "$f" ] || continue
        local SIZE
        SIZE=$(du -h "$f" | awk '{print $1}')
        echo "$i) $(basename "$f")  [$SIZE]"
        FILES[$i]="$f"
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No encrypted backup files found."; return; }

    echo ""
    read -p "Select file number: " choice
    local SELECTED="${FILES[$choice]}"
    [ -z "$SELECTED" ] && { echo "Invalid selection"; return; }

    decrypt_backup "$SELECTED"
}

# =====================================================
# STATUS
# =====================================================

show_status(){
    echo ""
    echo "======================================"
    echo "  BACKUP ENCRYPTION STATUS"
    echo "======================================"

    local ENABLED
    ENABLED=$(get_encrypt_enabled)

    if [ "$ENABLED" = "1" ]; then
        echo -e "  Status    : \e[32mENABLED\e[0m"
    else
        echo -e "  Status    : \e[33mDISABLED\e[0m"
    fi

    if [ -f "$KEY_FILE" ]; then
        echo -e "  Key       : \e[32mPresent\e[0m ($KEY_FILE)"
    else
        echo -e "  Key       : \e[31mNot found\e[0m"
    fi

    echo "  Algorithm : AES-256-CBC (PBKDF2, 100k iterations)"

    # Count encrypted backups
    local ENC_COUNT=0
    ENC_COUNT=$(find "$DOMAINS_ROOT" -name "*.enc" -type f 2>/dev/null | wc -l)
    echo "  Encrypted : $ENC_COUNT backup files"

    echo "======================================"
}

# =====================================================
# MENU
# =====================================================

while true; do
    clear
    sp_header "Backup Encryption" "AES-256 encryption for backups"

    ENABLED=$(get_encrypt_enabled)
    [ "$ENABLED" = "1" ] && ST_TEXT="ENABLED" || ST_TEXT="DISABLED"
    echo "  Status: $ST_TEXT"
    echo ""

    sp_menu_grid \
        "1|Enable Encryption|green" \
        "2|Disable Encryption|yellow" \
        "3|Generate New Key|cyan" \
        "4|Show Current Key|blue" \
        "5|Import Key|magenta" \
        "6|Encrypt Backup|green" \
        "7|Decrypt Backup|yellow" \
        "8|Encryption Status|cyan" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) enable_encryption; read -p "Enter..." ;;
        2) disable_encryption; read -p "Enter..." ;;
        3) generate_key; read -p "Enter..." ;;
        4) show_key; read -p "Enter..." ;;
        5) import_key; read -p "Enter..." ;;
        6) manual_encrypt; read -p "Enter..." ;;
        7) manual_decrypt; read -p "Enter..." ;;
        8) show_status; read -p "Enter..." ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
