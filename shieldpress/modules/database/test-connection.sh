#!/bin/bash

# Test a real TCP login against MariaDB or PostgreSQL.
set -u
BASE_DIR="/opt/shieldpress"
ENGINE="${1:-}"
TEST_HOST="${2:-127.0.0.1}"
TEST_PORT="${3:-}"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"; RED="\e[31m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

if [ -z "$ENGINE" ]; then
    echo "1) MariaDB"; echo "2) PostgreSQL"
    read -r -p "Chọn engine: " choice
    case "$choice" in 1) ENGINE=mariadb;; 2) ENGINE=postgresql;; *) fail "Lựa chọn không hợp lệ."; exit 1;; esac
fi

if [ -z "$TEST_PORT" ]; then
    [ "$ENGINE" = mariadb ] && TEST_PORT=3306 || TEST_PORT=5432
    read -r -p "Port [$TEST_PORT]: " value; TEST_PORT="${value:-$TEST_PORT}"
fi
valid_port "$TEST_PORT" || { fail "Port không hợp lệ."; exit 1; }
[ "$TEST_HOST" = "0.0.0.0" ] && TEST_HOST=127.0.0.1
read -r -p "Host kiểm tra [$TEST_HOST]: " value; TEST_HOST="${value:-$TEST_HOST}"

choose_maria(){
    mapfile -t DB_LIST < <(mysql -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME" 2>/dev/null)
    mapfile -t USER_LIST < <(mysql -NBe "SELECT DISTINCT User FROM mysql.user WHERE User <> '' AND User NOT IN ('mariadb.sys','mysql','root') ORDER BY User" 2>/dev/null)
}
choose_pg(){
    mapfile -t DB_LIST < <(runuser -u postgres -- psql -Atc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY datname" 2>/dev/null)
    mapfile -t USER_LIST < <(runuser -u postgres -- psql -Atc "SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname NOT IN ('postgres') ORDER BY rolname" 2>/dev/null)
}

if [ "$ENGINE" = mariadb ]; then choose_maria; else choose_pg; fi
[ "${#DB_LIST[@]}" -gt 0 ] || { fail "Không tìm thấy database."; exit 1; }
[ "${#USER_LIST[@]}" -gt 0 ] || { fail "Không tìm thấy tài khoản login."; exit 1; }
echo "Database:"; i=1; for item in "${DB_LIST[@]}"; do echo "  $i) $item"; ((i++)); done
read -r -p "Chọn database: " choice
[[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DB_LIST[@]}" ] || { fail "Database không hợp lệ."; exit 1; }
DB_NAME="${DB_LIST[$((choice-1))]}"
echo "Tài khoản:"; i=1; for item in "${USER_LIST[@]}"; do echo "  $i) $item"; ((i++)); done
read -r -p "Chọn tài khoản: " choice
[[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#USER_LIST[@]}" ] || { fail "Tài khoản không hợp lệ."; exit 1; }
DB_USER="${USER_LIST[$((choice-1))]}"
read -r -s -p "Mật khẩu của $DB_USER: " DB_PASS; echo

if [ "$ENGINE" = mariadb ]; then
    CRED_FILE=$(mktemp)
    chmod 600 "$CRED_FILE"
    printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASS" > "$CRED_FILE"
    trap 'rm -f "$CRED_FILE"' EXIT
    if mysql --defaults-extra-file="$CRED_FILE" --protocol=tcp -h "$TEST_HOST" -P "$TEST_PORT" "$DB_NAME" -NBe 'SELECT 1' 2>&1 | grep -qx '1'; then
        ok "MariaDB TCP kết nối thành công: $DB_USER@$TEST_HOST:$TEST_PORT/$DB_NAME"
    else
        fail "MariaDB TCP kết nối thất bại. Kiểm tra port, firewall, mật khẩu và quyền user."; exit 1
    fi
else
    if result=$(PGPASSWORD="$DB_PASS" psql "host=$TEST_HOST port=$TEST_PORT dbname=$DB_NAME user=$DB_USER connect_timeout=5" -Atc 'SELECT 1' 2>&1) && [ "$result" = "1" ]; then
        ok "PostgreSQL TCP kết nối thành công: $DB_USER@$TEST_HOST:$TEST_PORT/$DB_NAME"
    else
        fail "PostgreSQL TCP kết nối thất bại: $result"; exit 1
    fi
fi
