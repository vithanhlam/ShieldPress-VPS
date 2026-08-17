#!/bin/bash

DOMAINS_ROOT="/home/domains"

# ===== SELECT DOMAIN =====
select_domain(){
    echo ""
    echo "Available Domains:"
    echo "--------------------------------"

    i=1
    unset DOMAIN_LIST

    for d in $DOMAINS_ROOT/*; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        DOMAIN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        echo "$i) $DOMAIN"
        DOMAIN_LIST[$i]=$(basename "$d")
        ((i++))
    done

    echo "--------------------------------"
    read -p "Select domain: " choice

    DOMAIN_FOLDER="${DOMAIN_LIST[$choice]}"
    [ -z "$DOMAIN_FOLDER" ] && { echo "Invalid"; return 1; }

    DOMAIN_PATH="$DOMAINS_ROOT/$DOMAIN_FOLDER"
    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    WP_CONFIG="$DOMAIN_PATH/public_html/wp-config.php"

    if [ ! -f "$WP_CONFIG" ]; then
        echo "wp-config.php not found"
        return 1
    fi

    SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    [ -z "$SYSTEM_USER" ] && { echo "[FAIL] SYSTEM_USER not found"; return 1; }

    return 0
}

# ===== CHECK STATUS =====
is_enabled(){
    grep -q "ShieldPress Security & Optimize" "$WP_CONFIG"
}

# ===== APPLY SECURITY =====
apply_security(){

    echo ""
    echo "Applying WordPress Security & Optimize..."
    echo ""

    [ ! -f "$WP_CONFIG" ] && { echo "[FAIL] wp-config.php not found"; return 1; }

    # ===== CHECK IF ALREADY ENABLED =====
    if is_enabled; then
        echo "[INFO] Already enabled → skip"
        return
    fi

    # ===== BACKUP =====
    cp "$WP_CONFIG" "${WP_CONFIG}.bak"
    chown "$SYSTEM_USER:$SYSTEM_USER" "${WP_CONFIG}.bak"
    chmod 640 "${WP_CONFIG}.bak"

    # ===== CLEAN OLD =====
    sed -i "/define\s*(\s*'AUTOMATIC_UPDATER_DISABLED'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'WP_AUTO_UPDATE_CORE'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'DISALLOW_FILE_MODS'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'DISALLOW_FILE_EDIT'/d" "$WP_CONFIG"
    sed -i "/ShieldPress Security & Optimize/d" "$WP_CONFIG"

    # ===== INSERT =====
    if grep -q "That's all, stop editing" "$WP_CONFIG"; then

        awk '
        /That.s all, stop editing/ {
            print "\n/**";
            print " * ShieldPress Security & Optimize";
            print " */";
            print "define('\''AUTOMATIC_UPDATER_DISABLED'\'', true);";
            print "define('\''WP_AUTO_UPDATE_CORE'\'', false);";
            print "define('\''DISALLOW_FILE_MODS'\'', true);";
            print "define('\''DISALLOW_FILE_EDIT'\'', true);\n";
        }
        { print }
        ' "$WP_CONFIG" > "${WP_CONFIG}.tmp" && mv "${WP_CONFIG}.tmp" "$WP_CONFIG"

    else
        echo "[WARN] Marker not found → append"

        cat >> "$WP_CONFIG" <<EOF

/**
 * ShieldPress Security & Optimize
 */
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
define('DISALLOW_FILE_MODS', true);
define('DISALLOW_FILE_EDIT', true);

EOF
    fi

    # ===== FIX PERMISSION =====
    chown "$SYSTEM_USER:$SYSTEM_USER" "$WP_CONFIG"
    chmod 640 "$WP_CONFIG"

    echo "[OK] Applied successfully"
}

# ===== REMOVE SECURITY =====
remove_security(){

    echo ""
    echo "Removing WordPress Security & Optimize..."
    echo ""

    [ ! -f "$WP_CONFIG" ] && { echo "[FAIL] wp-config.php not found"; return 1; }

    # ===== CHECK IF NOT ENABLED =====
    if ! is_enabled; then
        echo "[INFO] Not enabled → skip"
        return
    fi

    # ===== BACKUP =====
    cp "$WP_CONFIG" "${WP_CONFIG}.bak"
    chown "$SYSTEM_USER:$SYSTEM_USER" "${WP_CONFIG}.bak"
    chmod 640 "${WP_CONFIG}.bak"

    # ===== REMOVE =====
    sed -i "/define\s*(\s*'AUTOMATIC_UPDATER_DISABLED'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'WP_AUTO_UPDATE_CORE'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'DISALLOW_FILE_MODS'/d" "$WP_CONFIG"
    sed -i "/define\s*(\s*'DISALLOW_FILE_EDIT'/d" "$WP_CONFIG"
    sed -i "/ShieldPress Security & Optimize/d" "$WP_CONFIG"

    chown "$SYSTEM_USER:$SYSTEM_USER" "$WP_CONFIG"
    chmod 640 "$WP_CONFIG"

    echo "[OK] Removed successfully"
}

# ===== MENU =====
while true; do

clear
echo "===================================================="
echo "      SECURITY & OPTIMIZE WORDPRESS"
echo " Disable file editor, disable auto updates"
echo "===================================================="
echo " 1) Enable Security & Optimize"
echo " 2) Disable (Restore default)"
echo " 0) Back"
echo "----------------------------------------------------"

read -p "Select: " opt

case $opt in
    1)
        select_domain || continue
        apply_security
        read -p "Press Enter..."
        ;;
    2)
        select_domain || continue
        remove_security
        read -p "Press Enter..."
        ;;
    0) break ;;
    *) echo "Invalid"; sleep 1 ;;
esac

done