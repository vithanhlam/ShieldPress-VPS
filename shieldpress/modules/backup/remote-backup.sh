#!/bin/bash

BASE_DIR="/opt/shieldpress"
CONFIG_DIR="$BASE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/backup-remote.env"
RCLONE_CONF="/root/.config/rclone/rclone.conf"

mkdir -p "$CONFIG_DIR"

pause(){ echo ""; read -p "Press Enter..."; }

# ==================================================
# AUTO-INSTALL RCLONE
# ==================================================
install_rclone(){
    echo ""
    echo "Installing rclone..."
    echo "--------------------------------------------------"

    # Detect OS and install
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y rclone 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y rclone 2>/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y rclone 2>/dev/null
    fi

    # If package manager failed, use official install script
    if ! command -v rclone >/dev/null 2>&1; then
        echo "Package manager install failed, using official script..."
        curl -fsSL https://rclone.org/install.sh | bash 2>/dev/null
    fi

    if command -v rclone >/dev/null 2>&1; then
        echo "[OK] rclone installed: $(rclone version --check 2>/dev/null | head -1 || rclone version 2>/dev/null | head -1)"
        return 0
    else
        echo "[FAIL] Could not install rclone automatically"
        echo "Try manually: curl https://rclone.org/install.sh | bash"
        return 1
    fi
}

ensure_rclone(){
    if command -v rclone >/dev/null 2>&1; then
        return 0
    fi
    echo ""
    echo "rclone is not installed."
    read -p "Install rclone automatically? (y/n): " ANS
    [[ "$ANS" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 1; }
    install_rclone
}

# ==================================================
# SHOW CURRENT CONFIG
# ==================================================
show_current(){
    echo "Current remote backup config:"
    echo "--------------------------------------------------"
    if [ -f "$CONFIG_FILE" ]; then
        local ENABLED REMOTES PATH_VAL RETENTION DEL_LOCAL
        ENABLED=$(grep "^REMOTE_ENABLED=" "$CONFIG_FILE" | cut -d'=' -f2)
        REMOTES=$(grep "^RCLONE_REMOTES=" "$CONFIG_FILE" | cut -d'=' -f2-)
        PATH_VAL=$(grep "^RCLONE_PATH=" "$CONFIG_FILE" | cut -d'=' -f2-)
        RETENTION=$(grep "^REMOTE_RETENTION=" "$CONFIG_FILE" | cut -d'=' -f2)
        DEL_LOCAL=$(grep "^DELETE_LOCAL_AFTER_UPLOAD=" "$CONFIG_FILE" | cut -d'=' -f2)

        [ "$ENABLED" = "1" ] && echo "  Status    : ENABLED" || echo "  Status    : DISABLED"
        [ -n "$REMOTES" ] && echo "  Remotes   : $REMOTES"
        [ -n "$PATH_VAL" ] && echo "  Path      : $PATH_VAL"
        [ -n "$RETENTION" ] && echo "  Retention : $RETENTION backups per domain/type"
        if [ "$DEL_LOCAL" = "1" ]; then
            echo "  Local     : DELETE after upload"
        else
            echo "  Local     : KEEP after upload"
        fi
    else
        echo "  Not configured"
    fi
    echo "--------------------------------------------------"
}

# ==================================================
# WRITE CONFIG
# ==================================================
write_config(){
    cat > "$CONFIG_FILE" <<EOF
REMOTE_ENABLED=$REMOTE_ENABLED
RCLONE_REMOTE=$RCLONE_REMOTE
RCLONE_REMOTES=$RCLONE_REMOTES
RCLONE_PATH=$RCLONE_PATH
REMOTE_RETENTION=$REMOTE_RETENTION
DELETE_LOCAL_AFTER_UPLOAD=$DELETE_LOCAL_AFTER_UPLOAD
EOF
    chmod 600 "$CONFIG_FILE"
}

# ==================================================
# CONFIGURE S3 (paste keys)
# ==================================================
configure_s3(){
    echo ""
    echo "========== S3 / S3-Compatible Setup =========="
    echo ""
    echo "Supported: AWS S3, Cloudflare R2, MinIO, Backblaze B2, DigitalOcean Spaces, etc."
    echo ""

    read -p "Remote name (e.g. my-s3): " REMOTE_NAME
    REMOTE_NAME="${REMOTE_NAME%:}"
    [ -z "$REMOTE_NAME" ] && { echo "Remote name required"; return 1; }

    echo ""
    echo "Common S3 providers:"
    echo "  1) AWS S3              (s3.amazonaws.com)"
    echo "  2) Cloudflare R2       (<account_id>.r2.cloudflarestorage.com)"
    echo "  3) DigitalOcean Spaces (<region>.digitaloceanspaces.com)"
    echo "  4) Backblaze B2        (s3.<region>.backblazeb2.com)"
    echo "  5) MinIO / Custom"
    echo ""
    read -p "Select provider (1-5): " S3_PROVIDER

    local S3_ENDPOINT="" S3_REGION=""
    case $S3_PROVIDER in
        1)
            read -p "AWS Region (e.g. us-east-1): " S3_REGION
            S3_ENDPOINT="s3.${S3_REGION}.amazonaws.com"
            ;;
        2)
            read -p "Cloudflare Account ID: " CF_ACCOUNT
            S3_ENDPOINT="${CF_ACCOUNT}.r2.cloudflarestorage.com"
            S3_REGION="auto"
            ;;
        3)
            read -p "Region (e.g. sgp1, nyc3): " S3_REGION
            S3_ENDPOINT="${S3_REGION}.digitaloceanspaces.com"
            ;;
        4)
            read -p "Region (e.g. us-west-004): " S3_REGION
            S3_ENDPOINT="s3.${S3_REGION}.backblazeb2.com"
            ;;
        5)
            read -p "Endpoint URL (e.g. https://minio.example.com): " S3_ENDPOINT
            S3_ENDPOINT=$(echo "$S3_ENDPOINT" | sed 's|^https\?://||')
            read -p "Region (leave empty if none): " S3_REGION
            ;;
        *)
            echo "Invalid option"; return 1
            ;;
    esac

    echo ""
    read -p "Access Key ID: " S3_KEY
    [ -z "$S3_KEY" ] && { echo "Access Key is required"; return 1; }

    read -sp "Secret Access Key: " S3_SECRET
    echo ""
    [ -z "$S3_SECRET" ] && { echo "Secret Key is required"; return 1; }

    read -p "Bucket name: " S3_BUCKET
    [ -z "$S3_BUCKET" ] && { echo "Bucket name is required"; return 1; }

    # Write rclone config directly
    mkdir -p "$(dirname "$RCLONE_CONF")"
    # Remove existing section if any
    if [ -f "$RCLONE_CONF" ]; then
        sed -i "/^\[${REMOTE_NAME}\]$/,/^\[/{ /^\[${REMOTE_NAME}\]$/d; /^\[/!d; }" "$RCLONE_CONF"
    fi

    cat >> "$RCLONE_CONF" <<EOF

