#!/bin/bash
# Install the explicit numeric update shortcut on new and existing servers.
sp_install_update_shortcut(){
    local shortcut
    for shortcut in /usr/bin/2 /usr/local/bin/2; do
        cat > "$shortcut" <<'SHORTCUT_EOF' || return 1
#!/bin/bash
exec /opt/shieldpress/shieldpress.sh update "$@"
SHORTCUT_EOF
        chmod 755 "$shortcut" || return 1
    done
    if command -v restorecon >/dev/null 2>&1; then
        restorecon /usr/bin/2 /usr/local/bin/2 || return 1
    fi
}
