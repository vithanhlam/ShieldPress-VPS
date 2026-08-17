#!/bin/bash
# ============================================================
#  Auto-Reload MariaDB
#  Monitor and automatically restart MariaDB if it crashes
#  Support: AlmaLinux 8.x / 9.x, RHEL, CentOS Stream
# ============================================================

set -e

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/auto-reload-db.log"
LOCK_FILE="/tmp/auto-reload-db.lock"
SERVICE_FILE="/etc/systemd/system/shieldpress-auto-reload-db.service"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok()     { echo -e "${GREEN}[✔]${NC} $1"; log "[OK] $1"; }
fail()   { echo -e "${RED}[✘]${NC} $1"; log "[FAILED] $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; log "[WARN] $1"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Kiểm tra root ────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    fail "Vui lòng chạy script với quyền root: sudo bash auto-reload-db.sh"
    exit 1
fi

mkdir -p "$LOG_DIR"

# ── Thêm menu ────────────────────────────────────────────────

show_menu(){
    clear
    echo ""
    echo "=============================================="
    echo "     AUTO-RELOAD MariaDB Setup"
    echo "=============================================="
    echo ""
    echo "  1) Enable Auto-Restart (Install Service)"
    echo "  2) Disable Auto-Restart (Remove Service)"
    echo "  3) Check Service Status"
    echo "  4) View Auto-Restart Log"
    echo "  5) Start Monitoring Now (Foreground)"
    echo ""
    echo "  0) Back"
    echo "----------------------------------------------"
    read -p "Select: " choice
    echo ""
}

# ── Monitor & Auto-Restart ──────────────────────────────────
monitor_mariadb(){
    header "MariaDB Auto-Restart Monitor Started"
    log "Monitor process started (PID: $$)"
    ok "Monitoring MariaDB... (Press Ctrl+C to stop)"
    echo ""

    while true; do
        if ! systemctl is-active --quiet mariadb; then
            warn "MariaDB down! Restarting..."
            log "MariaDB detected as stopped, attempting restart..."

            systemctl start mariadb 2>/dev/null
            sleep 2

            if systemctl is-active --quiet mariadb; then
                ok "MariaDB restarted successfully!"
                log "MariaDB successfully restarted"
            else
                fail "Failed to restart MariaDB, retrying in 30 seconds..."
                log "Failed to restart MariaDB, will retry"
                sleep 30
            fi
        else
            echo -ne "\r[$(date '+%H:%M:%S')] MariaDB is running ✓"
        fi

        sleep 10
    done
}

# ── Tạo systemd service ─────────────────────────────────────
create_service(){
    header "Creating Auto-Restart Service"

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=ShieldPress Auto-Reload MariaDB Service
After=mariadb.service
PartOf=mariadb.service

[Service]
Type=simple
ExecStart=/opt/shieldpress/modules/tools/auto-reload-db.sh --monitor
Restart=always
RestartSec=5
StandardOutput=append:/var/shieldpress/logs/auto-reload-db.log
StandardError=append:/var/shieldpress/logs/auto-reload-db.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shieldpress-auto-reload-db.service

    ok "Service created and enabled"
    log "Service file created: $SERVICE_FILE"

    echo ""
    read -p "Start service now? (y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl start shieldpress-auto-reload-db.service
        sleep 1
        if systemctl is-active --quiet shieldpress-auto-reload-db.service; then
            ok "Service started successfully!"
            log "Auto-reload service started"
        else
            fail "Failed to start service"
        fi
    fi
}

# ── Xóa systemd service ──────────────────────────────────────
remove_service(){
    header "Removing Auto-Restart Service"

    if [ ! -f "$SERVICE_FILE" ]; then
        warn "Service file not found"
        return
    fi

    systemctl stop shieldpress-auto-reload-db.service 2>/dev/null || true
    systemctl disable shieldpress-auto-reload-db.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    ok "Service removed and disabled"
    log "Auto-reload service removed"
}

# ── Kiểm tra trạng thái service ──────────────────────────────
check_status(){
    header "Auto-Restart Service Status"

    if [ ! -f "$SERVICE_FILE" ]; then
        echo "Service file: ${RED}NOT INSTALLED${NC}"
        echo ""
        return
    fi

    echo "Service file: ${GREEN}INSTALLED${NC}"
    echo ""

    if systemctl is-enabled --quiet shieldpress-auto-reload-db.service; then
        echo "Auto-start: ${GREEN}ENABLED${NC}"
    else
        echo "Auto-start: ${YELLOW}DISABLED${NC}"
    fi

    STATE=$(systemctl is-active shieldpress-auto-reload-db.service 2>/dev/null || echo "inactive")
    if [ "$STATE" = "active" ]; then
        echo "Status: ${GREEN}RUNNING${NC} (✓)"
    else
        echo "Status: ${RED}STOPPED${NC}"
    fi

    echo ""
    echo "Recent activity:"
    tail -n 10 "$LOG_FILE" 2>/dev/null || echo "No logs yet"
}

# ── Xem logs ────────────────────────────────────────────────
view_logs(){
    header "Auto-Restart Log"
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        fail "Log file not found"
    fi
}

# ── Argument handling ────────────────────────────────────────
if [ "$1" = "--monitor" ]; then
    monitor_mariadb
    exit 0
fi

# ── Main menu ────────────────────────────────────────────────
while true; do
    show_menu

    case $choice in
        1) create_service ;;
        2) remove_service ;;
        3) check_status ;;
        4) view_logs ;;
        5) monitor_mariadb ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    [ "$choice" != "4" ] && [ "$choice" != "5" ] && echo "" && read -p "Press Enter..."
done

clear
