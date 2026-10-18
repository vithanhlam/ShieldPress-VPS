#!/bin/bash
# Shared by website and mail installers. No UI/logging globals are changed here.
SSL_LE_DIR="${SSL_LE_DIR:-/etc/letsencrypt}"
SSL_SYSTEMD_DIR="${SSL_SYSTEMD_DIR:-/etc/systemd/system}"
SSL_NGINX_DIR="${SSL_NGINX_DIR:-/etc/nginx/conf.d}"
SSL_ACME_ROOT="${SSL_ACME_ROOT:-/var/www/shieldpress-acme}"

# Serve validation files without involving PHP, Node.js, application rewrites,
# dotfile rules or inherited HTTP basic authentication. Keep this location for
# subsequent unattended webroot renewals.
ssl_prepare_http01(){
    local conf="$1"
    mkdir -p "$SSL_ACME_ROOT/.well-known/acme-challenge" || return 1
    chmod 755 "$SSL_ACME_ROOT" "$SSL_ACME_ROOT/.well-known" \
        "$SSL_ACME_ROOT/.well-known/acme-challenge" || return 1
    if command -v selinuxenabled >/dev/null && selinuxenabled; then
        restorecon -R "$SSL_ACME_ROOT" || return 1
    fi
    python3 - "$conf" "$SSL_ACME_ROOT" <<'PY'
import pathlib, re, sys
conf, root = pathlib.Path(sys.argv[1]), sys.argv[2]
if not root.startswith('/') or any(c in root for c in '\n\r"\\$;{}'):
    sys.exit('Invalid SSL_ACME_ROOT')
text = conf.read_text()
text = re.sub(r'    # BEGIN ShieldPress HTTP-01\n.*?    # END ShieldPress HTTP-01\n',
              '', text, flags=re.S)
if re.search(r'^\s*location\s+[^\n]*acme-challenge', text, re.M):
    sys.exit('Existing ACME location found; reconcile it before installing SSL: ' + str(conf))
block = f'''    # BEGIN ShieldPress HTTP-01
    location ^~ /.well-known/acme-challenge/ {{
        root "{root}";
        default_type text/plain;
        auth_basic off;
        allow all;
        try_files $uri =404;
    }}
    # END ShieldPress HTTP-01
'''
# ShieldPress vhosts have one complete server_name directive per line. Fail
# safely on unsupported custom layouts instead of rewriting arbitrary syntax.
text, count = re.subn(r'(^[ \t]*server_name[ \t]+[^;\n]+;[^\n]*\n)',
                      lambda m: m[0] + block, text, flags=re.M)
if not count:
    sys.exit('No supported server_name directive in ' + str(conf))
conf.write_text(text)
PY
}

ssl_check_http01(){
    local probe token host response code status=0 attempt max_attempts="${SSL_HTTP01_RETRIES:-5}"
    probe=$(mktemp "$SSL_ACME_ROOT/.well-known/acme-challenge/shieldpress-XXXXXXXXXXXX") || return 1
    token="${probe##*/}"
    printf '%s' "$token" > "$probe"
    chmod 644 "$probe" || { rm -f "$probe"; return 1; }
    response=$(mktemp) || { rm -f "$probe"; return 1; }
    for host in "$@"; do
        attempt=1
        while [ "$attempt" -le "$max_attempts" ]; do
            code=$(curl --silent --noproxy '*' --connect-timeout 5 \
                --max-time 20 --max-filesize 4096 --insecure --location --max-redirs 5 --proto '=http,https' \
                --proto-redir '=http,https' --output "$response" --write-out '%{http_code}' \
                "http://$host/.well-known/acme-challenge/$token") || code=000
            if [ "$code" = 200 ] && cmp -s "$probe" "$response"; then
                echo "HTTP-01 ready: $host"
                break
            fi
            if [ "$attempt" -lt "$max_attempts" ]; then
                # systemctl reload returns before every old Nginx worker has
                # stopped accepting connections. Retry while the new vhost
                # configuration takes over, instead of probing stale workers.
                sleep 1
            fi
            ((attempt++))
        done
        if [ "$attempt" -gt "$max_attempts" ]; then
            echo "HTTP-01 preflight failed for $host (HTTP ${code:-000})." >&2
            echo "Check DNS A/AAAA, port 80, proxy forwarding, server-level redirects/access rules and the domain Nginx error log." >&2
            echo "No certificate request was submitted. The check runs from this server; public-IP loopback must also work." >&2
            status=1
            break
        fi
    done
    rm -f "$probe" "$response"
    return "$status"
}

