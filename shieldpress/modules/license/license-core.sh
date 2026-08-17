#!/bin/bash

BASE_DIR="/opt/shieldpress"
LICENSE_FILE="$BASE_DIR/license.key"
STATUS_FILE="$BASE_DIR/license.status"

API_SERVER="https://install.shieldpress.net/verify"

check_license_local() {
    [ -f "$STATUS_FILE" ] || return 1
    local STATUS
    STATUS=$(grep "^STATUS=" "$STATUS_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    [ "$STATUS" = "active" ]
}

activate_license() {

    read -p "Enter License Key: " KEY

    if [ -z "$KEY" ]; then
        echo "License key cannot be empty!"
        return
    fi

    # Validate key format (basic sanity check)
    if ! [[ "$KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Invalid key format!"
        return
    fi

    echo "Verifying license..."

    RESPONSE=$(curl -s -X POST "$API_SERVER" \
        --connect-timeout 5 --max-time 10 \
        -d "key=$KEY" \
        -d "ip=$(hostname -I | awk '{print $1}')")

    # Strict JSON response validation instead of loose grep
    if echo "$RESPONSE" | grep -qE '^.*"status"\s*:\s*"VALID"'; then

        echo "STATUS=active" > "$STATUS_FILE"
        echo "KEY=$KEY" >> "$STATUS_FILE"
        chmod 600 "$STATUS_FILE"

        echo "$KEY" > "$LICENSE_FILE"
        chmod 600 "$LICENSE_FILE"

        echo "License Activated Successfully!"
    else
        echo "Invalid License Key!"
    fi
}

deactivate_license() {
    rm -f "$LICENSE_FILE"
    rm -f "$STATUS_FILE"
    echo "License removed."
}