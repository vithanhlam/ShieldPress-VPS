#!/bin/bash
# Isolated test of modules/ssl/repair-acme-renewal.sh (fake nginx/certbot/systemctl).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)/shieldpress"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/le/renewal" "$W/le/live/a.test" "$W/le/live/b.test" "$W/nginx" "$W/acme"
for c in nginx systemctl certbot; do printf '#!/bin/sh\necho "$0 $*" >> "%s/calls"\nexit 0\n' "$W" > "$W/bin/$c"; done
chmod +x "$W/bin/"*
vhost(){ printf 'server {\n    listen 80;\n    server_name %s;\n    location ~* /(?:\\.|wp-config\\.php) { deny all; }\n}\n' "$1"; }
vhost "a.test www.a.test" > "$W/nginx/a.conf"
{ vhost "b.test"; } | sed 's#listen 80;#listen 80;\n    location ^~ /.well-known/acme-challenge/ { return 403; }#' > "$W/nginx/b.conf"
printf 'authenticator = webroot\nwebroot_path = /usr/local/lsws/a/html,\n[[webroot_map]]\na.test = /usr/local/lsws/a/html\nwww.a.test = /usr/local/lsws/a/html\n' > "$W/le/renewal/a.test.conf"
printf 'authenticator = webroot\nwebroot_path = /old,\n' > "$W/le/renewal/b.test.conf"
cp "$W/nginx/b.conf" "$W/b.before"
run(){ PATH="$W/bin:$PATH" BASE_DIR="$ROOT" SSL_LE_DIR="$W/le" SSL_NGINX_DIR="$W/nginx" SSL_ACME_ROOT="$W/acme" \
    bash "$ROOT/modules/ssl/repair-acme-renewal.sh"; }
fail=0; chk(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
run >"$W/out1" 2>&1; chk "first run exits 0" "[ \$? -eq 0 ]"
chk "ACME block added to a.conf" "[ \$(grep -c 'BEGIN ShieldPress HTTP-01' $W/nginx/a.conf) -eq 1 ]"
chk "custom ACME location in b.conf untouched" "cmp -s $W/nginx/b.conf $W/b.before"
chk "webroot_path repointed" "grep -Fq 'webroot_path = $W/acme,' $W/le/renewal/a.test.conf"
chk "webroot_map repointed" "grep -Fq 'www.a.test = $W/acme' $W/le/renewal/a.test.conf"
chk "stale path gone" "! grep -q lsws $W/le/renewal/a.test.conf"
chk "certbot renew ran" "grep -q 'certbot renew' $W/calls"
cp "$W/nginx/a.conf" "$W/a.once"; cp "$W/le/renewal/a.test.conf" "$W/r.once"
run >"$W/out2" 2>&1
chk "second run is idempotent" "cmp -s $W/nginx/a.conf $W/a.once && cmp -s $W/le/renewal/a.test.conf $W/r.once"
exit $fail
