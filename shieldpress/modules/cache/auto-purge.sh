#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh

TEMPLATE="/opt/shieldpress/templates/wp-mu-plugins/shieldpress-cache-purge.php"
PLUGIN_NAME="shieldpress-cache-purge.php"
PURGE_SCRIPT="/opt/shieldpress/bin/purge-fastcgi-cache"
SIGNAL_SCRIPT="/opt/shieldpress/bin/process-purge-signals"
SUDOERS_FILE="/etc/sudoers.d/shieldpress-cache-purge"
CRON_FILE="/etc/cron.d/shieldpress-cache-purge"

setup_purge_system() {
    # 1. Sudoers (for exec method, if exec is enabled)
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo "ALL ALL=(root) NOPASSWD: $PURGE_SCRIPT" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        echo "[OK] Sudoers rule created"
    fi

    # 2. Purge scripts permissions
    for script in "$PURGE_SCRIPT" "$SIGNAL_SCRIPT"; do
        if [ -f "$script" ]; then
            chmod 755 "$script"
            chown root:root "$script"
        fi
    done

    # 3. Cron job to process signal files every minute
    # PHP writes to /home/domains/*/tmp/.purge-cache (bypasses PrivateTmp)
    cat > "$CRON_FILE" <<EOF
# ShieldPress: process cache purge signals from PHP
* * * * * root $SIGNAL_SCRIPT >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "[OK] Purge signal cron installed"
}

deploy_mu_plugin() {
    local domain_path="$1"
    local system_user="$2"
    local root="$domain_path/public_html"
    local mu_dir="$root/wp-content/mu-plugins"

    if [ ! -f "$root/wp-config.php" ]; then
        echo "[SKIP] Not a WordPress site: $root"
        return 1
    fi

    if [ ! -f "$TEMPLATE" ]; then
        echo "[FAIL] Template not found: $TEMPLATE"
        return 1
    fi

    setup_purge_system

    mkdir -p "$mu_dir"
    cp "$TEMPLATE" "$mu_dir/$PLUGIN_NAME"
    chown "$system_user:$system_user" "$mu_dir/$PLUGIN_NAME"
    chmod 644 "$mu_dir/$PLUGIN_NAME"

    echo "[OK] Auto Purge deployed: $mu_dir/$PLUGIN_NAME"
    return 0
}

remove_mu_plugin() {
    local domain_path="$1"
    local root="$domain_path/public_html"
    local mu_file="$root/wp-content/mu-plugins/$PLUGIN_NAME"

    if [ -f "$mu_file" ]; then
        rm -f "$mu_file"
        echo "[OK] Auto Purge removed: $mu_file"
    else
        echo "[INFO] Auto Purge not installed for this domain"
    fi
}

check_status() {
    local domain_path="$1"
    local root="$domain_path/public_html"
    local mu_file="$root/wp-content/mu-plugins/$PLUGIN_NAME"

    if [ -f "$mu_file" ]; then
        echo "ENABLED"
    else
        echo "DISABLED"
    fi
}

deploy_all() {
    local env domain domain_path system_user count=0

    setup_purge_system

    for env in /home/domains/*/config/domain.env; do
        [ -f "$env" ] || continue
        domain=$(grep "^DOMAIN=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        domain_path=$(dirname "$(dirname "$env")")
        system_user=$(grep "^SYSTEM_USER=" "$env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$system_user" ] && system_user=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/_/g')

        echo "--- $domain ---"
        if deploy_mu_plugin "$domain_path" "$system_user"; then
            count=$((count + 1))
        fi
    done

    echo ""
    echo "[OK] Deployed to $count domain(s)"
}

# ============================================================
# MAIN MENU
# ============================================================

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
[ -z "$SYSTEM_USER" ] && SYSTEM_USER="$CLEAN_DOMAIN"

STATUS=$(check_status "$DOMAIN_PATH")

while true; do
    clear
    echo "===================================================="
    echo "       AUTO PURGE CACHE - $SELECTED_DOMAIN"
    echo "===================================================="
    echo ""
    echo "Status: $STATUS"
    echo ""
    echo "When enabled, Nginx FastCGI cache is automatically"
    echo "cleared when you:"
    echo "  - Create/update/delete posts or pages"
    echo "  - Install/update/activate plugins or themes"
    echo "  - Update menus, widgets, or customizer"
    echo "  - Approve/edit comments"
    echo "  - A 'Purge Cache' button appears in admin bar"
    echo ""
    echo "----------------------------------------------------"

    if [ "$STATUS" = "ENABLED" ]; then
        echo "1) Reinstall / Update"
        echo "2) Remove"
    else
        echo "1) Enable Auto Purge"
    fi

    echo "3) Deploy to ALL domains"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " action

    case "$action" in
        1)
            deploy_mu_plugin "$DOMAIN_PATH" "$SYSTEM_USER"
            STATUS="ENABLED"
            read -p "Press Enter..."
            ;;
        2)
            if [ "$STATUS" = "ENABLED" ]; then
                remove_mu_plugin "$DOMAIN_PATH"
                STATUS="DISABLED"
            else
                echo "Invalid option"
            fi
            read -p "Press Enter..."
            ;;
        3)
            echo ""
            echo "This will deploy Auto Purge to ALL WordPress sites."
            read -p "Continue? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                deploy_all
            else
                echo "Cancelled."
            fi
            read -p "Press Enter..."
            ;;
        0) break ;;
        *) echo "Invalid option"; sleep 1 ;;
    esac
done