[${REMOTE_NAME}]
type = s3
provider = Other
env_auth = false
access_key_id = ${S3_KEY}
secret_access_key = ${S3_SECRET}
endpoint = ${S3_ENDPOINT}
$([ -n "$S3_REGION" ] && echo "region = ${S3_REGION}")
acl = private
EOF

    RCLONE_REMOTE="$REMOTE_NAME"
    echo ""
    echo "[OK] S3 remote '${REMOTE_NAME}' configured"

    # Verify connection
    echo "Testing connection..."
    if rclone lsd "${REMOTE_NAME}:${S3_BUCKET}" >/dev/null 2>&1 || rclone mkdir "${REMOTE_NAME}:${S3_BUCKET}" >/dev/null 2>&1; then
        echo "[OK] Connection successful"
        # Set path with bucket
        RCLONE_PATH="${S3_BUCKET}/shieldpress-backups"
    else
        echo "[WARN] Could not verify connection. Check your keys and endpoint."
        RCLONE_PATH="${S3_BUCKET}/shieldpress-backups"
    fi

    return 0
}

# ==================================================
# CONFIGURE GOOGLE DRIVE
# ==================================================
configure_gdrive(){
    echo ""
    echo "========== Google Drive Setup =========="
    echo ""

    read -p "Remote name (e.g. my-gdrive): " REMOTE_NAME
    REMOTE_NAME="${REMOTE_NAME%:}"
    [ -z "$REMOTE_NAME" ] && { echo "Remote name required"; return 1; }

    echo ""
    echo "Auth method:"
    echo "  1) Service Account JSON (headless server - no browser needed)"
    echo "  2) OAuth Token (paste token from local machine)"
    echo "  3) OAuth Interactive (this machine has a browser)"
    echo ""
    read -p "Select (1-3): " AUTH_METHOD

    mkdir -p "$(dirname "$RCLONE_CONF")"
    # Remove existing section
    if [ -f "$RCLONE_CONF" ]; then
        sed -i "/^\[${REMOTE_NAME}\]$/,/^\[/{ /^\[${REMOTE_NAME}\]$/d; /^\[/!d; }" "$RCLONE_CONF"
    fi

    case $AUTH_METHOD in
        1)
            echo ""
            echo "=== Service Account Setup ==="
            echo ""
            echo "Steps:"
            echo "  1. Go to: https://console.cloud.google.com/iam-admin/serviceaccounts"
            echo "  2. Create service account -> Create key -> JSON"
            echo "  3. Upload the JSON file to this server"
            echo "  4. Share a Google Drive folder with the service account email"
            echo ""
            read -p "Path to service account JSON file on this server: " SA_FILE
            if [ ! -f "$SA_FILE" ]; then
                echo "[FAIL] File not found: $SA_FILE"
                return 1
            fi

            read -p "Google Drive folder ID (from folder URL): " FOLDER_ID
            [ -z "$FOLDER_ID" ] && { echo "Folder ID required"; return 1; }

            cat >> "$RCLONE_CONF" <<EOF

