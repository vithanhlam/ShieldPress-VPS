#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/custom.sh"

DATA_FILE="$DATA_DIR/databases.list"
LOG_FILE="$LOG_DIR/database.log"

if ! mkdir -p "$DATA_DIR" "$LOG_DIR"; then
    echo "Unable to create ShieldPress data directories!"
    exit 1
fi

clear

echo "===================================================="
echo "           CREATE DATABASE + USER"
echo "===================================================="

read -p "Enter Database Name: " DB_NAME

# Validate input
if [[ -z "$DB_NAME" ]]; then
    echo "Database name cannot be empty!"
    read -p "Press Enter..."
    exit 1
fi

# Normalize name
DB_NAME=$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]')
DB_NAME=$(echo "$DB_NAME" | sed 's/[^a-zA-Z0-9]/_/g')

if [[ -z "$DB_NAME" || ${#DB_NAME} -gt 64 ]]; then
    echo "Invalid database name after normalization (maximum 64 characters)!"
    read -p "Press Enter..."
    exit 1
fi

DB_USER="${DB_NAME}_user"

# Generate password
DB_PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c24)

if [[ ${#DB_PASS} -lt 16 ]]; then
    echo "Unable to generate a secure database password!"
    read -p "Press Enter..."
    exit 1
fi

# Check MySQL running
if ! systemctl is-active --quiet mariadb; then
    echo "MariaDB is not running!"
    read -p "Press Enter..."
    exit 1
fi

# Check DB exists
DB_CHECK=$(mysql -N -B -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>&1)
DB_CHECK_STATUS=$?

if [[ "$DB_CHECK_STATUS" -ne 0 ]]; then
    echo "Unable to check database: $DB_CHECK"
    read -p "Press Enter..."
    exit 1
fi

if [[ "$DB_CHECK" == "$DB_NAME" ]]; then
    echo "Database already exists!"
    read -p "Press Enter..."
    exit 1
fi

# Check user exists
USER_CHECK=$(mysql -N -B -e "SELECT User FROM mysql.user WHERE User='$DB_USER' AND Host='localhost';" 2>&1)
USER_CHECK_STATUS=$?

if [[ "$USER_CHECK_STATUS" -ne 0 ]]; then
    echo "Unable to check database user: $USER_CHECK"
    read -p "Press Enter..."
    exit 1
fi

if [[ "$USER_CHECK" == "$DB_USER" ]]; then
    echo "User already exists!"
    read -p "Press Enter..."
    exit 1
fi

echo ""
echo "Creating database..."

if ! MYSQL_ERROR=$(mysql -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1); then
    echo "Database creation failed: $MYSQL_ERROR"
    read -p "Press Enter..."
    exit 1
fi

if ! MYSQL_ERROR=$(mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>&1); then
    mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    echo "Database user creation failed: $MYSQL_ERROR"
    read -p "Press Enter..."
    exit 1
fi

if ! MYSQL_ERROR=$(mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" 2>&1); then
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    echo "Granting database privileges failed: $MYSQL_ERROR"
    read -p "Press Enter..."
    exit 1
fi

if ! MYSQL_ERROR=$(mysql -e "FLUSH PRIVILEGES;" 2>&1); then
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    echo "Finalizing database privileges failed: $MYSQL_ERROR"
    read -p "Press Enter..."
    exit 1
fi

# Save DB info (NOW SAVE PASSWORD)
if ! printf 'DB_NAME=%s | DB_USER=%s | DB_PASS=%s | CREATED=%s\n' \
    "$DB_NAME" "$DB_USER" "$DB_PASS" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"; then
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    echo "Unable to save database information; created database and user were rolled back."
    read -p "Press Enter..."
    exit 1
fi

if ! chmod 600 "$DATA_FILE"; then
    sed -i "/^DB_NAME=$DB_NAME[[:space:]]*|/d" "$DATA_FILE" 2>/dev/null
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
    echo "Unable to secure database information file; created database and user were rolled back."
    read -p "Press Enter..."
    exit 1
fi

# Log
echo "$(date '+%Y-%m-%d %H:%M:%S') - Created DB: $DB_NAME - User: $DB_USER" >> "$LOG_FILE"

echo ""
echo "========================================"
echo " Database Created Successfully!"
echo "----------------------------------------"
echo " DB Name : $DB_NAME"
echo " DB User : $DB_USER"
echo " DB Pass : $DB_PASS"
echo "----------------------------------------"
echo " Saved to: $DATA_FILE"
echo "========================================"

pause
