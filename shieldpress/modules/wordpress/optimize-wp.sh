#!/bin/bash
source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $SYSTEM_USER $PHP_BIN /usr/local/bin/wp"

DB_NAME=$(grep "^DB_NAME=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

if [ ! -f "$ROOT/wp-config.php" ]; then
    echo "ERROR: WordPress not found at $ROOT"
    read -p "Press Enter..."; exit 1
fi

clear
echo "===================================================="
echo "       WORDPRESS OPTIMIZER - $SELECTED_DOMAIN"
echo "===================================================="
echo ""
echo "1) Quick Optimize (safe, fast)"
echo "2) Deep Optimize (thorough cleanup)"
echo "3) Database Repair + Optimize"
echo "4) Autoload Analyzer (show heavy autoload)"
echo "0) Cancel"
echo "----------------------------------------------------"
read -p "Select: " OPT

case $OPT in

# ================================================
# 1) QUICK OPTIMIZE
# ================================================
1)
    echo ""
    echo "Running Quick Optimize..."
    echo ""

    # Transients
    COUNT=$($WP_CMD transient delete --all --path="$ROOT" 2>/dev/null | grep -c "Success" || echo "0")
    echo "[OK] Expired transients deleted"

    # Object cache flush
    $WP_CMD cache flush --path="$ROOT" 2>/dev/null && echo "[OK] Object cache flushed"

    # Rewrite rules
    $WP_CMD rewrite flush --path="$ROOT" 2>/dev/null && echo "[OK] Rewrite rules flushed"

    # Optimize tables
    $WP_CMD db optimize --path="$ROOT" 2>/dev/null && echo "[OK] Database tables optimized"

    echo ""
    echo "[OK] Quick optimize complete!"
    ;;

# ================================================
# 2) DEEP OPTIMIZE
# ================================================
2)
    echo ""
    echo "Running Deep Optimize..."
    echo "This will clean: revisions, spam, trash, orphan data"
    echo ""
    read -p "Continue? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; read -p "Press Enter..."; exit 0; }

    echo ""

    # --- Transients ---
    $WP_CMD transient delete --all --path="$ROOT" 2>/dev/null
    echo "[OK] Transients deleted"

    # --- Post Revisions (giữ 5 revision mới nhất) ---
    REV_COUNT=$(mysql -N -e "SELECT COUNT(*) FROM ${DB_NAME}.wp_posts WHERE post_type='revision';" 2>/dev/null)
    if [ -n "$REV_COUNT" ] && [ "$REV_COUNT" -gt 0 ]; then
        # Xóa revision cũ hơn 30 ngày
        mysql -e "DELETE FROM ${DB_NAME}.wp_posts WHERE post_type='revision' AND post_date < DATE_SUB(NOW(), INTERVAL 30 DAY);" 2>/dev/null
        DELETED=$(mysql -N -e "SELECT ROW_COUNT();" 2>/dev/null)
        echo "[OK] Old revisions cleaned (was: $REV_COUNT, removed: ${DELETED:-0})"
    else
        echo "[INFO] No revisions to clean"
    fi

    # --- Spam Comments ---
    SPAM=$($WP_CMD comment list --status=spam --format=count --path="$ROOT" 2>/dev/null)
    if [ -n "$SPAM" ] && [ "$SPAM" -gt 0 ]; then
        $WP_CMD comment delete $($WP_CMD comment list --status=spam --format=ids --path="$ROOT" 2>/dev/null) --force --path="$ROOT" 2>/dev/null
        echo "[OK] Spam comments deleted ($SPAM)"
    else
        echo "[INFO] No spam comments"
    fi

    # --- Trash Comments ---
    TRASH=$($WP_CMD comment list --status=trash --format=count --path="$ROOT" 2>/dev/null)
    if [ -n "$TRASH" ] && [ "$TRASH" -gt 0 ]; then
        $WP_CMD comment delete $($WP_CMD comment list --status=trash --format=ids --path="$ROOT" 2>/dev/null) --force --path="$ROOT" 2>/dev/null
        echo "[OK] Trash comments deleted ($TRASH)"
    else
        echo "[INFO] No trash comments"
    fi

    # --- Trashed Posts ---
    TRASH_POSTS=$($WP_CMD post list --post_status=trash --format=count --path="$ROOT" 2>/dev/null)
    if [ -n "$TRASH_POSTS" ] && [ "$TRASH_POSTS" -gt 0 ]; then
        $WP_CMD post delete $($WP_CMD post list --post_status=trash --format=ids --path="$ROOT" 2>/dev/null) --force --path="$ROOT" 2>/dev/null
        echo "[OK] Trashed posts deleted ($TRASH_POSTS)"
    else
        echo "[INFO] No trashed posts"
    fi

    # --- Orphaned Post Meta ---
    ORPHAN_META=$(mysql -N -e "SELECT COUNT(*) FROM ${DB_NAME}.wp_postmeta WHERE post_id NOT IN (SELECT ID FROM ${DB_NAME}.wp_posts);" 2>/dev/null)
    if [ -n "$ORPHAN_META" ] && [ "$ORPHAN_META" -gt 0 ]; then
        mysql -e "DELETE FROM ${DB_NAME}.wp_postmeta WHERE post_id NOT IN (SELECT ID FROM ${DB_NAME}.wp_posts);" 2>/dev/null
        echo "[OK] Orphaned post meta deleted ($ORPHAN_META rows)"
    else
        echo "[INFO] No orphaned post meta"
    fi

    # --- Orphaned Comment Meta ---
    ORPHAN_CM=$(mysql -N -e "SELECT COUNT(*) FROM ${DB_NAME}.wp_commentmeta WHERE comment_id NOT IN (SELECT comment_ID FROM ${DB_NAME}.wp_comments);" 2>/dev/null)
    if [ -n "$ORPHAN_CM" ] && [ "$ORPHAN_CM" -gt 0 ]; then
        mysql -e "DELETE FROM ${DB_NAME}.wp_commentmeta WHERE comment_id NOT IN (SELECT comment_ID FROM ${DB_NAME}.wp_comments);" 2>/dev/null
        echo "[OK] Orphaned comment meta deleted ($ORPHAN_CM rows)"
    else
        echo "[INFO] No orphaned comment meta"
    fi

    # --- Expired Transients in DB ---
    EXPIRED_T=$(mysql -N -e "SELECT COUNT(*) FROM ${DB_NAME}.wp_options WHERE option_name LIKE '_transient_timeout_%' AND option_value < UNIX_TIMESTAMP();" 2>/dev/null)
    if [ -n "$EXPIRED_T" ] && [ "$EXPIRED_T" -gt 0 ]; then
        mysql -e "DELETE a, b FROM ${DB_NAME}.wp_options a
            INNER JOIN ${DB_NAME}.wp_options b ON b.option_name = REPLACE(a.option_name, '_transient_timeout_', '_transient_')
            WHERE a.option_name LIKE '_transient_timeout_%' AND a.option_value < UNIX_TIMESTAMP();" 2>/dev/null
        echo "[OK] Expired DB transients cleaned ($EXPIRED_T)"
    fi

    # --- Optimize DB ---
    $WP_CMD db optimize --path="$ROOT" 2>/dev/null && echo "[OK] Database optimized"

    # --- Flush caches ---
    $WP_CMD cache flush --path="$ROOT" 2>/dev/null
    $WP_CMD rewrite flush --path="$ROOT" 2>/dev/null

    # --- DB size after ---
    DB_SIZE=$(mysql -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.TABLES WHERE table_schema='${DB_NAME}';" 2>/dev/null)

    echo ""
    echo "===================================================="
    echo "Deep optimize complete!"
    echo "Database size: ${DB_SIZE:-unknown}MB"
    echo "===================================================="
    ;;

# ================================================
# 3) DATABASE REPAIR + OPTIMIZE
# ================================================
3)
    echo ""
    echo "Repairing and optimizing all tables..."
    $WP_CMD db repair --path="$ROOT" 2>/dev/null && echo "[OK] Database repaired"
    $WP_CMD db optimize --path="$ROOT" 2>/dev/null && echo "[OK] Database optimized"

    # Show table sizes
    echo ""
    echo "Top 10 largest tables:"
    mysql -e "SELECT table_name,
        ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb
        FROM information_schema.TABLES
        WHERE table_schema = '${DB_NAME}'
        ORDER BY (data_length + index_length) DESC LIMIT 10;" 2>/dev/null
    ;;

