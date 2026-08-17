#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

# Đọc thẳng từ domain.env
ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $SYSTEM_USER $PHP_BIN /usr/local/bin/wp"

CRON_SCRIPT="$DOMAIN_PATH/config/wp-cron.sh"

# ------------------------------------------------
# HELPERS
# ------------------------------------------------

ok()  { echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }
fail(){ echo "[FAIL] $1"; }

is_wpcron_disabled(){
    grep -q "DISABLE_WP_CRON.*true" "$ROOT/wp-config.php" 2>/dev/null
}

is_syscron_active(){
    crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"
}

show_status(){
    echo ""
    echo "===================================================="
    echo "  WP-CRON STATUS - $SELECTED_DOMAIN"
    echo "===================================================="

    if is_wpcron_disabled; then
        echo "  WP-Cron (built-in) : DISABLED"
    else
        echo "  WP-Cron (built-in) : ENABLED (runs on every request)"
    fi

    if is_syscron_active; then
        CRON_LINE=$(crontab -l 2>/dev/null | grep "$CRON_SCRIPT")
        echo "  System Cron        : ACTIVE"
        echo "  Schedule           : $CRON_LINE"
    else
        echo "  System Cron        : NOT SET"
    fi

    echo "===================================================="
    echo ""
}

# ------------------------------------------------
# ENABLE SYSTEM CRON
# ------------------------------------------------

enable_system_cron(){

    if [ ! -f "$ROOT/wp-config.php" ]; then
        fail "WordPress not found at $ROOT"
        return 1
    fi

    echo ""
    echo "Select cron interval:"
    echo "1) Every 5 minutes  (recommended for most sites)"
    echo "2) Every 10 minutes"
    echo "3) Every 15 minutes"
    echo "4) Every 30 minutes (low-traffic sites)"
    echo "5) Every 1 hour"
    read -p "Choose: " INTERVAL

    case $INTERVAL in
        1) CRON_TIME="*/5 * * * *"  ;;
        2) CRON_TIME="*/10 * * * *" ;;
        3) CRON_TIME="*/15 * * * *" ;;
        4) CRON_TIME="*/30 * * * *" ;;
        5) CRON_TIME="0 * * * *"    ;;
        *) fail "Invalid option"; return 1 ;;
    esac

    # Tắt WP-Cron built-in
    if ! is_wpcron_disabled; then
        if grep -q "DISABLE_WP_CRON" "$ROOT/wp-config.php"; then
            sed -i "s/define.*DISABLE_WP_CRON.*/define('DISABLE_WP_CRON', true);/" "$ROOT/wp-config.php"
        else
            sed -i "/That's all, stop editing/i define('DISABLE_WP_CRON', true);" "$ROOT/wp-config.php"
        fi
        ok "WP-Cron built-in disabled in wp-config.php"
    fi

    # Tạo cron script
    cat > "$CRON_SCRIPT" << SCRIPT
#!/bin/bash
# WP-Cron system script for $SELECTED_DOMAIN
# Created by ShieldPress

$PHP_BIN "$ROOT/wp-cron.php" >/dev/null 2>&1
SCRIPT

    chmod +x "$CRON_SCRIPT"

    # Xóa cron cũ nếu có, thêm mới
    crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab -
    (crontab -l 2>/dev/null; echo "$CRON_TIME $CRON_SCRIPT") | crontab -

    ok "System cron added: $CRON_TIME"
    ok "WP-Cron system enabled for $SELECTED_DOMAIN"
}

# ------------------------------------------------
# DISABLE SYSTEM CRON
# ------------------------------------------------

disable_system_cron(){

    # Xóa khỏi crontab
    if is_syscron_active; then
        crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab -
        ok "System cron removed"
    else
        warn "No system cron found for this domain"
    fi

    # Xóa script
    rm -f "$CRON_SCRIPT"

    # Bật lại WP-Cron built-in
    if is_wpcron_disabled; then
        sed -i "s/define.*DISABLE_WP_CRON.*/define('DISABLE_WP_CRON', false);/" "$ROOT/wp-config.php"
        ok "WP-Cron built-in re-enabled"
    fi

    ok "Reverted to built-in WP-Cron"
}

# ------------------------------------------------
# RUN CRON NOW (manual trigger)
# ------------------------------------------------

run_cron_now(){
    if [ ! -f "$ROOT/wp-cron.php" ]; then
        fail "wp-cron.php not found"
        return 1
    fi
    echo "Running WP-Cron now..."
    "$PHP_BIN" "$ROOT/wp-cron.php" 2>&1
    ok "WP-Cron executed"
}

# ------------------------------------------------
# LIST SCHEDULED EVENTS
# ------------------------------------------------

list_events(){
    if [ ! -x "$PHP_BIN" ] || [ ! -f "$ROOT/wp-config.php" ]; then
        fail "WordPress or PHP not available"
        return 1
    fi
    echo ""
    echo "Scheduled WP-Cron events:"
    echo "----------------------------------------------------"
    $WP_CMD cron event list --path="$ROOT" 2>/dev/null || \
        warn "WP-CLI not available"
}

# ------------------------------------------------
# MENU
# ------------------------------------------------

while true; do
    clear
    show_status

    echo "===================================================="
    echo "   WP-CRON MANAGER - $SELECTED_DOMAIN"
    echo "===================================================="
    echo "1) Enable System Cron (Recommended)"
    echo "2) Disable System Cron (Back to WP-Cron)"
    echo "3) Run Cron Now (Manual trigger)"
    echo "4) List Scheduled Events"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " CHOICE

    case $CHOICE in
        1) enable_system_cron  ;;
        2) disable_system_cron ;;
        3) run_cron_now        ;;
        4) list_events         ;;
        0) break ;;
        *) warn "Invalid option"; sleep 1; continue ;;
    esac

    echo ""
    read -p "Press Enter..."
done
