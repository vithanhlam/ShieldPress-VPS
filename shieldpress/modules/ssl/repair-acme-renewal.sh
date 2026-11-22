#!/bin/bash
# Repair unattended webroot renewals of existing certificates.
#
# Older vhosts answer /.well-known/acme-challenge/ with 403 (the dotfile deny
# rule) and many renewal files still point at a stale webroot (for example a
# former OpenLiteSpeed path). Certbot then fails every renewal until the
# certificate is days from expiry. Install the shared ShieldPress HTTP-01
# location in each vhost, point the renewal file at the shared ACME root, and
# renew whatever is already due. Idempotent; custom ACME locations are kept.
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/modules/ssl/ssl-utils.sh"

command -v certbot >/dev/null 2>&1 || { echo "Certbot is not installed; nothing to repair."; exit 0; }
command -v nginx >/dev/null 2>&1 || { echo "Nginx is not installed; nothing to repair."; exit 0; }

backup_dir=$(mktemp -d /tmp/spatch_acme.XXXXXX) || exit 1
trap 'rm -rf "$backup_dir"' EXIT
declare -a touched_vhosts=() renewal_files=()
changed=0 skipped=0 broken=0

find_vhost(){
    local domain="$1" pattern conf
    pattern="^[[:space:]]*server_name[[:space:]]+([^;]*[[:space:]])?${domain//./\\.}([[:space:]][^;]*)?;"
    for conf in "$SSL_NGINX_DIR"/*.conf; do
        [ -f "$conf" ] && grep -Eq "$pattern" "$conf" && { printf '%s\n' "$conf"; return 0; }
    done
    return 1
}

for renewal in "$SSL_LE_DIR"/renewal/*.conf; do
    [ -f "$renewal" ] || continue
    grep -Eq '^authenticator[[:space:]]*=[[:space:]]*webroot[[:space:]]*$' "$renewal" || continue
    domain="${renewal##*/}"; domain="${domain%.conf}"
    if [ -e "$SSL_LE_DIR/live/$domain/cert.pem" ] && [ ! -L "$SSL_LE_DIR/live/$domain/cert.pem" ]; then
        warn "$domain: live/cert.pem is not a Certbot symlink; reissue it with SSL Manager"
        broken=$((broken+1)); continue
    fi
    conf=$(find_vhost "$domain") || { skipped=$((skipped+1)); continue; }
    if ! grep -q '# BEGIN ShieldPress HTTP-01' "$conf"; then
        if grep -Eq '^[[:space:]]*location[[:space:]]+[^{]*acme-challenge' "$conf"; then
            warn "$domain: custom ACME location in ${conf##*/}; left unchanged"
            skipped=$((skipped+1)); continue
        fi
        cp -p "$conf" "$backup_dir/${conf##*/}" || exit 1
        if ssl_prepare_http01 "$conf"; then
            touched_vhosts+=("$conf")
        else
            cp -p "$backup_dir/${conf##*/}" "$conf"
            warn "$domain: could not add the HTTP-01 location to ${conf##*/}"
            skipped=$((skipped+1)); continue
        fi
    fi
    renewal_files+=("$renewal")
done

if [ "${#touched_vhosts[@]}" -gt 0 ]; then
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx; then
        for conf in "${touched_vhosts[@]}"; do cp -p "$backup_dir/${conf##*/}" "$conf"; done
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        fail "Nginx rejected the HTTP-01 locations; every vhost was restored. Migration stays pending"
        exit 1
    fi
fi

for renewal in "${renewal_files[@]}"; do
    python3 - "$renewal" "$SSL_ACME_ROOT" <<'PY' && changed=$((changed+1)) || true
import pathlib, re, sys
path, root = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
new = re.sub(r'(?m)^webroot_path\s*=.*$', f'webroot_path = {root},', text)
if '[[webroot_map]]' in new:
    head, tail = new.split('[[webroot_map]]', 1)
    tail = re.sub(r'(?m)^([^\s=\[#][^=\n]*?)\s*=\s*\S.*$', lambda m: f'{m[1]} = {root}', tail)
    new = head + '[[webroot_map]]' + tail
if new == text:
    sys.exit(1)
path.write_text(new)
PY
done

ok "ACME HTTP-01 repair: ${#touched_vhosts[@]} vhost(s) updated, $changed renewal file(s) repointed, $skipped skipped, $broken need reissue"

# Renew what is already due now; certbot leaves certificates with more than 30
# days alone. A remaining failure (DNS, proxy) is retried by the renewal timer.
if [ "$changed" -gt 0 ] || [ "${#touched_vhosts[@]}" -gt 0 ]; then
    if timeout --foreground 900 certbot renew --non-interactive --quiet; then
        ok "Certbot renewed every certificate that was due"
    else
        warn "Some certificates are still not renewable (DNS, proxy or Cloudflare?). Run: certbot renew"
    fi
fi
exit 0