[${REMOTE_NAME}]
type = drive
scope = drive
service_account_file = ${SA_FILE}
root_folder_id = ${FOLDER_ID}
EOF
            ;;
        2)
            echo ""
            echo "=== OAuth Token (Headless Server) ==="
            echo ""
            echo "On your LOCAL machine (laptop/desktop with browser):"
            echo "--------------------------------------------------"
            echo "  Step 1: Install rclone on local machine"
            echo "          https://rclone.org/install/"
            echo ""
            echo "  Step 2: Run this command on your LOCAL machine:"
            echo ""
            echo "    rclone authorize \"drive\""
            echo ""
            echo "  Step 3: A browser will open, login to Google"
            echo "  Step 4: Copy the token JSON that rclone outputs"
            echo "          (starts with {\"access_token\":...})"
            echo "--------------------------------------------------"
            echo ""

            # Optional: Client ID for higher quota
            echo "Optional: Use your own Client ID for higher API quota"
            echo "(Get one at: https://console.cloud.google.com/apis/credentials)"
            read -p "Client ID (Enter to skip): " GDRIVE_CLIENT_ID
            read -p "Client Secret (Enter to skip): " GDRIVE_CLIENT_SECRET
            echo ""

            # If user has custom client ID, tell them to use it in authorize command
            if [ -n "$GDRIVE_CLIENT_ID" ] && [ -n "$GDRIVE_CLIENT_SECRET" ]; then
                echo "Run this command on your LOCAL machine instead:"
                echo ""
                echo "  rclone authorize \"drive\" \"${GDRIVE_CLIENT_ID}\" \"${GDRIVE_CLIENT_SECRET}\""
                echo ""
            fi

            echo "Paste the token JSON from rclone authorize output:"
            echo "(paste the entire JSON starting with { and ending with })"
            echo ""
            local TOKEN_JSON=""
            local LINE=""
            local BRACE_COUNT=0
            local STARTED=0

            while IFS= read -r LINE; do
                TOKEN_JSON="${TOKEN_JSON}${LINE}"
                # Count braces
                local OPEN="${LINE//[^\{]/}"
                local CLOSE="${LINE//[^\}]/}"
                BRACE_COUNT=$((BRACE_COUNT + ${#OPEN} - ${#CLOSE}))
                STARTED=1
                [ "$BRACE_COUNT" -le 0 ] && [ "$STARTED" -eq 1 ] && break
            done

            if [ -z "$TOKEN_JSON" ]; then
                echo "[FAIL] No token provided"
                return 1
            fi

            # Validate it looks like JSON
            if ! echo "$TOKEN_JSON" | grep -q '"access_token"'; then
                echo "[FAIL] Invalid token. Must contain access_token field."
                echo "Make sure you paste the complete JSON from rclone authorize."
                return 1
            fi

            # Escape token for rclone config
            local TOKEN_ESCAPED
            TOKEN_ESCAPED=$(echo "$TOKEN_JSON" | tr -d '\n' | sed 's/[[:space:]]\+/ /g')

            read -p "Google Drive folder ID to backup to (Enter for root): " FOLDER_ID

            cat >> "$RCLONE_CONF" <<EOF

[${REMOTE_NAME}]
type = drive
scope = drive
$([ -n "$GDRIVE_CLIENT_ID" ] && echo "client_id = ${GDRIVE_CLIENT_ID}")
$([ -n "$GDRIVE_CLIENT_SECRET" ] && echo "client_secret = ${GDRIVE_CLIENT_SECRET}")
token = ${TOKEN_ESCAPED}
$([ -n "$FOLDER_ID" ] && echo "root_folder_id = ${FOLDER_ID}")
EOF
            # Clean up empty lines from conditional writes
            sed -i '/^$/{ N; /^\n$/d; }' "$RCLONE_CONF"
            ;;
        3)
            echo ""
            echo "=== OAuth Interactive ==="
            echo "A browser will open to authorize Google Drive access."
            echo ""
            rclone config create "$REMOTE_NAME" drive scope=drive
            ;;
        *)
            echo "Invalid option"; return 1
            ;;
    esac

    RCLONE_REMOTE="$REMOTE_NAME"
    RCLONE_PATH="shieldpress-backups"

    echo ""
    echo "Testing connection..."
    if rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        echo "[OK] Google Drive connected"
    else
        echo "[WARN] Could not verify connection. Check configuration."
    fi

    return 0
}

