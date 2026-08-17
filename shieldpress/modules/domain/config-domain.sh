#!/bin/bash

source /opt/shieldpress/modules/domain/helpers.sh

LOG_FILE="$LOG_DIR/domain-config.log"
mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

log(){
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

pause(){
    echo ""
    read -p "Press Enter to continue..."
}

is_number(){
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ==========================================
# SELECT DOMAIN
# ==========================================

select_domain || exit 1

PHP_VERSION=$(grep "^PHP_VERSION=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSTEM_USER}.conf"
PHP_SERVICE="php${PHP_SHORT}-php-fpm"
PHP_INI="/etc/opt/remi/php${PHP_SHORT}/php.ini"
NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

if [ ! -f "$PHP_POOL_FILE" ]; then
    echo -e "${RED}PHP pool file not found!${RESET}"
    exit 1
fi

# ==========================================
# AUTO RAM DETECT
# ==========================================

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
RESERVED=1024
AVAILABLE=$((TOTAL_RAM - RESERVED))
SUGGEST_CHILD=$((AVAILABLE / 30))
[ "$SUGGEST_CHILD" -lt 5 ] && SUGGEST_CHILD=5

# ==========================================
# CLEAN DUPLICATE KEYS (CRITICAL FIX)
# ==========================================

clean_key(){
    KEY=$1
    ESCAPED=$(echo "$KEY" | sed 's/\[/\\[/g; s/\]/\\]/g')
    sed -i "/^$ESCAPED/d" "$PHP_POOL_FILE"
}

# ==========================================
# SAFE SET POOL VALUE
# ==========================================

set_pool_value(){
    KEY=$1
    VALUE=$2
    clean_key "$KEY"
    echo "$KEY = $VALUE" >> "$PHP_POOL_FILE"
}

# ==========================================
# SET php.ini VALUE
# ==========================================

set_ini_value(){
    KEY=$1
    VALUE=$2
    sed -i "s/^$KEY.*/$KEY = $VALUE/" "$PHP_INI"
}

# ==========================================
# BACKUP
# ==========================================

backup_config(){
    cp "$PHP_POOL_FILE" "${PHP_POOL_FILE}.bak"
    cp "$PHP_INI" "${PHP_INI}.bak"
    [ -f "$NGINX_CONF" ] && cp "$NGINX_CONF" "${NGINX_CONF}.bak"
    log "Backup created for $SELECTED_DOMAIN"
}

rollback(){
    echo -e "${RED}Rollback triggered...${RESET}"
    mv "${PHP_POOL_FILE}.bak" "$PHP_POOL_FILE" 2>/dev/null
    mv "${PHP_INI}.bak" "$PHP_INI" 2>/dev/null
    [ -f "${NGINX_CONF}.bak" ] && mv "${NGINX_CONF}.bak" "$NGINX_CONF"
    systemctl restart "$PHP_SERVICE"
    nginx -t && systemctl reload nginx
    log "Rollback executed"
}

# ==========================================
# SHOW CURRENT CONFIG
# ==========================================

show_current(){

	clear
	echo -e "${CYAN}================================================${RESET}"
	echo -e " Domain: ${GREEN}$SELECTED_DOMAIN${RESET}"
	echo -e " PHP Version: ${GREEN}$PHP_VERSION${RESET}"
	echo -e " Server RAM: ${GREEN}${TOTAL_RAM}MB${RESET}"
	echo -e " Suggested pm.max_children: ${GREEN}${SUGGEST_CHILD}${RESET}"
	echo -e "${CYAN}================================================${RESET}"
	echo ""

	echo -e "${YELLOW}PATH INFORMATION${RESET}"
	echo "Public HTML        : $ROOT"
	echo "PHP Pool Config    : $PHP_POOL_FILE"
	echo "PHP Ini            : $PHP_INI"
	echo "Nginx Domain Conf  : $NGINX_CONF"
	echo "Nginx Global Conf  : /etc/nginx/nginx.conf"
	echo "Nginx HTTP Includes: /etc/nginx/conf.d/"
	echo "MariaDB Config     : /etc/my.cnf.d/"
	echo ""

	echo -e "${YELLOW}CURRENT PHP.INI VALUES${RESET}"
	grep -E "memory_limit|upload_max_filesize|post_max_size|max_execution_time|max_input_vars" \
	$PHP_INI 2>/dev/null

	echo ""
	echo -e "${YELLOW}CURRENT PHP-FPM POOL VALUES${RESET}"
	grep -E "pm.max_children|pm.max_requests|php_admin_value" "$PHP_POOL_FILE"
	echo ""

	echo -e "${YELLOW}CURRENT NGINX LIMITS${RESET}"
	if [ -f "$NGINX_CONF" ]; then
		grep -E "client_max_body_size|fastcgi_read_timeout" "$NGINX_CONF"
	else
		echo "No domain nginx config found"
	fi

	echo ""
}

# ==========================================
# SAFE INPUT
# ==========================================

safe_input(){
    LABEL=$1
    CURRENT=$2
    while true; do
        read -p "$LABEL [$CURRENT]: " VALUE
        if [ -z "$VALUE" ]; then
            echo "$CURRENT"
            return
        fi
        if is_number "$VALUE"; then
            echo "$VALUE"
            return
        else
            echo -e "${RED}Invalid number. Try again.${RESET}"
        fi
    done
}

# ==========================================
# PRESETS
# ==========================================

apply_preset(){

case $1 in
1) MEMORY=256; UPLOAD=64; POST=64; EXEC=60; INPUT=3000; CHILD=5 ;;
2) MEMORY=512; UPLOAD=256; POST=256; EXEC=120; INPUT=5000; CHILD=20 ;;
3) MEMORY=2048; UPLOAD=2048; POST=2048; EXEC=300; INPUT=10000; CHILD=50 ;;
esac

set_pool_value "php_admin_value[memory_limit]" "${MEMORY}M"
set_pool_value "php_admin_value[upload_max_filesize]" "${UPLOAD}M"
set_pool_value "php_admin_value[post_max_size]" "${POST}M"
set_pool_value "php_admin_value[max_execution_time]" "$EXEC"
set_pool_value "php_admin_value[max_input_vars]" "$INPUT"
set_pool_value "pm.max_children" "$CHILD"
set_pool_value "pm.max_requests" "500"

set_ini_value "memory_limit" "${MEMORY}M"
set_ini_value "upload_max_filesize" "${UPLOAD}M"
set_ini_value "post_max_size" "${POST}M"
set_ini_value "max_execution_time" "$EXEC"
set_ini_value "max_input_vars" "$INPUT"

# nginx sync
if [ -f "$NGINX_CONF" ]; then
    if grep -q client_max_body_size "$NGINX_CONF"; then
        sed -i "s/client_max_body_size.*/client_max_body_size ${UPLOAD}M;/" "$NGINX_CONF"
    else
        sed -i "/server_name/a \    client_max_body_size ${UPLOAD}M;" "$NGINX_CONF"
    fi
fi

echo -e "${GREEN}Preset applied successfully!${RESET}"
log "Preset $1 applied to $SELECTED_DOMAIN"
}