# Certbot can wait indefinitely when an ACME HTTP-01 challenge cannot reach
# the server (wrong DNS, broken IPv6, blocked port 80, or a proxy). Keep SSL
# installation bounded and preserve the useful certbot error output.
run_certbot(){
    local timeout_seconds="${CERTBOT_TIMEOUT_SECONDS:-180}"
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "${timeout_seconds}s" certbot "$@"
        local status=$?
        if [ "$status" -eq 124 ]; then
            echo "Certbot timed out after ${timeout_seconds}s" >&2
            echo "Check DNS (including AAAA), Cloudflare proxy, and inbound port 80."
        fi
        return "$status"
    fi
    certbot "$@"
}


ssl_timer_exists(){
    systemctl list-unit-files --no-legend "$1" 2>/dev/null |
        awk -v unit="$1" '$1 == unit { found=1 } END { exit !found }'
}

ssl_active_timer(){
    local timer
    for timer in certbot-renew.timer certbot.timer snap.certbot.renew.timer shieldpress-certbot-renew.timer; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            printf '%s\n' "$timer"
            return 0
        fi
    done
    return 1
}

ensure_ssl_auto_renew(){
    local timer certbot_bin
    certbot_bin=$(command -v certbot) || return 1
    mkdir -p "$SSL_LE_DIR/renewal-hooks/deploy" || return 1
    # Certbot runs deploy hooks only after a successful renewal. Reload only
    # services consuming this lineage; certonly does not reload mail daemons.
    cat > "$SSL_LE_DIR/renewal-hooks/deploy/50-shieldpress-reload" <<'EOF' || return 1
#!/bin/bash
status=0
if systemctl is-active --quiet nginx; then
    nginx -t && systemctl reload nginx || status=1
fi
if systemctl is-active --quiet postfix && command -v postconf >/dev/null; then
    cert=$(postconf -h smtpd_tls_cert_file)
    if [ "$cert" = "$RENEWED_LINEAGE/fullchain.pem" ]; then
        systemctl reload postfix || status=1
    fi
fi
if systemctl is-active --quiet dovecot && command -v doveconf >/dev/null; then
    cert=$(doveconf -h ssl_cert)
    cert="${cert#<}"
    if [ "$cert" = "$RENEWED_LINEAGE/fullchain.pem" ]; then
        systemctl reload dovecot || status=1
    fi
fi
exit "$status"
EOF
    chmod 755 "$SSL_LE_DIR/renewal-hooks/deploy/50-shieldpress-reload" || return 1

    # RHEL/AlmaLinux packages use certbot-renew.timer; Debian uses certbot.timer.
    for timer in certbot-renew.timer certbot.timer snap.certbot.renew.timer; do
        if ssl_timer_exists "$timer"; then
            systemctl enable --now "$timer" || return 1
            systemctl is-enabled --quiet "$timer" &&
                systemctl is-active --quiet "$timer" || return 1
            if ssl_timer_exists shieldpress-certbot-renew.timer; then
                systemctl disable --now shieldpress-certbot-renew.timer || return 1
            fi
            echo "SSL auto-renew enabled: $timer"
            return 0
        fi
    done

    # Some installations have no packaged scheduler. Use one persistent timer
    # rather than silently reporting success or adding repeated cron entries.
    mkdir -p "$SSL_SYSTEMD_DIR" || return 1
    cat > "$SSL_SYSTEMD_DIR/shieldpress-certbot-renew.service" <<EOF || return 1
[Unit]
Description=ShieldPress certificate renewal
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart="$certbot_bin" renew --non-interactive --quiet
EOF
    cat > "$SSL_SYSTEMD_DIR/shieldpress-certbot-renew.timer" <<'EOF' || return 1
[Unit]
Description=Check ShieldPress certificates twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload &&
        systemctl enable --now shieldpress-certbot-renew.timer &&
        systemctl is-enabled --quiet shieldpress-certbot-renew.timer &&
        systemctl is-active --quiet shieldpress-certbot-renew.timer || return 1
    echo "SSL auto-renew enabled: shieldpress-certbot-renew.timer"
}

