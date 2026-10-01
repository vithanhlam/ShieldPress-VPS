#!/bin/bash
# Repair schedules and legacy standalone lineages on existing installations.
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/modules/ssl/ssl-utils.sh"

if ! command -v certbot >/dev/null; then
    echo "Certbot is not installed; auto-renew will be configured when SSL is installed."
    exit 0
fi
ensure_ssl_dependencies || exit 1
ensure_ssl_auto_renew || { fail "Could not enable SSL auto-renew"; exit 1; }

status=0
for renewal in "$SSL_LE_DIR"/renewal/*.conf; do
    [ -f "$renewal" ] || continue
    domain="${renewal##*/}"
    domain="${domain%.conf}"
    if grep -Eq '^authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal"; then
        if nginx -t && ssl_migrate_standalone "$domain"; then
            ok "Migrated $domain from standalone to Nginx HTTP-01"
        else
            fail "Could not migrate $domain; check DNS/port 80 and retry this patch"
            status=1
        fi
    elif grep -Eq '^authenticator[[:space:]]*=[[:space:]]*manual[[:space:]]*$' "$renewal" &&
        ! grep -Eq '^manual_auth_hook[[:space:]]*=[[:space:]]*[^[:space:]]' "$renewal"; then
        warn "$domain uses manual validation without an authentication hook; it cannot auto-renew"
    fi
done
exit "$status"
