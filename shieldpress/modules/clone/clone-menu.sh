#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/clone.log"
LOCK_FILE="/tmp/shieldpress_clone.lock"

source "$BASE_DIR/modules/domain/helpers.sh"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"; }
ok(){   log "[OK] $1"; }
fail(){ log "[FAIL] $1"; }

# Lock uses mkdir for atomicity
LOCKED=0

lock(){
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        echo "[ERROR] Another clone task is running!"
        echo "If this is wrong, delete: $LOCK_FILE"
        return 1
    fi
    LOCKED=1
}

# Only unlock if we actually acquired the lock.
# CHỈ trap EXIT - bash tự động chạy trap EXIT ngay cả khi tiến trình bị kết
# thúc bởi tín hiệu INT/TERM chưa bắt (đây là hành vi chuẩn), nên không cần
# trap thêm INT/TERM. Nếu trap CẢ INT/TERM mà handler không tự gọi `exit`,
# script sẽ "nuốt" tín hiệu và chạy tiếp thay vì dừng lại - khiến Ctrl+C và
# `timeout`/`kill -TERM` không còn tác dụng dừng script (đã tái hiện thật:
# script rơi vào vòng lặp menu vô hạn "Invalid option" mà timeout không dừng
# được, phải kill -9 mới thoát).
trap '[ "$LOCKED" -eq 1 ] && unlock' EXIT

unlock(){ rm -rf "$LOCK_FILE"; LOCKED=0; }

# ================================
# ĐỌC DOMAIN ENV - có trim space
# ================================

