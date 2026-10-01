#!/bin/bash
# Shared by website and mail installers. No UI/logging globals are changed here.
SSL_LE_DIR="${SSL_LE_DIR:-/etc/letsencrypt}"
SSL_SYSTEMD_DIR="${SSL_SYSTEMD_DIR:-/etc/systemd/system}"
SSL_NGINX_DIR="${SSL_NGINX_DIR:-/etc/nginx/conf.d}"

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
    nginx -t || return 1
    backup=$(mktemp) || return 1
    cp -p "$conf" "$backup" || { rm -f "$backup"; return 1; }
    if run_certbot --nginx --cert-name "$domain" --keep-until-expiring \
        --renew-with-new-domains --non-interactive --agree-tos --redirect "$@"; then
        if ! ssl_nginx_has_certificate "$domain" "$conf" || ! nginx -t || ! systemctl reload nginx; then
            status=1
        fi
    else
        status=$?
    fi
    if [ "$status" -ne 0 ]; then
        cp -p "$backup" "$conf"
        nginx -t && systemctl reload nginx
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
