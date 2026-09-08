#!/bin/bash

# Create a least-privilege account for an existing database.
set -u
BASE_DIR="/opt/shieldpress"
ENGINE="${1:-}"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; RESET="\e[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
valid_name(){ [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]; }
sql_quote(){ local v="$1"; printf "%s" "${v//\'/\'\'}"; }
mysql_ident(){ local v="$1"; printf "%s" "${v//\`/\`\`}"; }
pg_ident(){ local v="$1"; printf "%s" "${v//\"/\"\"}"; }
gen_password(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; }

choose_maria_db(){
    local i=1 choice; mapfile -t dbs < <(mysql -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME" 2>/dev/null)
    [ "${#dbs[@]}" -gt 0 ] || { fail "Không tìm thấy database MariaDB."; return 1; }
    echo "Database MariaDB hiện có:"; for db in "${dbs[@]}"; do echo "  $i) $db"; ((i++)); done
    read -r -p "Chọn database: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dbs[@]}" ] || { fail "Lựa chọn không hợp lệ."; return 1; }
    DB_NAME="${dbs[$((choice-1))]}"
}
choose_pg_db(){
    local i=1 choice; mapfile -t dbs < <(runuser -u postgres -- psql -Atc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres' ORDER BY datname" 2>/dev/null)
    [ "${#dbs[@]}" -gt 0 ] || { fail "Không tìm thấy database PostgreSQL."; return 1; }
    echo "Database PostgreSQL hiện có:"; for db in "${dbs[@]}"; do echo "  $i) $db"; ((i++)); done
    read -r -p "Chọn database: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dbs[@]}" ] || { fail "Lựa chọn không hợp lệ."; return 1; }
    DB_NAME="${dbs[$((choice-1))]}"
}
read_privileges(){
    PRIVS=(); echo "Chọn quyền (y/N):"
    read -r -p "  Đọc dữ liệu (SELECT)? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && PRIVS+=(SELECT)
    read -r -p "  Xem cấu trúc/view (SHOW VIEW)? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && PRIVS+=(SHOW_VIEW)
    read -r -p "  Sửa dữ liệu (INSERT, UPDATE)? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && PRIVS+=(INSERT UPDATE)
    read -r -p "  Xoá dữ liệu (DELETE)? [y/N]: " v; [[ "$v" =~ ^[Yy]$ ]] && PRIVS+=(DELETE)
    [ "${#PRIVS[@]}" -gt 0 ] || { fail "Phải chọn ít nhất một quyền."; return 1; }
}
create_maria_user(){
    systemctl is-active --quiet mariadb || { fail "MariaDB chưa chạy."; return 1; }; choose_maria_db || return
    read -r -p "Tên tài khoản mới: " DB_USER; valid_name "$DB_USER" || { fail "Tên tài khoản không hợp lệ."; return 1; }
    read -r -p "Host đăng nhập [localhost]: " DB_HOST; DB_HOST="${DB_HOST:-localhost}"
    [[ "$DB_HOST" =~ ^[A-Za-z0-9._%:-]+$ ]] || { fail "Host không hợp lệ."; return 1; }
    DB_PASS=$(gen_password); [ "${#DB_PASS}" -eq 24 ] || { fail "Không tạo được mật khẩu."; return 1; }; read_privileges || return
    local grants=() p qdb quser qhost; qdb=$(mysql_ident "$DB_NAME"); quser=$(sql_quote "$DB_USER"); qhost=$(sql_quote "$DB_HOST")
    for p in "${PRIVS[@]}"; do [ "$p" = SHOW_VIEW ] && grants+=("SHOW VIEW") || grants+=("$p"); done
    if mysql -NBe "SELECT 1 FROM mysql.user WHERE User='$quser' AND Host='$qhost'" 2>/dev/null | grep -q 1; then fail "Tài khoản '$DB_USER@$DB_HOST' đã tồn tại."; return 1; fi
    mysql -e "CREATE USER '$quser'@'$qhost' IDENTIFIED BY '$(sql_quote "$DB_PASS")'; GRANT $(IFS=,; echo "${grants[*]}") ON \`$qdb\`.* TO '$quser'@'$qhost'; FLUSH PRIVILEGES;" || { fail "Tạo tài khoản/cấp quyền MariaDB thất bại."; return 1; }
    ok "Đã tạo MariaDB user '$DB_USER@$DB_HOST' trên '$DB_NAME'."; echo "Quyền: ${grants[*]}"; echo "Mật khẩu: $DB_PASS"
}
create_pg_user(){
    systemctl is-active --quiet postgresql || { fail "PostgreSQL chưa chạy."; return 1; }; choose_pg_db || return
    read -r -p "Tên role/tài khoản mới: " DB_USER; valid_name "$DB_USER" || { fail "Tên role không hợp lệ."; return 1; }; DB_PASS=$(gen_password); read_privileges || return
    local sqlpass; sqlpass=$(sql_quote "$DB_PASS")
    if runuser -u postgres -- psql -Atc "SELECT 1 FROM pg_roles WHERE rolname='$(sql_quote "$DB_USER")'" | grep -q 1; then fail "Role '$DB_USER' đã tồn tại."; return 1; fi
    local unique_privs dbq userq; dbq=$(pg_ident "$DB_NAME"); userq=$(pg_ident "$DB_USER")
    local table_privs=() p sequence_sql=""; for p in "${PRIVS[@]}"; do case "$p" in SELECT|SHOW_VIEW) table_privs+=(SELECT);; INSERT|UPDATE) table_privs+=("$p"); sequence_sql=" GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"$userq\";";; DELETE) table_privs+=(DELETE);; esac; done
    unique_privs=$(printf '%s\n' "${table_privs[@]}" | sort -u | paste -sd, -)
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE ROLE \"$userq\" LOGIN PASSWORD '$sqlpass'; GRANT CONNECT ON DATABASE \"$dbq\" TO \"$userq\";" >/dev/null || { fail "Tạo PostgreSQL role thất bại."; return 1; }
    if ! runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT USAGE ON SCHEMA public TO \"$userq\"; GRANT $unique_privs ON ALL TABLES IN SCHEMA public TO \"$userq\"; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT $unique_privs ON TABLES TO \"$userq\";$sequence_sql" >/dev/null; then
        runuser -u postgres -- psql -d postgres -c "DROP ROLE IF EXISTS \"$userq\";" >/dev/null 2>&1; fail "Cấp quyền PostgreSQL thất bại."; return 1
    fi
    ok "Đã tạo PostgreSQL role '$DB_USER' trên '$DB_NAME'."; echo "Quyền bảng: $unique_privs"; echo "Mật khẩu: $DB_PASS"
}
case "$ENGINE" in mariadb) create_maria_user;; postgresql) create_pg_user;; *) fail "Engine không hợp lệ (mariadb|postgresql)."; exit 1;; esac