ssl_has_lineage(){
    [ -f "$SSL_LE_DIR/renewal/$1.conf" ] &&
        [ -f "$SSL_LE_DIR/live/$1/fullchain.pem" ]
}

ssl_nginx_has_certificate(){
    local domain="$1" conf="$2"
    grep -Eq 'listen[[:space:]]+([^;[:space:]]*:)?443[[:space:]]+ssl' "$conf" &&
        awk -v cert="$SSL_LE_DIR/live/$domain/fullchain.pem;" \
            '$1 == "ssl_certificate" && $2 == cert { found=1 } END { exit !found }' "$conf" &&
        awk -v key="$SSL_LE_DIR/live/$domain/privkey.pem;" \
            '$1 == "ssl_certificate_key" && $2 == key { found=1 } END { exit !found }' "$conf"
}

ssl_migrate_standalone(){
    local domain="$1"
    if grep -Eq '^authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$SSL_LE_DIR/renewal/$domain.conf"; then
        # reconfigure tests against staging and saves the new authenticator
        # even when the production certificate is not due yet (Certbot >=2.3).
        run_certbot reconfigure --cert-name "$domain" --authenticator nginx --non-interactive || return 1
    fi
}

# Keep the current certificate/config while obtaining its replacement. A valid
# existing certificate is reused; Certbot renews only when due.
ssl_install_nginx(){
    local domain="$1" conf="$2" backup status=0
    shift 2
    local -a hosts=()
    local previous='' argument
    for argument in "$@"; do
        if [ "$previous" = '-d' ] || [ "$previous" = '--domains' ]; then
            local -a names=()
            IFS=, read -r -a names <<< "$argument"
            hosts+=("${names[@]}")
        fi
        previous="$argument"
    done
    [ "${#hosts[@]}" -gt 0 ] || hosts=("$domain")
    nginx -t || return 1
    backup=$(mktemp) || return 1
    cp -p "$conf" "$backup" || { rm -f "$backup"; return 1; }
    if ! ssl_prepare_http01 "$conf" || ! nginx -t || ! systemctl reload nginx ||
        ! ssl_check_http01 "${hosts[@]}"; then
        status=1
    elif run_certbot run --authenticator webroot --webroot-path "$SSL_ACME_ROOT" \
        --installer nginx --cert-name "$domain" --keep-until-expiring \
        --renew-with-new-domains --non-interactive --agree-tos --redirect "$@"; then
        if ! ssl_nginx_has_certificate "$domain" "$conf" || ! nginx -t || ! systemctl reload nginx; then
            status=1
        fi
    else
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        if ! cp -p "$backup" "$conf" || ! nginx -t || ! systemctl reload nginx; then
            echo "Nginx rollback failed; original configuration retained at $backup" >&2
            return 1
        fi
        echo "SSL installation failed; previous Nginx configuration restored." >&2
    fi
    rm -f "$backup"
    return "$status"
}

ssl_renew_nginx(){
    local domain="$1" conf="$2" backup status=0
    shift 2
    nginx -t || return 1
    backup=$(mktemp) || return 1
    cp -p "$conf" "$backup" || { rm -f "$backup"; return 1; }
    if ssl_migrate_standalone "$domain" &&
        run_certbot renew --cert-name "$domain" --non-interactive "$@" &&
        run_certbot install --nginx --cert-name "$domain" --non-interactive --redirect &&
        ssl_nginx_has_certificate "$domain" "$conf" &&
        nginx -t && systemctl reload nginx; then
        status=0
    else
        status=$?
        cp -p "$backup" "$conf"
        nginx -t && systemctl reload nginx
        echo "SSL renewal/install failed; previous Nginx configuration restored." >&2
    fi
    rm -f "$backup"
    return "$status"
}

ssl_install_mail(){
    local domain="$1" email="$2"
    shift 2
    nginx -t || return 1
    if ssl_has_lineage "$domain"; then
        ssl_migrate_standalone "$domain" || return 1
        run_certbot renew --cert-name "$domain" --non-interactive "$@" || return 1
    else
        run_certbot certonly --nginx --cert-name "$domain" --keep-until-expiring \
            --agree-tos --non-interactive -d "$domain" --email "$email" "$@" || return 1
    fi
    ensure_ssl_auto_renew
}
