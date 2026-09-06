#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh"
source "$BASE_DIR/core/update-source.sh"

while true; do
    clear
    CURRENT=$(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo "unknown")
    sp_header "Update Manager" "Current version: $CURRENT"
    sp_menu_grid \
        "1|Update Now|yellow" \
        "2|Update Core Packages|yellow" \
        "0|Back|white"
    sp_prompt CHOICE

    case $CHOICE in
        1)
            echo ""
            echo "Checking latest version on github.com/$SHIELDPRESS_GITHUB_REPO ..."

            REMOTE=$(sp_remote_version || true)

            if [ -z "$REMOTE" ]; then
                echo "[ERROR] Cannot reach GitHub to check for updates."
                echo ""
                read -p "Press Enter..."
                continue
            fi

            echo "Installed : $CURRENT"
            echo "Latest    : $REMOTE"
            echo ""

            if [ "$CURRENT" = "$REMOTE" ]; then
                echo "You are already on the latest version."
                echo ""
                read -p "Press Enter..."
                continue
            fi

            echo "New version available: $CURRENT → $REMOTE"
            echo ""
            read -p "Update now? [Y/n]: " CONFIRM
            CONFIRM="${CONFIRM:-Y}"

            if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                echo "Update cancelled."
                echo ""
                read -p "Press Enter..."
                continue
            fi

            if ! SHIELDPRESS_TARGET_VERSION="$REMOTE" bash "$BASE_DIR/modules/update/updater.sh"; then
                echo ""
                echo "[ERROR] Update failed. Check $LOG_DIR/update.log"
                echo ""
                read -p "Press Enter..."
                continue
            fi
            UPDATED=$(tr -d '[:space:]' < "$BASE_DIR/version.txt" 2>/dev/null || echo "unknown")

            echo ""
            echo "============================================"
            if [ "$UPDATED" = "$REMOTE" ]; then
                echo "  Update complete!"
                echo "  Installed version: $UPDATED"
                echo "  Reloading into the new version..."
                echo "============================================"
                sleep 2
                # Nạp lại toàn bộ tiến trình bằng shieldpress.sh của bản MỚI
                # ($BASE_DIR đã được atomic-switch sang thư mục mới) - người
                # dùng không cần tự gõ lại "exit" rồi "shieldpress".
                exec "$BASE_DIR/shieldpress.sh"
            else
                echo "  Update finished but version.txt is still: $UPDATED"
                echo "  Expected version: $REMOTE"
                echo "  Check $LOG_DIR/update.log"
                echo "============================================"
                echo ""
                read -p "Press Enter..."
            fi
            ;;
        2)
            echo ""
            read -p "Update OS/core packages now? (y/n): " CONFIRM
            if [ "$CONFIRM" = "y" ]; then
                dnf clean all
                dnf makecache --refresh --setopt=skip_if_unavailable=true -y
                # Loại trừ các gói do Upgrade Manager quản lý riêng (backup +
                # rollback + version policy) - nếu không, `dnf update` ở đây
                # có thể tự ý bump nginx/mariadb/postgresql/php lên bản mới
                # nhất trong repo mà bỏ qua toàn bộ cơ chế an toàn đó, kể cả
                # khi versionlock (Upgrade Manager) chưa từng được thiết lập
                # trên máy mới cài.
                dnf update -y --setopt=skip_if_unavailable=true \
                    --exclude='nginx' --exclude='nginx-core' --exclude='nginx-mod-*' \
                    --exclude='php8*-*' \
                    --exclude='mariadb-server' --exclude='mariadb' --exclude='mariadb-common' --exclude='mariadb-backup' --exclude='mariadb-gssapi-server' \
                    --exclude='postgresql*' \
                    --exclude='nodejs' --exclude='nodejs-libs' --exclude='npm'
                systemctl restart nginx mariadb postgresql valkey 2>/dev/null || true
                for svc in php81-php-fpm php82-php-fpm php83-php-fpm php84-php-fpm; do
                    systemctl list-unit-files 2>/dev/null | grep -q "$svc" && systemctl restart "$svc" 2>/dev/null
                done
                echo "[OK] Core server packages updated."
                echo ""
                read -p "Press Enter..."
            fi
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