# ==================================================
# CONFIGURE ONEDRIVE
# ==================================================
configure_onedrive(){
    echo ""
    echo "========== OneDrive Setup =========="
    echo ""

    read -p "Remote name (e.g. my-onedrive): " REMOTE_NAME
    REMOTE_NAME="${REMOTE_NAME%:}"
    [ -z "$REMOTE_NAME" ] && { echo "Remote name required"; return 1; }

    echo ""
    echo "Auth method:"
    echo "  1) OAuth Token (paste token from local machine)"
    echo "  2) OAuth Interactive (this machine has a browser)"
    echo ""
    read -p "Select (1-2): " AUTH_METHOD

    mkdir -p "$(dirname "$RCLONE_CONF")"
    # Remove existing section
    if [ -f "$RCLONE_CONF" ]; then
        sed -i "/^\[${REMOTE_NAME}\]$/,/^\[/{ /^\[${REMOTE_NAME}\]$/d; /^\[/!d; }" "$RCLONE_CONF"
    fi

    case $AUTH_METHOD in
        1)
            echo ""
            echo "=== OAuth Token (Headless Server) ==="
            echo ""
            echo "On your LOCAL machine (laptop/desktop with browser):"
            echo "--------------------------------------------------"
            echo "  Step 1: Install rclone on local machine"
            echo "          https://rclone.org/install/"
            echo ""
            echo "  Step 2: Run this command on your LOCAL machine:"
            echo ""
            echo "    rclone authorize \"onedrive\""
            echo ""
            echo "  Step 3: A browser will open, login to Microsoft"
            echo "  Step 4: Copy the token JSON that rclone outputs"
            echo "          (starts with {\"access_token\":...})"
            echo "--------------------------------------------------"
            echo ""
            echo "Paste the token JSON from rclone authorize output:"
            echo ""

            local TOKEN_JSON=""
            local LINE=""
            local BRACE_COUNT=0
            local STARTED=0

            while IFS= read -r LINE; do
                TOKEN_JSON="${TOKEN_JSON}${LINE}"
                local OPEN="${LINE//[^\{]/}"
                local CLOSE="${LINE//[^\}]/}"
                BRACE_COUNT=$((BRACE_COUNT + ${#OPEN} - ${#CLOSE}))
                STARTED=1
                [ "$BRACE_COUNT" -le 0 ] && [ "$STARTED" -eq 1 ] && break
            done

            if [ -z "$TOKEN_JSON" ]; then
                echo "[FAIL] No token provided"
                return 1
            fi

            if ! echo "$TOKEN_JSON" | grep -q '"access_token"'; then
                echo "[FAIL] Invalid token. Must contain access_token field."
                return 1
            fi

            local TOKEN_ESCAPED
            TOKEN_ESCAPED=$(echo "$TOKEN_JSON" | tr -d '\n' | sed 's/[[:space:]]\+/ /g')

            echo ""
            echo "OneDrive type:"
            echo "  1) OneDrive Personal"
            echo "  2) OneDrive Business"
            echo "  3) SharePoint"
            read -p "Select (1-3) [1]: " OD_TYPE
            local DRIVE_TYPE="personal"
            case $OD_TYPE in
                2) DRIVE_TYPE="business" ;;
                3) DRIVE_TYPE="documentLibrary" ;;
                *) DRIVE_TYPE="personal" ;;
            esac

            cat >> "$RCLONE_CONF" <<EOF

