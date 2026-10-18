#!/bin/bash
# Meilisearch installer and per-domain search-key manager.
set -euo pipefail

MEILI_VERSION="v1.12.0"
MEILI_BIN="/usr/local/bin/meilisearch"
MEILI_DATA="/var/lib/meilisearch"
MEILI_CONFIG="/etc/meilisearch.toml"
MEILI_SERVICE="/etc/systemd/system/meilisearch.service"
MEILI_URL="http://127.0.0.1:7700"
DOMAINS_ROOT="/home/domains"

ok(){ printf '[OK] %s\n' "$*"; }
fail(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "Run with sudo/root."

read_master_key(){
    [[ -r "$MEILI_CONFIG" ]] || return 1
    sed -nE 's/^[[:space:]]*master_key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$MEILI_CONFIG" | head -n1
}

install_meili(){
    local os glibc key current
    os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release | head -n1)
    glibc=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+$' || true)
    key=$(read_master_key 2>/dev/null || true)
    if [[ -z "$key" ]]; then key=$(openssl rand -hex 32); fi

    mkdir -p "$MEILI_DATA"
    chmod 755 "$MEILI_DATA"
    current=$("$MEILI_BIN" --version 2>/dev/null | grep -oE 'v[0-9.]+' || true)
    if [[ "$current" != "$MEILI_VERSION" ]]; then
        curl -fsSL "https://github.com/meilisearch/meilisearch/releases/download/${MEILI_VERSION}/meilisearch-linux-amd64" -o "$MEILI_BIN"
        chmod 755 "$MEILI_BIN"
    fi
    "$MEILI_BIN" --version >/dev/null || fail "Meilisearch binary check failed."

    cat > "$MEILI_CONFIG" <<EOF
# Managed by ShieldPress
db_path = "$MEILI_DATA"
env = "production"
http_addr = "127.0.0.1:7700"
master_key = "$key"
no_analytics = true
log_level = "WARN"
EOF
    chmod 600 "$MEILI_CONFIG"
    cat > "$MEILI_SERVICE" <<EOF
[Unit]
Description=Meilisearch Search Engine
After=network.target

[Service]
ExecStart=$MEILI_BIN --config-file-path=$MEILI_CONFIG
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now meilisearch
    ok "Meilisearch $MEILI_VERSION is running ($os${glibc:+, glibc $glibc}). Existing data was preserved."
    printf 'Endpoint: %s (local server access)\n' "$MEILI_URL"
}

