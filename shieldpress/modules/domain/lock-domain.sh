#!/bin/bash

source /opt/shieldpress/modules/domain/helpers.sh

LOG_FILE="$LOG_DIR/domain-lock.log"
mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
NGINX_DISABLED="${NGINX_CONF}.disabled"
LOCK_HTML="$ROOT/.shieldpress_suspended.html"

# ------------------------------------------------
# TẠO TRANG THÔNG BÁO KHÓA
# ------------------------------------------------

create_lock_page(){
    cat > "$LOCK_HTML" << HTMLEOF
<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tên miền tạm thời bị khóa</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    font-family: 'Segoe UI', Arial, sans-serif;
    background: #0f172a;
    color: #e2e8f0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
  }

  .card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 16px;
    padding: 48px 40px;
    max-width: 560px;
    width: 100%;
    text-align: center;
    box-shadow: 0 25px 50px rgba(0,0,0,0.5);
  }

  .icon {
    width: 72px;
    height: 72px;
    background: linear-gradient(135deg, #f97316, #ef4444);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    margin: 0 auto 24px;
    font-size: 32px;
  }

  h1 {
    font-size: 22px;
    font-weight: 700;
    color: #f1f5f9;
    margin-bottom: 12px;
    line-height: 1.4;
  }

  .domain {
    display: inline-block;
    background: #0f172a;
    border: 1px solid #475569;
    border-radius: 8px;
    padding: 6px 16px;
    font-size: 15px;
    color: #f97316;
    font-weight: 600;
    margin-bottom: 20px;
    word-break: break-all;
  }

  p {
    color: #94a3b8;
    font-size: 15px;
    line-height: 1.7;
    margin-bottom: 12px;
  }

  .divider {
    height: 1px;
    background: #334155;
    margin: 28px 0;
  }

  .contact-box {
    background: #0f172a;
    border: 1px solid #334155;
    border-radius: 10px;
    padding: 20px;
    text-align: left;
  }

  .contact-box h3 {
    font-size: 13px;
    font-weight: 600;
    color: #64748b;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 10px;
  }

  .contact-item {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 14px;
    color: #cbd5e1;
    padding: 6px 0;
  }

  .contact-item span.label {
    color: #64748b;
    min-width: 70px;
  }

  .badge {
    display: inline-block;
    background: #1e3a5f;
    color: #60a5fa;
    font-size: 11px;
    padding: 3px 10px;
    border-radius: 999px;
    margin-top: 24px;
    font-weight: 500;
  }

  .powered {
    margin-top: 32px;
    font-size: 12px;
    color: #475569;
  }

  .powered a {
    color: #64748b;
    text-decoration: none;
  }
</style>
</head>
<body>
<div class="card">

  <div class="icon">🔒</div>

  <h1>Tên miền tạm thời bị khóa</h1>

  <div class="domain">$SELECTED_DOMAIN</div>

  <p>
    Tên miền này đang bị tạm khóa theo yêu cầu của quản trị viên.<br>
    Dịch vụ sẽ được khôi phục sau khi vấn đề được giải quyết.
  </p>

  <p>
    Nếu bạn cho rằng đây là lỗi, vui lòng liên hệ
    quản trị viên website để được hỗ trợ.
  </p>

  <div class="divider"></div>

  <div class="contact-box">
    <h3>📞 Liên hệ quản trị viên</h3>
    <div class="contact-item">
      <span class="label">Email</span>
      <span>admin@$SELECTED_DOMAIN</span>
    </div>
    <div class="contact-item">
      <span class="label">Website</span>
      <span>$SELECTED_DOMAIN</span>
    </div>
  </div>

  <div class="badge">⏱ Tạm khóa lúc: $(date '+%d/%m/%Y %H:%M')</div>

  <div class="powered">
    Powered by <a href="https://shieldpress.net" target="_blank">ShieldPress VPS</a>
  </div>

</div>
</body>
</html>
HTMLEOF
    chown "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$LOCK_HTML" 2>/dev/null
}

# ------------------------------------------------
# TẠO NGINX CONFIG TẠM KHÓA
# ------------------------------------------------

create_lock_nginx(){
    cat > "${NGINX_CONF}.lock" << NGEOF
server {
    listen 80;
    listen [::]:80;
    server_name $SELECTED_DOMAIN www.$SELECTED_DOMAIN;

    root $ROOT;
    index .shieldpress_suspended.html;

    location / {
        try_files /.shieldpress_suspended.html =503;
    }

    # Chặn tất cả truy cập PHP và file nhạy cảm
    location ~ \.php\$ { deny all; }
    location ~ /\.      { deny all; }
}
NGEOF
}

# ------------------------------------------------
# LOCK DOMAIN
# ------------------------------------------------

lock_domain(){
    if [ -f "${NGINX_CONF}.lock" ]; then
        echo "Domain already locked."
        return 1
    fi

    if [ ! -f "$NGINX_CONF" ]; then
        echo "Nginx config not found: $NGINX_CONF"
        return 1
    fi

    # Tạo trang thông báo
    create_lock_page

    # Backup nginx config
    cp "$NGINX_CONF" "${NGINX_CONF}.prelocked"

    # Tạo nginx lock config
    create_lock_nginx

    # Disable config thực, dùng lock config
    mv "$NGINX_CONF" "${NGINX_CONF}.disabled"
    cp "${NGINX_CONF}.lock" "$NGINX_CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log "Domain $SELECTED_DOMAIN locked"
        echo "[OK] Domain locked: $SELECTED_DOMAIN"
        echo "     Lock page: http://$SELECTED_DOMAIN"
    else
        # Rollback nếu lỗi
        mv "${NGINX_CONF}.disabled" "$NGINX_CONF"
        rm -f "${NGINX_CONF}.lock"
        echo "[FAIL] Nginx config error, lock cancelled"
        nginx -t
    fi
}

# ------------------------------------------------
# UNLOCK DOMAIN
# ------------------------------------------------

unlock_domain(){
    if [ ! -f "${NGINX_CONF}.disabled" ]; then
        echo "Domain is not locked."
        return 1
    fi

    # Restore nginx config gốc
    mv "${NGINX_CONF}.disabled" "$NGINX_CONF"
    rm -f "${NGINX_CONF}.lock"
    rm -f "${NGINX_CONF}.prelocked"

    # Xóa trang lock
    rm -f "$LOCK_HTML"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log "Domain $SELECTED_DOMAIN unlocked"
        echo "[OK] Domain unlocked: $SELECTED_DOMAIN"
    else
        echo "[FAIL] Nginx config error after unlock:"
        nginx -t
    fi
}

# ------------------------------------------------
# KIỂM TRA STATUS
# ------------------------------------------------

if [ -f "${NGINX_CONF}.disabled" ]; then
    STATUS="🔒 LOCKED"
    STATUS_COLOR="\e[31m"
else
    STATUS="✅ ACTIVE"
    STATUS_COLOR="\e[32m"
fi

echo ""
echo "=================================="
echo "Domain : $SELECTED_DOMAIN"
echo -e "Status : ${STATUS_COLOR}${STATUS}\e[0m"
echo "=================================="
echo ""
echo "1) Lock Domain"
echo "2) Unlock Domain"
echo "0) Back"
echo "----------------------------------"
read -p "Select: " OPTION

case $OPTION in
    1) lock_domain;   pause ;;
    2) unlock_domain; pause ;;
    0) exit ;;
    *) echo "Invalid option"; sleep 1 ;;
esac