[${REMOTE_NAME}]
type = onedrive
token = ${TOKEN_ESCAPED}
drive_type = ${DRIVE_TYPE}
EOF
            ;;
        2)
            echo ""
            echo "=== OAuth Interactive ==="
            echo "A browser will open to authorize OneDrive access."
            echo ""
            rclone config create "$REMOTE_NAME" onedrive
            ;;
        *)
            echo "Invalid option"; return 1
            ;;
    esac

    RCLONE_REMOTE="$REMOTE_NAME"
    RCLONE_PATH="shieldpress-backups"

    echo ""
    echo "Testing connection..."
    if rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        echo "[OK] OneDrive connected"
    else
        echo "[WARN] Could not verify connection. Check configuration."
    fi

    return 0
}

# ==================================================
# CONFIGURE EXISTING REMOTE
# ==================================================
configure_existing(){
    echo ""
    echo "Configured rclone remotes:"
    echo "--------------------------------------------------"
    rclone listremotes 2>/dev/null || echo "  (none)"
    echo "--------------------------------------------------"
    echo ""
    read -p "Remote name to use: " REMOTE_NAME
    REMOTE_NAME="${REMOTE_NAME%:}"
    [ -z "$REMOTE_NAME" ] && { echo "Remote name required"; return 1; }

    if ! rclone listremotes 2>/dev/null | grep -qx "${REMOTE_NAME}:"; then
        echo "[FAIL] Remote not found: $REMOTE_NAME"
        return 1
    fi

    RCLONE_REMOTE="$REMOTE_NAME"
    RCLONE_PATH="shieldpress-backups"
    return 0
}

# ==================================================
# MAIN CONFIGURE WIZARD
# ==================================================
configure_remote(){
    ensure_rclone || { pause; return; }

    echo ""
    echo "Select cloud provider:"
    echo "  1) S3 / S3-compatible (AWS, Cloudflare R2, DO Spaces, etc.)"
    echo "  2) Google Drive"
    echo "  3) OneDrive"
    echo "  4) Use existing rclone remote"
    echo ""
    read -p "Select (1-4): " PROVIDER

    case $PROVIDER in
        1) configure_s3 || { pause; return; } ;;
        2) configure_gdrive || { pause; return; } ;;
        3) configure_onedrive || { pause; return; } ;;
        4) configure_existing || { pause; return; } ;;
        *) echo "Invalid option"; pause; return ;;
    esac

    # --- Common settings ---
    echo ""
    echo "========== Backup Options =========="

    # Multi-remote upload
    echo ""
    echo "Current primary remote: $RCLONE_REMOTE"
    read -p "Upload to additional remotes? (comma-separated, or Enter to skip): " EXTRA_REMOTES
    if [ -n "$EXTRA_REMOTES" ]; then
        RCLONE_REMOTES="${RCLONE_REMOTE},${EXTRA_REMOTES}"
        RCLONE_REMOTES=$(echo "$RCLONE_REMOTES" | sed 's/[[:space:]]//g;s/:,/,/g;s/:$//')
    else
        RCLONE_REMOTES="$RCLONE_REMOTE"
    fi

    # Remote path
    echo ""
    read -p "Remote folder path [${RCLONE_PATH:-shieldpress-backups}]: " INPUT_PATH
    RCLONE_PATH="${INPUT_PATH:-${RCLONE_PATH:-shieldpress-backups}}"
    RCLONE_PATH="${RCLONE_PATH#/}"
    RCLONE_PATH="${RCLONE_PATH%/}"

    # Retention
    echo ""
    echo "How many remote backups to keep per domain/type?"
    echo "  0 = keep all (no auto-delete)"
    echo "  1-120 = auto-delete oldest when exceeded"
    while true; do
        read -p "Retention count [7]: " REMOTE_RETENTION
        REMOTE_RETENTION="${REMOTE_RETENTION:-7}"
        [[ "$REMOTE_RETENTION" =~ ^[0-9]+$ ]] && [ "$REMOTE_RETENTION" -le 120 ] && break
        echo "Enter a number from 0 to 120"
    done

    # Delete local after upload
    echo ""
    echo "After uploading backup to remote:"
    echo "  1) Keep local backup files"
    echo "  2) Delete local backup files (save disk space)"
    read -p "Select (1-2) [1]: " DEL_CHOICE
    case $DEL_CHOICE in
        2) DELETE_LOCAL_AFTER_UPLOAD=1 ;;
        *) DELETE_LOCAL_AFTER_UPLOAD=0 ;;
    esac

    REMOTE_ENABLED=1
    write_config

    echo ""
    echo "===================================================="
    echo "[OK] Remote backup configured!"
    echo "  Remotes   : $RCLONE_REMOTES"
    echo "  Path      : $RCLONE_PATH"
    echo "  Retention : $REMOTE_RETENTION per domain/type"
    if [ "$DELETE_LOCAL_AFTER_UPLOAD" = "1" ]; then
        echo "  Local     : DELETE after upload"
    else
        echo "  Local     : KEEP after upload"
    fi
    echo "===================================================="
    pause
}