select_domain(){
    local -a dirs=() names=()
    local d name i choice
    echo "Configured domains:"
    for d in "$DOMAINS_ROOT"/*/; do
        [[ -f "$d/config/domain.env" ]] || continue
        name=$(sed -n 's/^DOMAIN=//p' "$d/config/domain.env" | head -n1)
        [[ -n "$name" ]] || continue
        dirs+=("${d%/}"); names+=("$name")
        printf ' %d) %s\n' "${#dirs[@]}" "$name"
    done
    ((${#dirs[@]})) || fail "No configured domains found."
    read -r -p "Select domain: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#dirs[@]})) || fail "Invalid selection."
    DOMAIN_PATH="${dirs[$((choice-1))]}"
    DOMAIN_NAME="${names[$((choice-1))]}"
    DOMAIN_ENV="$DOMAIN_PATH/config/domain.env"
    DOMAIN_INDEX="products_$(printf '%s' "$DOMAIN_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g' | cut -c1-200)"
}

save_domain_key(){
    local uid="$1" value="$2" env_tmp
    env_tmp=$(mktemp "${DOMAIN_ENV}.XXXXXX")
    awk '!/^MEILI_(HOST|INDEX|KEY|KEY_UID)=/' "$DOMAIN_ENV" > "$env_tmp"
    {
        printf 'MEILI_HOST=%s\n' "$MEILI_URL"
        printf 'MEILI_INDEX=%s\n' "$DOMAIN_INDEX"
        printf 'MEILI_KEY=%s\n' "$value"
        printf 'MEILI_KEY_UID=%s\n' "$uid"
    } >> "$env_tmp"
    cat "$env_tmp" > "$DOMAIN_ENV"
    rm -f "$env_tmp"
    chmod 600 "$DOMAIN_ENV"
}

manage_key(){
    local action="$1" master response uid value status
    select_domain
    master=$(read_master_key)
    curl -fsS "$MEILI_URL/health" >/dev/null || fail "Meilisearch is not responding at $MEILI_URL."
    case "$action" in
        create)
            if grep -q '^MEILI_KEY_UID=' "$DOMAIN_ENV"; then
                read -r -p "A key is already saved. Create and replace it? [y/N]: " confirm
                [[ "$confirm" =~ ^[yY]$ ]] || return 0
                uid=$(sed -n 's/^MEILI_KEY_UID=//p' "$DOMAIN_ENV" | head -n1)
                curl -fsS -X DELETE "$MEILI_URL/keys/$uid" -H "Authorization: Bearer $master" >/dev/null || fail "Could not revoke the old key."
            fi
            curl -fsS -X POST "$MEILI_URL/indexes" -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
                -d "{\"uid\":\"$DOMAIN_INDEX\",\"primaryKey\":\"post_id\"}" >/dev/null || true
            response=$(curl -fsS -X POST "$MEILI_URL/keys" -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
                -d "{\"name\":\"shieldpress-$DOMAIN_NAME\",\"description\":\"Search-only key for $DOMAIN_NAME\",\"actions\":[\"search\"],\"indexes\":[\"$DOMAIN_INDEX\"]}") || fail "Key creation failed."
            uid=$(printf '%s' "$response" | sed -nE 's/.*"uid"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
            value=$(printf '%s' "$response" | sed -nE 's/.*"key"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
            [[ -n "$uid" && -n "$value" ]] || fail "Could not read the created key response. Install jq or check the Meilisearch API response."
            save_domain_key "$uid" "$value"
            ok "Search-only key created and saved to $DOMAIN_ENV"
            ;;
        show)
            value=$(sed -n 's/^MEILI_KEY=//p' "$DOMAIN_ENV" | head -n1)
            [[ -n "$value" ]] || fail "No key saved for $DOMAIN_NAME."
            printf '\nDomain: %s\nEndpoint: %s\nIndex: %s\nKey: %s\n' "$DOMAIN_NAME" "$MEILI_URL" "$DOMAIN_INDEX" "$value"
            ;;
        revoke)
            uid=$(sed -n 's/^MEILI_KEY_UID=//p' "$DOMAIN_ENV" | head -n1)
            [[ -n "$uid" ]] || fail "No managed key found for $DOMAIN_NAME."
            read -r -p "Revoke this domain's key? [y/N]: " confirm
            [[ "$confirm" =~ ^[yY]$ ]] || return 0
            curl -fsS -X DELETE "$MEILI_URL/keys/$uid" -H "Authorization: Bearer $master" >/dev/null || fail "Key revocation failed."
            env_tmp=$(mktemp "${DOMAIN_ENV}.XXXXXX")
            awk '!/^MEILI_(HOST|INDEX|KEY|KEY_UID)=/' "$DOMAIN_ENV" > "$env_tmp"
            cat "$env_tmp" > "$DOMAIN_ENV"; rm -f "$env_tmp"; chmod 600 "$DOMAIN_ENV"
            ok "Domain key revoked and removed from domain.env."
            ;;
    esac
    echo
    echo "Connect your app with MEILI_HOST, MEILI_INDEX, and MEILI_KEY from domain.env."
    echo "The endpoint is localhost-only; connect through the app on this server or a private tunnel."
}

echo "Meilisearch: install/update, or manage a search-only key per domain."
echo "1) Install / Update  2) Create domain key  3) Show saved key  4) Revoke domain key  0) Back"
read -r -p "Select: " choice
case "$choice" in
    1) install_meili ;;
    2) manage_key create ;;
    3) manage_key show ;;
    4) manage_key revoke ;;
    0) exit 0 ;;
    *) fail "Invalid selection." ;;
esac