# ==========================================
# CUSTOM CONFIG
# ==========================================

custom_config(){

CURRENT_MEMORY=$(grep -E '^[^;]*memory_limit' "$PHP_INI" | awk '{print $3}' | tr -d 'M' | tail -1)
CURRENT_UPLOAD=$(grep -E '^[^;]*upload_max_filesize' "$PHP_INI" | awk '{print $3}' | tr -d 'M' | tail -1)
CURRENT_POST=$(grep -E '^[^;]*post_max_size' "$PHP_INI" | awk '{print $3}' | tr -d 'M' | tail -1)
CURRENT_EXEC=$(grep -E '^[^;]*max_execution_time' "$PHP_INI" | awk '{print $3}' | tail -1)
CURRENT_INPUT=$(grep -E '^[^;]*max_input_vars' "$PHP_INI" | awk '{print $3}' | tail -1)
CURRENT_CHILD=$(grep pm.max_children $PHP_POOL_FILE | awk '{print $3}')

MEMORY=$(safe_input "memory_limit (MB)" "$CURRENT_MEMORY")
UPLOAD=$(safe_input "upload_max_filesize (MB)" "$CURRENT_UPLOAD")
POST=$(safe_input "post_max_size (MB)" "$CURRENT_POST")
EXEC=$(safe_input "max_execution_time (seconds)" "$CURRENT_EXEC")
INPUT=$(safe_input "max_input_vars" "$CURRENT_INPUT")
CHILD=$(safe_input "pm.max_children (Suggested: $SUGGEST_CHILD)" "$CURRENT_CHILD")

set_pool_value "php_admin_value[memory_limit]" "${MEMORY}M"
set_pool_value "php_admin_value[upload_max_filesize]" "${UPLOAD}M"
set_pool_value "php_admin_value[post_max_size]" "${POST}M"
set_pool_value "php_admin_value[max_execution_time]" "$EXEC"
set_pool_value "php_admin_value[max_input_vars]" "$INPUT"
set_pool_value "pm.max_children" "$CHILD"

set_ini_value "memory_limit" "${MEMORY}M"
set_ini_value "upload_max_filesize" "${UPLOAD}M"
set_ini_value "post_max_size" "${POST}M"
set_ini_value "max_execution_time" "$EXEC"
set_ini_value "max_input_vars" "$INPUT"

if [ -f "$NGINX_CONF" ]; then
    if grep -q client_max_body_size "$NGINX_CONF"; then
        sed -i "s/client_max_body_size.*/client_max_body_size ${UPLOAD}M;/" "$NGINX_CONF"
    else
        sed -i "/server_name/a \    client_max_body_size ${UPLOAD}M;" "$NGINX_CONF"
    fi
fi

echo -e "${GREEN}Custom config applied!${RESET}"
log "Custom config updated for $SELECTED_DOMAIN"
}