# ================================================
# 4) AUTOLOAD ANALYZER
# ================================================
4)
    echo ""
    echo "===================================================="
    echo "  AUTOLOAD ANALYZER - $SELECTED_DOMAIN"
    echo "===================================================="
    echo ""

    # Tổng autoload size
    TOTAL_AUTOLOAD=$(mysql -N -e "SELECT ROUND(SUM(LENGTH(option_value))/1024/1024, 2) FROM ${DB_NAME}.wp_options WHERE autoload='yes';" 2>/dev/null)
    TOTAL_ROWS=$(mysql -N -e "SELECT COUNT(*) FROM ${DB_NAME}.wp_options WHERE autoload='yes';" 2>/dev/null)

    echo "Total autoload size : ${TOTAL_AUTOLOAD:-0}MB"
    echo "Total autoload rows : ${TOTAL_ROWS:-0}"
    echo ""

    if [ -n "$TOTAL_AUTOLOAD" ]; then
        # Cảnh báo nếu autoload quá lớn
        AUTOLOAD_INT=$(echo "$TOTAL_AUTOLOAD" | cut -d'.' -f1)
        if [ "$AUTOLOAD_INT" -gt 2 ]; then
            echo "[WARN] Autoload > 2MB! This slows down EVERY page load."
            echo ""
        fi
    fi

    echo "Top 20 heaviest autoload entries:"
    echo "----------------------------------------------------"
    mysql -e "SELECT option_name,
        ROUND(LENGTH(option_value)/1024, 2) AS size_kb
        FROM ${DB_NAME}.wp_options
        WHERE autoload='yes'
        ORDER BY LENGTH(option_value) DESC LIMIT 20;" 2>/dev/null

    echo ""
    echo "Tip: Disable autoload for heavy entries:"
    echo "  UPDATE wp_options SET autoload='no' WHERE option_name='<name>';"
    ;;

0)
    exit 0
    ;;
*)
    echo "Invalid option"
    ;;
esac

echo ""
read -p "Press Enter..."
