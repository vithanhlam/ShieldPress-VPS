#!/bin/bash
# Install the numeric shell shortcuts on new and existing servers:
#   2 update   3 cache   4 domain   5 ssl   6 backup
# (1, the admin menu, is installed by install.sh and the updater.)
# The function name is kept because older updaters and patches call it.
sp_install_update_shortcut(){
    local entry num action dir shortcut
    for entry in 2:update 3:cache 4:domain 5:ssl 6:backup; do
        num="${entry%%:*}"; action="${entry#*:}"
        for dir in /usr/bin /usr/local/bin; do
            shortcut="$dir/$num"
            cat > "$shortcut" <<SHORTCUT_EOF || return 1
#!/bin/bash
exec /opt/shieldpress/shieldpress.sh $action "\$@"
SHORTCUT_EOF
            chmod 755 "$shortcut" || return 1
            if command -v restorecon >/dev/null 2>&1; then
                restorecon "$shortcut" || return 1
            fi
        done
    done
}