# ==========================================
# MANAGE DISABLED FUNCTIONS
# ==========================================

manage_functions(){

    DISABLED=$(grep "php_admin_value\[disable_functions\]" "$PHP_POOL_FILE" | cut -d'=' -f2 | xargs)

    clear
    echo "===================================================="
    echo "  DISABLED FUNCTIONS - $SELECTED_DOMAIN"
    echo "===================================================="
    echo ""
    echo "Current: ${DISABLED:-none}"
    echo ""
    echo "Default dangerous (recommended to keep disabled):"
    echo "  exec, passthru, shell_exec, system, proc_open, popen, pcntl_exec"
    echo ""
    echo "Some plugins may need:"
    echo "  exec          - WP-CLI, backup plugins, image processing"
    echo "  proc_open     - UpdraftPlus, WooCommerce PDF"
    echo "  passthru      - FFmpeg, ImageMagick CLI"
    echo "  shell_exec    - Some caching plugins"
    echo ""
    echo "1) Apply DEFAULT (all 7 functions disabled) - most secure"
    echo "2) Allow exec only (needed by many plugins)"
    echo "3) Allow exec + proc_open (backup/PDF plugins)"
    echo "4) Disable ALL restrictions (NOT recommended)"
    echo "5) Custom - enter manually"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " OPT

    case $OPT in
    1)
        NEW_DISABLED="exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec"
        ;;
    2)
        NEW_DISABLED="passthru,shell_exec,system,proc_open,popen,pcntl_exec"
        echo ""
        echo "[INFO] exec is now ALLOWED - needed by WP-CLI, backup plugins"
        ;;
    3)
        NEW_DISABLED="passthru,shell_exec,system,popen,pcntl_exec"
        echo ""
        echo "[INFO] exec + proc_open ALLOWED - for backup/PDF plugins"
        ;;
    4)
        NEW_DISABLED=""
        echo ""
        echo "[WARN] All function restrictions removed!"
        ;;
    5)
        echo ""
        echo "Enter functions to DISABLE (comma-separated), or leave empty to allow all:"
        echo "Available: exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec"
        read -p "Disable: " NEW_DISABLED
        ;;
    0) return ;;
    *) echo "Invalid"; return ;;
    esac

    # Update pool config
    if grep -q "disable_functions" "$PHP_POOL_FILE"; then
        if [ -z "$NEW_DISABLED" ]; then
            sed -i "/php_admin_value\[disable_functions\]/d" "$PHP_POOL_FILE"
        else
            sed -i "s|php_admin_value\[disable_functions\].*|php_admin_value[disable_functions] = $NEW_DISABLED|" "$PHP_POOL_FILE"
        fi
    else
        [ -n "$NEW_DISABLED" ] &&             echo "php_admin_value[disable_functions] = $NEW_DISABLED" >> "$PHP_POOL_FILE"
    fi

    systemctl restart "$PHP_SERVICE" &&         echo "[OK] Function restrictions updated" ||         echo "[FAIL] PHP-FPM restart failed"
}


# ==========================================
# MAIN
# ==========================================

while true; do

show_current

echo "1) Apply SMALL Website preset"
echo "2) Apply MEDIUM Website preset"
echo "3) Apply LARGE Website preset"
echo "4) Custom configuration"
echo "5) Manage Disabled Functions (Security)"
echo "0) Back"
echo "--------------------------------"

read -p "Select: " OPTION

case $OPTION in

1|2|3)
    backup_config
    apply_preset $OPTION
    systemctl restart "$PHP_SERVICE" || { rollback; pause; continue; }
    nginx -t || { rollback; pause; continue; }
    systemctl reload nginx
    pause
    ;;

4)
    backup_config
    custom_config
    systemctl restart "$PHP_SERVICE" || { rollback; pause; continue; }
    nginx -t || { rollback; pause; continue; }
    systemctl reload nginx
    pause
    ;;

5)
    manage_functions
    pause
    ;;

0) break ;;

*) echo "Invalid option"; sleep 1 ;;

esac

done