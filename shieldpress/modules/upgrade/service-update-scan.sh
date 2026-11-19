#!/bin/bash
# Daily read-only check for Nginx/PHP/MariaDB/PostgreSQL same-branch updates.
# The result is cached for the root login banner; packages are never changed.
SP_SERVICE_SCAN_UNIT_DIR="${SP_SERVICE_SCAN_UNIT_DIR:-/etc/systemd/system}"

sp_install_service_update_scan(){
    local base="${BASE_DIR:-/opt/shieldpress}"
    mkdir -p "$SP_SERVICE_SCAN_UNIT_DIR" || return 1
    cat > "$SP_SERVICE_SCAN_UNIT_DIR/shieldpress-service-updates.service" <<EOF || return 1
[Unit]
Description=ShieldPress service update and advisory check (read-only)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1h
ExecStart=/usr/bin/python3 -I $base/modules/upgrade/service-updates.py --scan
EOF
    cat > "$SP_SERVICE_SCAN_UNIT_DIR/shieldpress-service-updates.timer" <<'EOF' || return 1
[Unit]
Description=Daily ShieldPress service update check

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload &&
        systemctl enable --now shieldpress-service-updates.timer &&
        systemctl is-active --quiet shieldpress-service-updates.timer || return 1
    # First check runs in the background so installs and updates are not delayed.
    systemctl start --no-block shieldpress-service-updates.service 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --install) sp_install_service_update_scan ;;
        *) echo "Usage: $0 --install"; exit 2 ;;
    esac
fi