read_domain_env(){
    local PATH_=$1
    local ENV="$PATH_/config/domain.env"

    _DB=$(grep      "^DB_NAME="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _DB_USER=$(grep "^DB_USER="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _DB_PASS=$(grep "^DB_PASS="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _ROOT=$(grep    "^ROOT="        "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _SSL=$(grep     "^SSL="         "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _PHP=$(grep     "^PHP_VERSION=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    _SYSUSER=$(grep "^SYSTEM_USER=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
}

# ================================
# VERIFY WORDPRESS DB
# ================================

verify_wp_db(){
    local DB=$1 DOMAIN=$2

    PREFIX=$(mysql -N -e "
        SELECT table_name FROM information_schema.tables
        WHERE table_schema='$DB' AND table_name LIKE '%_options'
        LIMIT 1;" 2>/dev/null | sed 's/_options//')

    [ -z "$PREFIX" ] && return 1

    SITEURL=$(mysql -N -e "
        SELECT option_value FROM \`${DB}\`.\`${PREFIX}_options\`
        WHERE option_name='siteurl';" 2>/dev/null)

    [[ "$SITEURL" == *"$DOMAIN"* ]]
}

# ================================
# UPDATE WP-CONFIG
# ================================

update_wp_config(){
    local CONF="$TARGET_ROOT/wp-config.php"
    [ -f "$CONF" ] || { fail "wp-config.php not found"; return 1; }

    sed -i "s/define( *'DB_NAME'.*/define( 'DB_NAME', '$TARGET_DB' );/"       "$CONF"
    sed -i "s/define( *'DB_USER'.*/define( 'DB_USER', '$TARGET_DB_USER' );/"   "$CONF"
    sed -i "s/define( *'DB_PASSWORD'.*/define( 'DB_PASSWORD', '$TARGET_DB_PASS' );/" "$CONF"
    ok "wp-config.php updated"
}

# ================================
# FIX PERMISSIONS
# ================================

fix_permissions(){
    [ -z "$TARGET_SYS_USER" ] && { fail "SYSTEM_USER not found"; return 1; }

    chown -R "$TARGET_SYS_USER:$TARGET_SYS_USER" "$TARGET_ROOT"
    find "$TARGET_ROOT" -type d \
        -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
        -exec chmod 755 {} \;
    find "$TARGET_ROOT" -type f \
        -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
        -exec chmod 644 {} \;
    [ -f "$TARGET_ROOT/wp-config.php" ] && chmod 600 "$TARGET_ROOT/wp-config.php"
    ok "Permissions fixed"
}

# ================================
# ROLLBACK TARGET
# ================================

rollback_target(){
    log "ROLLBACK INITIATED"
    rm -rf "${TARGET_ROOT:?}"/*

    mysql -N -e "SHOW TABLES FROM \`$TARGET_DB\`;" 2>/dev/null | \
        xargs -I{} mysql -e "DROP TABLE \`$TARGET_DB\`.\`{}\`;" 2>/dev/null

    if [ -n "$TARGET_ROLLBACK_DIR" ] && [ -d "$TARGET_ROLLBACK_DIR" ]; then
        # Đích vốn có dữ liệu trước khi clone - phải phục hồi ĐÚNG bản gốc của
        # đích (không phải snapshot nguồn) nếu không sẽ mất trắng dữ liệu
        # người dùng, không thể khôi phục.
        RESTORE_OK=1
        rsync -a --delete "$TARGET_ROLLBACK_DIR/files/" "$TARGET_ROOT/" 2>/dev/null || RESTORE_OK=0
        if [ -f "$TARGET_ROLLBACK_DIR/database.sql" ]; then
            mysql "$TARGET_DB" < "$TARGET_ROLLBACK_DIR/database.sql" 2>/dev/null || RESTORE_OK=0
        fi
        [ -n "$TARGET_SYS_USER" ] && chown -R "$TARGET_SYS_USER:$TARGET_SYS_USER" "$TARGET_ROOT"

        if [ "$RESTORE_OK" -eq 1 ]; then
            log "Target files+DB restored from pre-clone backup"
            rm -rf "$TARGET_ROLLBACK_DIR"
        else
            fail "Target restore FAILED - ban goc van con nguyen tai $TARGET_ROLLBACK_DIR, can khoi phuc thu cong"
        fi
    fi
    log "ROLLBACK COMPLETED"
}

# ================================
# VERIFY CLONE
# ================================

verify_clone(){
    SRC_COUNT=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$SRC_DB';" 2>/dev/null)
    TGT_COUNT=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TARGET_DB';" 2>/dev/null)

    if [ "$SRC_COUNT" -ne "$TGT_COUNT" ]; then
        fail "Table count mismatch: source=$SRC_COUNT target=$TGT_COUNT"
        return 1
    fi
    ok "Table count verified ($TGT_COUNT tables)"
}

# ================================
# MAIN CLONE
# ================================

clone_site(){
    lock || return 1

    # --- SELECT SOURCE ---
    echo ""
    echo "========== SELECT SOURCE DOMAIN =========="
    select_domain || { unlock; return 1; }
    SRC_DOMAIN="$SELECTED_DOMAIN"
    SRC_PATH="$DOMAIN_PATH"

    read_domain_env "$SRC_PATH"
    SRC_DB="$_DB"; SRC_DB_USER="$_DB_USER"; SRC_DB_PASS="$_DB_PASS"
    SRC_ROOT="$_ROOT"; SRC_SSL="$_SSL"; SRC_PHP="$_PHP"

    # Reset state - tránh dùng nhầm giá trị của lượt clone trước trong cùng phiên
    TARGET_ROLLBACK_DIR=""

    # Verify WordPress
    if ! verify_wp_db "$SRC_DB" "$SRC_DOMAIN"; then
        fail "Source DB does not match domain or is not WordPress"
        unlock; return 1
    fi

    # --- SELECT TARGET ---
    echo ""
    echo "========== SELECT TARGET DOMAIN =========="
    select_domain || { unlock; return 1; }
    TARGET_DOMAIN="$SELECTED_DOMAIN"
    TARGET_PATH="$DOMAIN_PATH"

    read_domain_env "$TARGET_PATH"
    TARGET_DB="$_DB"; TARGET_DB_USER="$_DB_USER"; TARGET_DB_PASS="$_DB_PASS"
    TARGET_ROOT="$_ROOT"; TARGET_SSL="$_SSL"; TARGET_PHP="$_PHP"
    TARGET_SYS_USER="$_SYSUSER"

    if [ "$SRC_DOMAIN" = "$TARGET_DOMAIN" ]; then
        fail "Source and Target cannot be the same domain"
        unlock; return 1
    fi

    # --- SUMMARY ---
    echo ""
    sp_header "Clone Manager" "Website to website cloning"
    echo "  CLONE SUMMARY"
    echo "===================================================="
    echo "  SOURCE : $SRC_DOMAIN"
    echo "         : DB=$SRC_DB | PHP=$SRC_PHP | SSL=$SRC_SSL"
    echo ""
    echo "  TARGET : $TARGET_DOMAIN"
    echo "         : DB=$TARGET_DB | PHP=$TARGET_PHP | SSL=$TARGET_SSL"
    echo "===================================================="
    echo ""
    read -p "Start cloning? (y/n): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; unlock; return 1; }

    # --- BACKUP SOURCE (optional) ---
    read -p "Backup source before clone? [Y/n]: " DO_BACKUP
    DO_BACKUP="${DO_BACKUP:-y}"
    if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
        BDIR="$SRC_PATH/backup/full/clone_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BDIR"
        echo "Backing up source files..."
        rsync -a "$SRC_ROOT/" "$BDIR/files/"
        echo "Backing up source DB..."
        mysqldump --single-transaction --quick "$SRC_DB" > "$BDIR/database.sql"
        ok "Source backup: $BDIR"
    fi

    # --- CLEAR TARGET IF NOT EMPTY ---
    FILE_COUNT=$(find "$TARGET_ROOT" -mindepth 1 2>/dev/null | wc -l)
    TABLE_COUNT=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TARGET_DB';" 2>/dev/null)

    if [ "$FILE_COUNT" -gt 0 ] || [ "$TABLE_COUNT" -gt 0 ]; then
        echo ""
        echo -e "\e[31mWARNING: Target is NOT empty: $FILE_COUNT files, $TABLE_COUNT tables. All will be deleted!\e[0m"
        read -p "Wipe target and continue? (y/n): " CONFIRM2
        [[ ! "$CONFIRM2" =~ ^[Yy]$ ]] && { echo "Cancelled."; unlock; return 1; }

        # Backup dữ liệu GỐC của domain đích trước khi wipe. Nếu clone thất
        # bại giữa chừng, rollback_target() cần phục hồi ĐÚNG dữ liệu này -
        # không có bước này thì domain đích mất trắng không thể khôi phục.
        TARGET_ROLLBACK_DIR="/home/domains/.clone-rollback-${TARGET_DOMAIN}-$(date +%s)"
        mkdir -p "$TARGET_ROLLBACK_DIR/files"
        echo "Backing up target before wipe (rollback safety)..."
        rsync -a "$TARGET_ROOT/" "$TARGET_ROLLBACK_DIR/files/" 2>/dev/null
        if [ "$TABLE_COUNT" -gt 0 ]; then
            mysqldump --single-transaction --quick --routines --triggers \
                "$TARGET_DB" > "$TARGET_ROLLBACK_DIR/database.sql" 2>/dev/null
        fi
        ok "Target rollback backup: $TARGET_ROLLBACK_DIR"

        rm -rf "${TARGET_ROOT:?}"/*
        mysql -N -e "SHOW TABLES FROM \`$TARGET_DB\`;" 2>/dev/null | \
            xargs -I{} mysql -e "DROP TABLE \`$TARGET_DB\`.\`{}\`;" 2>/dev/null
        ok "Target cleared"
    fi

    # --- SNAPSHOT SOURCE DB ---
    # QUAN TRỌNG: bước này chạy SAU khi target đã bị wipe ở trên - nếu fail ở
    # đây mà không rollback_target(), domain đích bị bỏ trống vĩnh viễn dù
    # bản backup gốc (TARGET_ROLLBACK_DIR) vẫn nằm sẵn đó không được dùng tới.
    SNAPSHOT_FILE="/tmp/${SRC_DB}_snap_$(date +%s).sql"
    echo "Creating DB snapshot..."
    mysqldump --single-transaction --quick --routines --triggers \
        "$SRC_DB" > "$SNAPSHOT_FILE" || { fail "DB snapshot failed"; rollback_target; unlock; return 1; }
    ok "Snapshot: $SNAPSHOT_FILE"

    # --- CLONE FILES ---
    echo "Cloning files..."
    rsync -a --delete --numeric-ids "$SRC_ROOT/" "$TARGET_ROOT/" || {
        fail "File clone failed"; rollback_target; unlock; return 1
    }
    ok "Files cloned"

    # --- UPDATE WP-CONFIG ---
    update_wp_config || { rollback_target; unlock; return 1; }

    # --- FIX PERMISSIONS ---
    fix_permissions

    # --- IMPORT DB ---
    echo "Importing database..."
    mysql "$TARGET_DB" < "$SNAPSHOT_FILE" || {
        fail "DB import failed"; rollback_target; unlock; return 1
    }
    ok "Database imported"

    # --- UPDATE SITEURL/HOME ---
    # Lấy OLD_URL từ DB thực tế của source (đúng hơn hardcode http/https)
    PREFIX=$(mysql -N -e "
        SELECT table_name FROM information_schema.tables
        WHERE table_schema='$TARGET_DB' AND table_name LIKE '%_options'
        LIMIT 1;" 2>/dev/null | sed 's/_options//')

    OLD_URL=$(mysql -N -e "
        SELECT option_value FROM \`${TARGET_DB}\`.\`${PREFIX}_options\`
        WHERE option_name='siteurl';" 2>/dev/null)

    [ "$TARGET_SSL" = "enabled" ] && PROTOCOL="https" || PROTOCOL="http"
    NEW_URL="${PROTOCOL}://${TARGET_DOMAIN}"

    mysql -e "
        UPDATE \`${TARGET_DB}\`.\`${PREFIX}_options\`
        SET option_value='$NEW_URL'
        WHERE option_name IN ('siteurl','home');" 2>/dev/null
    ok "siteurl/home updated: $OLD_URL → $NEW_URL"

    # Search-replace nếu có WP-CLI
    TARGET_PHP_BIN="/opt/remi/php${TARGET_PHP//./}/root/usr/bin/php"
    if [ -x "$TARGET_PHP_BIN" ] && command -v wp >/dev/null 2>&1; then
        echo "Running search-replace..."
        sudo -u "$TARGET_SYS_USER" "$TARGET_PHP_BIN" /usr/local/bin/wp \
            search-replace "$OLD_URL" "$NEW_URL" \
            --skip-columns=guid \
            --all-tables \
            --path="$TARGET_ROOT" 2>/dev/null && ok "Search-replace completed"
    fi

    # --- VERIFY ---
    verify_clone || { rollback_target; unlock; return 1; }

    # --- FLUSH CACHE ---
    # Chỉ xoá cache của domain đích (prefix "domain:" - cùng quy ước với
    # WP_REDIS_PREFIX ở cache/wp-valkey.sh) - KHÔNG FLUSHALL vì sẽ xoá sạch
    # cache của mọi domain khác đang dùng chung Valkey instance.
    if command -v valkey-cli >/dev/null 2>&1 && valkey-cli ping >/dev/null 2>&1; then
        valkey-cli --scan --pattern "${TARGET_DOMAIN}:*" 2>/dev/null | \
            xargs -r valkey-cli del >/dev/null 2>&1
    fi
    rm -f "$SNAPSHOT_FILE"

    # Clone thành công - không cần bản backup rollback của đích nữa
    [ -n "$TARGET_ROLLBACK_DIR" ] && rm -rf "$TARGET_ROLLBACK_DIR"

    unlock

    echo ""
    echo "===================================================="
    echo " [OK] CLONE COMPLETED SUCCESSFULLY"
    echo "===================================================="
    echo "  Source : $SRC_DOMAIN"
    echo "  Target : $TARGET_DOMAIN"
    echo "  URL    : $NEW_URL"
    echo "===================================================="
    ok "Clone $SRC_DOMAIN → $TARGET_DOMAIN completed"
}

# ================================
# MENU
# ================================

while true; do
    clear
    sp_header "Clone Manager" "Website to website cloning"
    sp_menu_grid \
        "1|Clone Website to Website|magenta" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) clone_site; echo ""; read -p "Press Enter..." ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