# ==================================================
# DISABLE REMOTE
# ==================================================
disable_remote(){
    if [ -f "$CONFIG_FILE" ]; then
        sed -i 's/^REMOTE_ENABLED=.*/REMOTE_ENABLED=0/' "$CONFIG_FILE"
    else
        REMOTE_ENABLED=0
        RCLONE_REMOTE=""
        RCLONE_REMOTES=""
        RCLONE_PATH="shieldpress-backups"
        REMOTE_RETENTION=0
        DELETE_LOCAL_AFTER_UPLOAD=0
        write_config
    fi
    echo "[OK] Remote backup disabled"
    pause
}

# ==================================================
# TEST REMOTE UPLOAD
# ==================================================
test_remote(){
    ensure_rclone || { pause; return; }
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Remote backup is not configured"
        pause; return
    fi

    RCLONE_REMOTE=$(grep "^RCLONE_REMOTE=" "$CONFIG_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    RCLONE_REMOTES=$(grep "^RCLONE_REMOTES=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    RCLONE_REMOTES="${RCLONE_REMOTES:-$RCLONE_REMOTE}"
    RCLONE_PATH=$(grep "^RCLONE_PATH=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's#^/##;s#/$##')

    TMP="/tmp/shieldpress-rclone-test-$(date +%s).txt"
    echo "SHIELDPRESS remote backup test $(date '+%F %T')" > "$TMP"
    STATUS=0
    while read -r REMOTE; do
        REMOTE="${REMOTE%:}"
        [ -z "$REMOTE" ] && continue
        echo "Testing upload to: ${REMOTE}:${RCLONE_PATH}/_test ..."
        if rclone copy "$TMP" "${REMOTE}:${RCLONE_PATH}/_test" --no-traverse; then
            echo "[OK] Upload to $REMOTE succeeded"
            # Cleanup: delete the test file then remove the empty _test/ folder
            rclone deletefile "${REMOTE}:${RCLONE_PATH}/_test/$(basename "$TMP")" >/dev/null 2>&1 || true
            rclone rmdir "${REMOTE}:${RCLONE_PATH}/_test" >/dev/null 2>&1 || true
        else
            echo "[FAIL] Upload to $REMOTE failed"
            STATUS=1
        fi
    done <<< "$(echo "$RCLONE_REMOTES" | tr ',' '\n')"
    rm -f "$TMP"

    echo ""
    if [ "$STATUS" -eq 0 ]; then
        echo "[OK] All upload tests passed!"
    else
        echo "[FAIL] Some upload tests failed. Check your configuration."
    fi
    pause
}

# ==================================================
# EDIT OPTIONS (quick change without reconfiguring remote)
# ==================================================
edit_options(){
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Remote backup is not configured. Use option 1 first."
        pause; return
    fi

    echo ""
    echo "========== Edit Backup Options =========="

    local CUR_RETENTION CUR_DELETE CUR_PATH
    CUR_RETENTION=$(grep "^REMOTE_RETENTION=" "$CONFIG_FILE" | cut -d'=' -f2)
    CUR_DELETE=$(grep "^DELETE_LOCAL_AFTER_UPLOAD=" "$CONFIG_FILE" | cut -d'=' -f2)
    CUR_PATH=$(grep "^RCLONE_PATH=" "$CONFIG_FILE" | cut -d'=' -f2-)

    echo ""
    echo "Current retention: ${CUR_RETENTION:-0}"
    while true; do
        read -p "New retention count (0-120) [${CUR_RETENTION:-0}]: " NEW_RET
        NEW_RET="${NEW_RET:-${CUR_RETENTION:-0}}"
        [[ "$NEW_RET" =~ ^[0-9]+$ ]] && [ "$NEW_RET" -le 120 ] && break
        echo "Enter a number from 0 to 120"
    done

    echo ""
    if [ "${CUR_DELETE:-0}" = "1" ]; then
        echo "Current: DELETE local after upload"
    else
        echo "Current: KEEP local after upload"
    fi
    echo "  1) Keep local backup files"
    echo "  2) Delete local backup files"
    read -p "Select (1-2) [current]: " DEL_CHOICE
    case $DEL_CHOICE in
        1) NEW_DELETE=0 ;;
        2) NEW_DELETE=1 ;;
        *) NEW_DELETE="${CUR_DELETE:-0}" ;;
    esac

    echo ""
    read -p "Remote folder path [${CUR_PATH:-shieldpress-backups}]: " NEW_PATH
    NEW_PATH="${NEW_PATH:-${CUR_PATH:-shieldpress-backups}}"

    sed -i "s/^REMOTE_RETENTION=.*/REMOTE_RETENTION=${NEW_RET}/" "$CONFIG_FILE"
    sed -i "s/^RCLONE_PATH=.*/RCLONE_PATH=${NEW_PATH}/" "$CONFIG_FILE"

    if grep -q "^DELETE_LOCAL_AFTER_UPLOAD=" "$CONFIG_FILE"; then
        sed -i "s/^DELETE_LOCAL_AFTER_UPLOAD=.*/DELETE_LOCAL_AFTER_UPLOAD=${NEW_DELETE}/" "$CONFIG_FILE"
    else
        echo "DELETE_LOCAL_AFTER_UPLOAD=${NEW_DELETE}" >> "$CONFIG_FILE"
    fi

    echo ""
    echo "[OK] Options updated"
    echo "  Retention : $NEW_RET"
    echo "  Local     : $([ "$NEW_DELETE" = "1" ] && echo "DELETE after upload" || echo "KEEP after upload")"
    echo "  Path      : $NEW_PATH"
    pause
}

