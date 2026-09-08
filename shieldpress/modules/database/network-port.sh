#!/bin/bash

set -u
BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/ui.sh"
GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_source(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ || "$1" == "*" ]]; }

echo "1) MariaDB (mặc định 3306)"; echo "2) PostgreSQL (mặc định 5432)"
read -r -p "Chọn engine: " ENGINE
case "$ENGINE" in 1) ENGINE=mariadb; DEFAULT_PORT=3306;; 2) ENGINE=postgresql; DEFAULT_PORT=5432;; *) fail "Lựa chọn không hợp lệ."; exit 1;; esac
read -r -p "Port [$DEFAULT_PORT]: " PORT; PORT="${PORT:-$DEFAULT_PORT}"; valid_port "$PORT" || { fail "Port không hợp lệ."; exit 1; }
read -r -p "Bind address [127.0.0.1]: " BIND; BIND="${BIND:-127.0.0.1}"
[[ "$BIND" =~ ^[0-9a-fA-F:.]+$ ]] || { fail "Bind address không hợp lệ."; exit 1; }
REMOTE=0; [[ "$BIND" != "127.0.0.1" && "$BIND" != "::1" && "$BIND" != "localhost" ]] && REMOTE=1
SOURCE=""
if [ "$REMOTE" = 1 ]; then
    read -r -p "CIDR/IP được phép truy cập (bắt buộc, ví dụ 203.0.113.10/32): " SOURCE
    valid_source "$SOURCE" || { fail "CIDR/IP nguồn không hợp lệ."; exit 1; }
    [ "$SOURCE" != "*" ] || warn "Bạn đang mở cho mọi nguồn; nên dùng IP/CIDR cụ thể."
fi

if [ "$ENGINE" = mariadb ]; then
    mkdir -p /etc/my.cnf.d
    cat > /etc/my.cnf.d/99-shieldpress-network.cnf <<EOF
[mysqld]
bind-address=$BIND
port=$PORT
EOF
    systemctl restart mariadb || { fail "MariaDB không khởi động lại được."; exit 1; }
else
    PG_CONF=/var/lib/pgsql/data/postgresql.conf; PG_HBA=/var/lib/pgsql/data/pg_hba.conf
    [ -f "$PG_CONF" ] && [ -f "$PG_HBA" ] || { fail "Không tìm thấy cấu hình PostgreSQL."; exit 1; }
    sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '$BIND'/; s/^[#[:space:]]*port[[:space:]]*=.*/port = $PORT/" "$PG_CONF"
    grep -q "^listen_addresses" "$PG_CONF" || echo "listen_addresses = '$BIND'" >> "$PG_CONF"
    grep -q "^port" "$PG_CONF" || echo "port = $PORT" >> "$PG_CONF"
    if [ "$REMOTE" = 1 ]; then
        grep -qF "# SHIELDPRESS remote access $SOURCE" "$PG_HBA" || printf "\n# SHIELDPRESS remote access %s\nhost all all %s scram-sha-256\n" "$SOURCE" "$SOURCE" >> "$PG_HBA"
        chown postgres:postgres "$PG_HBA"; restorecon "$PG_HBA" >/dev/null 2>&1 || true
    fi
    systemctl restart postgresql || { fail "PostgreSQL không khởi động lại được."; exit 1; }
fi

read -r -p "Mở port $PORT/tcp trên firewalld? [y/N]: " OPEN
if [[ "$OPEN" =~ ^[Yy]$ ]]; then
    command -v firewall-cmd >/dev/null 2>&1 || dnf install -y firewalld
    systemctl enable --now firewalld >/dev/null 2>&1 || true; ZONE=$(firewall-cmd --get-default-zone)
    if [ "$REMOTE" = 1 ] && [ "$SOURCE" != "*" ]; then
        firewall-cmd --zone="$ZONE" --permanent --add-rich-rule="rule family='ipv4' source address='$SOURCE' port port='$PORT' protocol='tcp' accept" >/dev/null || { fail "Không mở được firewall rule giới hạn nguồn."; exit 1; }
    else
        firewall-cmd --zone="$ZONE" --permanent --add-port="$PORT/tcp" >/dev/null || { fail "Không mở được firewall port."; exit 1; }
    fi
    firewall-cmd --reload >/dev/null; ok "Đã cập nhật firewalld ($PORT/tcp)."
else
    warn "Không mở firewall; dịch vụ chỉ nhận kết nối theo cấu hình mạng hiện tại."
fi
ok "$ENGINE đang dùng bind=$BIND, port=$PORT."
read -r -p "Chọn database/tài khoản và test kết nối TCP ngay? [y/N]: " TEST_NOW
if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    TEST_HOST="$BIND"; [ "$TEST_HOST" = "0.0.0.0" ] && TEST_HOST=127.0.0.1
    bash "$BASE_DIR/modules/database/test-connection.sh" "$ENGINE" "$TEST_HOST" "$PORT"
fi
