#!/bin/bash

BASE_DIR="/opt/shieldpress"

# Đọc version từ file
SHIELDPRESS_VERSION=$(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo "unknown")

clear

echo "======================================================"
echo "           ShieldPress VPS - SYSTEM INFORMATION"
echo "======================================================"
echo ""

# ------------------------------------------------
# SYSTEM INFO
# ------------------------------------------------

CPU_MODEL=$(lscpu | grep "Model name" | awk -F': ' '{print $2}' | xargs)
CPU_CORES=$(nproc)
CPU_FREQ=$(lscpu | grep "CPU MHz\|CPU max MHz" | head -1 | awk '{print $NF}' | cut -d'.' -f1)
CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)

DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m  | awk '/Mem:/ {print $3}')
RAM_FREE=$(free -m  | awk '/Mem:/ {print $4+$6+$7}')

SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m  | awk '/Swap:/ {print $3}')

UPTIME=$(uptime -p | sed 's/up //')
OS=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
KERNEL=$(uname -r)
ARCH=$(uname -m)
VIRT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
DOMAIN_COUNT=$(find /home/domains -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

echo "  ShieldPress VPS Version: $SHIELDPRESS_VERSION"
echo "  OS                : $OS"
echo "  Kernel            : $KERNEL"
echo "  Arch              : $ARCH"
echo "  Virtualization    : $VIRT"
echo "  Uptime            : $UPTIME"
echo ""
echo "  CPU Model         : $CPU_MODEL"
echo "  CPU Cores         : $CPU_CORES"
echo "  CPU Freq          : ${CPU_FREQ:-N/A} MHz"
echo "  Load Average      : $CPU_LOAD"
echo ""
echo "  RAM Total         : ${RAM_TOTAL}MB"
echo "  RAM Used          : ${RAM_USED}MB"
echo "  RAM Free          : ${RAM_FREE}MB"
echo "  Swap              : ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
echo ""
echo "  Disk Used         : $DISK_USED / $DISK_TOTAL ($DISK_PERCENT)"
echo "  Domains           : $DOMAIN_COUNT"

# ------------------------------------------------
# NETWORK INFO (timeout ngắn để không chờ lâu)
# ------------------------------------------------

echo ""
echo "======================================================"
echo "  NETWORK"
echo "======================================================"

IP=$(curl -s --connect-timeout 3 https://ipv4.icanhazip.com 2>/dev/null || \
     curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null)
ORG=$(curl -s --connect-timeout 3 "https://ipinfo.io/${IP}/org" 2>/dev/null)
CITY=$(curl -s --connect-timeout 3 https://ipinfo.io/city 2>/dev/null)
COUNTRY=$(curl -s --connect-timeout 3 https://ipinfo.io/country 2>/dev/null)

echo "  Public IP         : ${IP:-N/A}"
echo "  Organization      : ${ORG:-N/A}"
echo "  Location          : ${CITY:-N/A}, ${COUNTRY:-N/A}"

OPEN_PORTS=$(ss -tuln | awk 'NR>1 {print $5}' | grep -oP '(?<=:)\d+$' | sort -n | uniq | tr '\n' ' ')
echo "  Open Ports        : $OPEN_PORTS"

# ------------------------------------------------
# SERVICE STATUS
# ------------------------------------------------

echo ""
echo "======================================================"
echo "  SERVICE STATUS"
echo "======================================================"

check_svc(){
    local NAME=$1 SVC=$2
    local STATE=$(systemctl is-active "$SVC" 2>/dev/null)
    if [ "$STATE" = "active" ]; then
        printf "  %-18s : \e[32m%s\e[0m\n" "$NAME" "running"
    else
        printf "  %-18s : \e[31m%s\e[0m\n" "$NAME" "$STATE"
    fi
}

check_svc "Nginx"     nginx
check_svc "MariaDB"   mariadb
check_svc "PostgreSQL" postgresql
check_svc "Valkey"    valkey
check_svc "Fail2ban"  fail2ban
check_svc "Firewalld" firewalld

for php in 81 82 83 84; do
    SVC="php${php}-php-fpm"
    systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
    check_svc "PHP ${php:0:1}.${php:1} FPM" "$SVC"
done

# ------------------------------------------------
# INSTALLED VERSIONS
# ------------------------------------------------

echo ""
echo "======================================================"
echo "  VERSIONS"
echo "======================================================"

NGINX_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\S+')
MYSQL_VER=$(mysql -V 2>/dev/null | awk '{print $5}' | tr -d ',')
PG_VER=$(psql --version 2>/dev/null | awk '{print $3}')
VALKEY_VER=$(valkey-server --version 2>/dev/null | awk '{print $3}')
NODE_VER=$(node -v 2>/dev/null)
NPM_VER=$(npm -v 2>/dev/null)
COMPOSER_VER=$(composer --version 2>/dev/null | awk '{print $3}')

echo "  Nginx             : ${NGINX_VER:-N/A}"
echo "  MariaDB           : ${MYSQL_VER:-N/A}"
echo "  PostgreSQL        : ${PG_VER:-N/A}"
echo "  Valkey            : ${VALKEY_VER:-N/A}"
echo "  Node.js           : ${NODE_VER:-N/A}"
echo "  npm               : ${NPM_VER:-N/A}"
echo "  Composer          : ${COMPOSER_VER:-N/A}"

for php in 81 82 83 84; do
    BIN="/opt/remi/php${php}/root/usr/bin/php"
    [ -x "$BIN" ] || continue
    VER=$("$BIN" -r 'echo PHP_VERSION;' 2>/dev/null)
    printf "  PHP %-14s : %s\n" "${php:0:1}.${php:1}" "${VER:-N/A}"
done

# ------------------------------------------------
# DISK SPEED TEST
# ------------------------------------------------

echo ""
echo "======================================================"
echo "  DISK SPEED TEST"
echo "======================================================"

echo -n "  Write speed       : "
WRITE=$(dd if=/dev/zero of=/tmp/shieldpress_speed_test bs=64k count=4k conv=fdatasync 2>&1 | \
    awk '/copied/ {print $(NF-1),$NF}')
rm -f /tmp/shieldpress_speed_test
echo "${WRITE:-N/A}"

# ------------------------------------------------
# INTERNET SPEED TEST
# ------------------------------------------------

echo ""
echo "======================================================"
echo "  INTERNET SPEED TEST"
echo "======================================================"

speed_test(){
    local LABEL=$1 URL=$2
    local SPEED MB
    SPEED=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 10 "$URL" 2>/dev/null)
    MB=$(echo "scale=1; $SPEED / 1048576" | bc 2>/dev/null || echo "0")
    printf "  %-35s : %s MB/s\n" "$LABEL" "$MB"
}

speed_test "Cloudflare (Singapore)"   "https://speed.cloudflare.com/__down?bytes=50000000"
speed_test "Linode (Tokyo)"           "http://speedtest.tokyo2.linode.com/100MB-tokyo.bin"
speed_test "Vultr (Singapore)"        "https://sgp-ping.vultr.com/vultr.com.100MB.bin"

echo ""
echo "======================================================"
echo ""
read -p "Press Enter to continue..."