# ==================================================
# SHOW REMOTE STORAGE INFO
# ==================================================
show_remote_info(){
    ensure_rclone || { pause; return; }
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Remote backup is not configured"
        pause; return
    fi

    local REMOTES PATH_VAL
    REMOTES=$(grep "^RCLONE_REMOTES=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    PATH_VAL=$(grep "^RCLONE_PATH=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's#^/##;s#/$##')

    echo ""
    while read -r REMOTE; do
        REMOTE="${REMOTE%:}"
        [ -z "$REMOTE" ] && continue
        echo "Remote: $REMOTE"
        echo "--------------------------------------------------"
        echo "Folders in ${REMOTE}:${PATH_VAL}/"
        rclone lsd "${REMOTE}:${PATH_VAL}/" 2>/dev/null | awk '{print "  " $NF}' || echo "  (empty or error)"
        echo ""

        local TOTAL_SIZE
        TOTAL_SIZE=$(rclone size "${REMOTE}:${PATH_VAL}/" 2>/dev/null | grep "Total size" || echo "  Could not calculate")
        echo "  $TOTAL_SIZE"
        echo ""
    done <<< "$(echo "$REMOTES" | tr ',' '\n')"

    pause
}

# ==================================================
# MAIN MENU
# ==================================================
while true; do
    clear
    echo "===================================================="
    echo "             REMOTE BACKUP SETTINGS"
    echo "===================================================="
    show_current
    echo "1) Configure S3 / Google Drive / OneDrive"
    echo "2) Edit Options (retention, delete local, path)"
    echo "3) Test Remote Upload"
    echo "4) View Remote Storage"
    echo "5) Disable Remote Backup"
    echo "0) Back"
    echo "--------------------------------------------------"
    read -p "Select: " opt

    case $opt in
        1) configure_remote ;;
        2) edit_options ;;
        3) test_remote ;;
        4) show_remote_info ;;
        5) disable_remote ;;
        0) break ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done
