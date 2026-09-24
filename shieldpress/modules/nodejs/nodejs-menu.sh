#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAIN_MODULE="$BASE_DIR/modules/domain"
DOMAINS_ROOT="/home/domains"

source "$DOMAIN_MODULE/helpers.sh"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

confirm_action(){
    local prompt="$1"
    echo -e "${RED}WARNING: ${prompt}${RESET}"
    read -p "Continue? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-y}"
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return 1; }
}

# Start Next.js with an explicit CLI port. This avoids package.json scripts
# such as `next start -p 3000` overriding the domain's configured port.
start_pm2_next_app(){
    local pm2_name="$1"
    local next_bin="./node_modules/.bin/next"
    [ -x "$next_bin" ] || next_bin="$(command -v next 2>/dev/null || true)"
    [ -n "$next_bin" ] || return 1
    # Persist the selected launcher in PM2's environment.  A domain can be
    # created before its source is uploaded, in which case its placeholder
    # app.js is initially started.  This marker lets Start/Deploy replace that
    # legacy process once a Next.js package is present instead of merely
    # restarting app.js forever.
    run_pm2 "$pm2_name" SHIELDPRESS_START_MODE=next NEXT_DIST_DIR=.next-release PORT="$NODE_APP_PORT" NODE_ENV=production pm2 start "$next_bin" \
        --name "$pm2_name" --update-env -- start --port "$NODE_APP_PORT" \
        && pm2_persist_startup "$pm2_name"
}

is_nextjs_app(){
    [ -f "$DOMAIN_PATH/public_html/package.json" ] || return 1
    grep -Eq '"next"[[:space:]]*:' "$DOMAIN_PATH/public_html/package.json"
}

# Candidate builds are safe only when the app's Next config uses this
# environment variable for `distDir`. Other Next apps keep the established
# .next build path and rollback behavior.
next_app_supports_dist_dir(){
    local app_root="$DOMAIN_PATH/public_html"
    local config
    for config in "$app_root"/next.config.js "$app_root"/next.config.mjs "$app_root"/next.config.ts "$app_root"/next.config.cjs; do
        [ -f "$config" ] || continue
        grep -q 'NEXT_DIST_DIR' "$config" && return 0
    done
    return 1
}

pm2_app_start_mode(){
    local user="$1"
    local pm2_name="$2"
    run_pm2 "$user" pm2 jlist 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    for app in json.load(sys.stdin):
        if app.get("name") != name:
            continue
        env = app.get("pm2_env", {})
        value = env.get("SHIELDPRESS_START_MODE")
        if value is None:
            value = env.get("env", {}).get("SHIELDPRESS_START_MODE", "")
        print(value)
        break
except (json.JSONDecodeError, TypeError):
    pass
' "$pm2_name"
}

restart_pm2_app_with_config(){
    local pm2_name="$1"
    local next_dist_dir="${2:-.next-release}"
    # Do not let a PM2 process created for the temporary app.js survive after
    # a Next.js project has been uploaded.  Restarting preserves PM2's old
    # executable, so this is the one intentional replacement path.
    if is_nextjs_app && [ "$(pm2_app_start_mode "$pm2_name" "$pm2_name")" != "next" ]; then
        warn "Replacing legacy PM2 launcher with Next.js for $pm2_name"
        run_pm2 "$pm2_name" pm2 delete "$pm2_name" || return 1
        start_pm2_next_app "$pm2_name" || return 1
        return 0
    fi
    # Keep the existing PM2 process and its id. The application receives the
    # new environment on restart; a fresh start is only needed when the
    # process does not exist yet.
    if is_nextjs_app; then
        # PM2 reload keeps cluster-mode Next apps serving while workers rotate.
        # PM2 may fall back to restart for fork-mode applications.
        run_pm2 "$pm2_name" NEXT_DIST_DIR="$next_dist_dir" PORT="$NODE_APP_PORT" NODE_ENV=production \
            pm2 reload "$pm2_name" --update-env || return 1
    else
        run_pm2 "$pm2_name" PORT="$NODE_APP_PORT" NODE_ENV=production \
            pm2 restart "$pm2_name" --update-env || return 1
    fi
    run_pm2 "$pm2_name" pm2 save || true
}

ensure_pm2(){
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "PM2 not installed. Installing..."
        npm install -g pm2 || { fail "Failed to install PM2"; return 1; }
        ok "PM2 installed"
    fi
    return 0
}

# Every Node.js domain has its own Linux user (same name as $CLEAN_DOMAIN,
# see domain/helpers.sh:create_linux_user). Run each domain's PM2 daemon and
# app process under that user instead of root: PM2 keys its daemon/socket off
# $HOME (runuser sets $HOME from the target user's passwd entry), so this
# gives every domain its own isolated PM2 instance for free - one domain's
# app can no longer reach another domain's process, and a compromised app
# runs as an unprivileged user instead of root.
run_pm2(){
    local user="$1"; shift
    local home="/home/domains/$user"
    local pm2_home="$home/.pm2"
    local npm_cache="$home/.npm"

    # A PM2 daemon is not re-owned by `runuser`: if an older deployment
    # created this PM2_HOME as root, every later PM2 command silently talks to
    # that root daemon and starts the app as root.  Tear down only this
    # domain's stale daemon so the next invocation creates it as the domain
    # account.  This also prevents root Next.js processes from writing .next.
    local daemon_pid daemon_owner
    daemon_pid=$(cat "$pm2_home/pm2.pid" 2>/dev/null || true)
    if [[ "$daemon_pid" =~ ^[0-9]+$ ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        daemon_owner=$(ps -o user= -p "$daemon_pid" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$daemon_owner" ] && [ "$daemon_owner" != "$user" ]; then
            warn "Replacing PM2 daemon owned by $daemon_owner for $user"
            HOME="$home" PM2_HOME="$pm2_home" pm2 kill >/dev/null 2>&1 || kill "$daemon_pid" 2>/dev/null || true
            sleep 1
        fi
    fi

    # PM2 uses HOME/PM2_HOME for its daemon, sockets, logs and dump file.
    # Prepare these paths before every invocation so a first run can never
    # fall back to /root/.pm2.
    mkdir -p "$pm2_home"
    chown -R "$user:$user" "$pm2_home"
    if [ ! -s "$pm2_home/module_conf.json" ]; then
        printf '{}' > "$pm2_home/module_conf.json"
        chown "$user:$user" "$pm2_home/module_conf.json"
    fi
    # Keep npm's cache explicit as well. Without this, npm can discover a
    # root-owned cache left by an older root PM2/npm deployment and fail with
    # EACCES before it can even write its log.
    runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" PM2_HOME="$pm2_home" \
        NPM_CONFIG_CACHE="$npm_cache" "$@"
}

# Print one PM2 process as fields suitable for the domain overview:
# id|status|restarts|pid|uptime|memory.  The working-directory check prevents
# an unrelated PM2 app with the same name from being reported for this domain.
pm2_app_row(){
    local user="$1"
    local pm2_name="$2"
    local app_root="$3"
    run_pm2 "$user" pm2 jlist 2>/dev/null | python3 -c '
import json, os, sys
name, root = sys.argv[1:]
try:
    for app in json.load(sys.stdin):
        env = app.get("pm2_env", {})
        if app.get("name") == name and os.path.realpath(env.get("pm_cwd", "")) == os.path.realpath(root):
            print("|".join(str(x) for x in (
                app.get("pm_id", "-"), env.get("status", "unknown"),
                env.get("restart_time", 0), app.get("pid", "-"),
                env.get("pm_uptime", 0), app.get("monit", {}).get("memory", 0))))
            break
except (json.JSONDecodeError, TypeError):
    pass
' "$pm2_name" "$app_root"
}

# Older ShieldPress releases placed every app in root's shared PM2 daemon.
# Do not invoke pm2 here unless that daemon is already alive: a status screen
# must not create a new /root/.pm2 daemon just to inspect it.
root_pm2_app_row(){
    local pm2_name="$1"
    local app_root="$2"
    local daemon_pid
    daemon_pid=$(cat /root/.pm2/pm2.pid 2>/dev/null || true)
    [[ "$daemon_pid" =~ ^[0-9]+$ ]] && kill -0 "$daemon_pid" 2>/dev/null || return 0
    pm2 jlist 2>/dev/null | python3 -c '
import json, os, sys
name, root = sys.argv[1:]
try:
    for app in json.load(sys.stdin):
        env = app.get("pm2_env", {})
        if app.get("name") == name and os.path.realpath(env.get("pm_cwd", "")) == os.path.realpath(root):
            print("|".join(str(x) for x in (
                app.get("pm_id", "-"), env.get("status", "unknown"),
                env.get("restart_time", 0), app.get("pid", "-"),
                env.get("pm_uptime", 0), app.get("monit", {}).get("memory", 0))))
            break
except (json.JSONDecodeError, TypeError):
    pass
' "$pm2_name" "$app_root"
}

format_pm2_uptime(){
    local started="$1"
    [[ "$started" =~ ^[0-9]+$ ]] && [ "$started" -gt 0 ] || { echo "-"; return; }
    local elapsed=$(( $(date +%s) - started / 1000 ))
    [ "$elapsed" -lt 0 ] && elapsed=0
    printf '%dd %02dh %02dm' $((elapsed / 86400)) $((elapsed % 86400 / 3600)) $((elapsed % 3600 / 60))
}

format_pm2_memory(){
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || { echo "-"; return; }
    printf '%dM' $((bytes / 1024 / 1024))
}

port_is_listening(){
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ss -ltn 2>/dev/null | grep -qE "(:|\.)${port}[[:space:]]"
}

prepare_root_pm2_for_action(){
    local root_row
    root_row=$(root_pm2_app_row "$CLEAN_DOMAIN" "$DOMAIN_PATH/public_html")
    [ -n "$root_row" ] || return 0

    warn "This domain is still running in root's legacy PM2 daemon (PM2 ID ${root_row%%|*})."
    warn "This action cannot safely use the per-domain PM2 app while root owns port $NODE_APP_PORT."
    echo "The app will be migrated to user $CLEAN_DOMAIN first; it may briefly restart."
    confirm_action "Migrate root PM2 for $DOMAIN before continuing?" || return 1
    command -v python3 >/dev/null 2>&1 || { fail "python3 is required for PM2 migration"; return 1; }
    python3 "$BASE_DIR/modules/nodejs/migrate-root-pm2.py" \
        "$CLEAN_DOMAIN" "$NODE_APP_PORT" "$DOMAIN" --yes || {
            fail "Root PM2 migration failed. Deploy was not started; see the migration output above."
            return 1
        }
}

# Early Node.js releases used the display domain as the PM2 app name (for
# example, `example.com`).  The per-domain manager now consistently uses the
# safe Linux-user name (`example_com`).  Recognise only the exact legacy name
# in this domain's own PM2 daemon and exact project root, then rename it
# before port ownership is checked.  Matching the root prevents a same-named
# app belonging to another domain from ever being adopted.
migrate_legacy_domain_pm2_name(){
    local app_root="$DOMAIN_PATH/public_html"
    local legacy_name="$DOMAIN"
    local legacy_row current_row

    [ "$legacy_name" != "$CLEAN_DOMAIN" ] || return 0

    current_row=$(pm2_app_row "$CLEAN_DOMAIN" "$CLEAN_DOMAIN" "$app_root")
    [ -n "$current_row" ] && return 0

    legacy_row=$(pm2_app_row "$CLEAN_DOMAIN" "$legacy_name" "$app_root")
    [ -n "$legacy_row" ] || return 0

    warn "Migrating legacy PM2 app name '$legacy_name' to '$CLEAN_DOMAIN'"
    run_pm2 "$CLEAN_DOMAIN" PORT="$NODE_APP_PORT" NODE_ENV=production \
        pm2 restart "$legacy_name" --name "$CLEAN_DOMAIN" --update-env || {
            fail "Could not migrate legacy PM2 app name '$legacy_name'"
            return 1
        }
    run_pm2 "$CLEAN_DOMAIN" pm2 save >/dev/null 2>&1 || true
    ok "Migrated PM2 app name to $CLEAN_DOMAIN"
}

selected_pm2_owns_port(){
    local port="$1"
    local row pid status listener_pid parent_pid hops
    row=$(pm2_app_row "$CLEAN_DOMAIN" "$CLEAN_DOMAIN" "$DOMAIN_PATH/public_html")
    [ -n "$row" ] || return 1
    IFS='|' read -r _ status _ pid _ _ <<< "$row"
    [ "$status" = "online" ] && [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    # `pm2 start npm -- start` records npm's PID, while Node is its child and
    # owns the HTTP socket. Walk listener parents so this normal topology is
    # accepted without treating an unrelated service as our application.
    while read -r listener_pid; do
        [ -n "$listener_pid" ] || continue
        parent_pid="$listener_pid"
        for ((hops = 0; hops < 16; hops++)); do
            [ "$parent_pid" = "$pid" ] && return 0
            parent_pid=$(ps -o ppid= -p "$parent_pid" 2>/dev/null | tr -d '[:space:]')
            [[ "$parent_pid" =~ ^[0-9]+$ ]] || break
        done
    done < <(ss -ltnp 2>/dev/null | grep -E "(:|\.)${port}[[:space:]]" | grep -oE 'pid=[0-9]+' | cut -d= -f2)
    return 1
}

# A process on a configured port is only safe to reuse when it is the
# selected domain's online PM2 process. Never guess and kill an unrelated
# service (including another root PM2 application).
assert_node_port_available(){
    local port="${1:-$NODE_APP_PORT}"
    port_is_listening "$port" || return 0
    selected_pm2_owns_port "$port" && return 0
    fail "Port $port is already listening, but not from PM2 app $CLEAN_DOMAIN."
    ss -ltnp 2>/dev/null | grep -E "(:|\.)${port}[[:space:]]" || true
    warn "No process was stopped. Select the owning app, migrate its root PM2 entry, or choose another port."
    return 1
}

# Next 16 defaults to Turbopack for production builds. On small VPSes a
# Turbopack build can stall while compiling, and an interrupted SSH/menu
# session can leave .next/lock behind. Keep the build bounded and use the
# more predictable webpack backend for Next applications.
run_node_build(){
    local user="$1"
    local app_root="$2"
    local timeout_value="${SHIELDPRESS_BUILD_TIMEOUT:-15m}"
    local -a build_cmd=(npm run build)
    local dist_dir="${3:-}"

    if grep -Eq '"next"[[:space:]]*:' "$app_root/package.json" && \
       grep -Eq '"build"[[:space:]]*:[^,}]*next[[:space:]]+build' "$app_root/package.json"; then
        if ! grep -Eq '"build"[[:space:]]*:[^,}]*--(webpack|turbopack)' "$app_root/package.json"; then
            build_cmd+=(-- --webpack)
        fi
    fi

    local home="/home/domains/$user"
    local npm_cache="$home/.npm"
    local -a build_env=(
        "HOME=$home"
        "USER=$user"
        "LOGNAME=$user"
        "NPM_CONFIG_CACHE=$npm_cache"
    )
    [ -n "$dist_dir" ] && build_env+=("NEXT_DIST_DIR=$dist_dir")

    # Keep timeout in the terminal's foreground process group. Without
    # --foreground, Ctrl-C can terminate the menu/runuser wrapper while a
    # Next.js worker spawned by npm keeps running and leaves .next/lock behind.
    # The same also makes TERM from the deploy timeout reach the build command
    # more predictably when the build is waiting in a Next.js worker phase.
    runuser -u "$user" -- env "${build_env[@]}" \
        timeout --foreground --signal=TERM --kill-after=30s "$timeout_value" \
        "${build_cmd[@]}" </dev/null
}

cleanup_stale_next_lock(){
    local app_root="$1"
    [ -f "$app_root/.next/lock" ] || return 0

    # Never remove a lock belonging to a live Next build.
    if ! pgrep -af "$app_root/.next/build" >/dev/null 2>&1; then
        rm -f "$app_root/.next/lock"
        warn "Removed stale Next.js build lock"
    fi
}

prepare_node_dependency_install(){
    local user="$1"
    local domain_path="$2"
    local home="/home/domains/$user"
    local app_root="$domain_path/public_html"
    local npm_cache="$home/.npm"

    # npm writes cache/log files below HOME. Repair this separately from the
    # application tree because fix_node_app_permissions cannot reach it.
    mkdir -p "$npm_cache"
    chown -R "$user:$user" "$npm_cache"
    chmod 700 "$npm_cache"

    # A copied or interrupted node_modules tree can contain missing entries
    # and make npm emit TAR_ENTRY_ERROR/ENOTEMPTY during reconciliation. It is
    # generated state, so rebuild it from the lockfile/package manifest.
    if [ -d "$app_root/node_modules" ] || [ -L "$app_root/node_modules" ]; then
        rm -rf "${app_root:?}/node_modules"
    fi

    # Verify is best-effort: npm can still download a clean cache entry when
    # the cache contains an old/incomplete package.
    run_pm2 "$user" npm cache verify >/dev/null 2>&1 || true
}

fix_node_app_permissions(){
    local user="$1"
    local domain_path="$2"
    local app_root="$domain_path/public_html"

    chown -R "$user:$user" "$app_root"
    find "$app_root" -path "$app_root/node_modules" -prune -o -path "$app_root/vendor" -prune -o -type d -exec chmod 755 {} \;
    find "$app_root" -path "$app_root/node_modules" -prune -o -path "$app_root/vendor" -prune -o -type f -exec chmod 644 {} \;
    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env"
    [ -f "$app_root/package.json" ] && chmod 644 "$app_root/package.json"
    [ -f "$app_root/package-lock.json" ] && chmod 644 "$app_root/package-lock.json"

    if [ -d "$app_root/node_modules" ]; then
        chown -R "$user:$user" "$app_root/node_modules"
        find "$app_root/node_modules" -type d -exec chmod 755 {} \;
        [ -d "$app_root/node_modules/.bin" ] && find -L "$app_root/node_modules/.bin" -type f -exec chmod 755 {} \;
    fi

    return 0
}

repair_selected_node_permissions(){
    local sysuser
    sysuser=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')
    sysuser="${sysuser:-$CLEAN_DOMAIN}"
    fix_node_app_permissions "$sysuser" "$DOMAIN_PATH"
    ok "Permissions fixed before PM2 start/restart (owner: $sysuser)"
}

# Make this user's PM2 daemon (and whatever it has saved via `pm2 save`) come
# back after a reboot.  The stock `pm2 startup` unit is Type=forking and uses
# a PID file below /home/domains.  SELinux/systemd can reject that PID file,
# leaving an otherwise healthy app unmanaged after reboot.  Replace just the
# service start command with PM2's foreground mode so systemd supervises it
# directly instead of trusting that PID file.
pm2_persist_startup(){
    local user="$1"
    local home="/home/domains/$user"
    local out="/tmp/.pm2-startup-${user}.$$"
    local startup_cmd
    local pm2_bin
    local service="pm2-${user}.service"
    local dropin="/etc/systemd/system/${service}.d/shieldpress-foreground.conf"

    pm2_bin=$(command -v pm2 2>/dev/null) || {
        fail "PM2 executable not found; cannot configure startup"
        return 1
    }

    env HOME="$home" PM2_HOME="$home/.pm2" "$pm2_bin" startup systemd -u "$user" --hp "$home" >"$out" 2>&1 || {
        rm -f "$out"
        fail "Could not create systemd startup for $user"
        return 1
    }
    startup_cmd=$(grep -E '^(sudo )?env PATH=.*pm2 .*systemd' "$out" | tail -1)
    if [ -n "$startup_cmd" ] && ! bash -c "$startup_cmd" >/dev/null 2>&1; then
        rm -f "$out"
        fail "Could not enable systemd startup for $user"
        return 1
    fi
    rm -f "$out"

    [ -f "/etc/systemd/system/$service" ] || {
        fail "Systemd unit was not created for $user"
        return 1
    }
    mkdir -p "$(dirname "$dropin")" || return 1
    cat > "$dropin" <<EOF
[Service]
Type=simple
PIDFile=
ExecStart=
ExecStart=$pm2_bin resurrect --no-daemon
EOF
    systemctl daemon-reload || return 1
    systemctl enable "$service" >/dev/null || {
        fail "Could not enable systemd startup for $user"
        return 1
    }
    run_pm2 "$user" pm2 save >/dev/null 2>&1 || true

    # Hand the existing daemon to systemd now. This gives the same process
    # model on first deploy and after reboot, and surfaces startup errors
    # immediately instead of waiting for the next reboot.
    run_pm2 "$user" pm2 kill >/dev/null 2>&1 || true
    systemctl reset-failed "$service" 2>/dev/null || true
    if ! systemctl restart "$service" || ! systemctl is-active --quiet "$service"; then
        fail "Systemd PM2 startup failed for $user"
        return 1
    fi
}

backup_node_app(){
    select_node_domain || return
    backup_selected_node_app
}

backup_selected_node_app(){
    local backup_root="$BACKUP_GLOBAL_DIR/nodejs/$CLEAN_DOMAIN"
    local ts
    local backup_file
    ts=$(date +%Y%m%d-%H%M%S)
    backup_file="$backup_root/${CLEAN_DOMAIN}-${ts}.tar.gz"

    mkdir -p "$backup_root"

    # Deploy backups contain source only. Runtime/config files and large or
    # user-generated directories must never be copied into this archive.
    tar -czf "$backup_file" \
        --exclude="./node_modules" \
        --exclude="*/node_modules" \
        --exclude="./uploads" \
        --exclude="*/uploads" \
        --exclude="./public" \
        --exclude="*/public" \
        -C "$DOMAIN_PATH/public_html" . 2>/dev/null || {
        fail "Backup failed"
        return 1
    }

    LAST_NODE_BACKUP_FILE="$backup_file"
    ok "Backup created: $backup_file"
}

select_node_deploy_mode(){
    echo ""
    echo "Deploy mode:"
    echo "  1) Standard update — build + PM2 restart/update environment"
    echo "  2) Initial deploy — install dependencies, Prisma migrations, build, start"
    echo "  3) Dependencies + DB migration — install, Prisma migrations, build, restart"
    echo ""
    read -p "Select mode [1]: " NODE_DEPLOY_MODE
    NODE_DEPLOY_MODE="${NODE_DEPLOY_MODE:-1}"
    case "$NODE_DEPLOY_MODE" in
        1|2|3) return 0 ;;
        *) fail "Invalid deploy mode"; return 1 ;;
    esac
}

confirm_node_backup(){
    local answer
    read -p "Backup source before deploy? [Y/n]: " answer
    answer="${answer:-Y}"
    [[ "$answer" =~ ^[Yy]$ ]] && return 0
    [[ "$answer" =~ ^[Nn]$ ]] && return 1
    warn "Invalid answer; backup will be created"
    return 0
}

is_prisma_project(){
    [ -f "prisma/schema.prisma" ] || grep -q '"prisma"' package.json 2>/dev/null
}

confirm_prisma_migration(){
    echo ""
    warn "Prisma migrations can change production database data/schema."
    echo "Confirm that a current database backup exists and the committed migration SQL was reviewed."
    read -p "Apply pending Prisma migrations now? [y/N]: " PRISMA_CONFIRM
    [[ "$PRISMA_CONFIRM" =~ ^[Yy]$ ]] || { warn "Database migration cancelled; deployment was not started."; return 1; }
}

run_prisma_migrations(){
    local user="$1"
    is_prisma_project || return 0

    # Production must only apply reviewed migrations committed from local
    # development. `db push` deliberately has no migration history and is not
    # used here.
    if [ ! -d "prisma/migrations" ] || ! find "prisma/migrations" -mindepth 2 -name migration.sql -print -quit | grep -q .; then
        fail "Prisma project has no committed prisma/migrations files. Create them locally with: npx prisma migrate dev --name <change>"
        return 1
    fi

    confirm_prisma_migration || return 1
    echo "Step $step: Applying reviewed Prisma migrations..."
    run_pm2 "$user" npx prisma migrate deploy || {
        fail "Prisma migrate deploy failed; PM2 was not restarted."
        return 1
    }
    run_pm2 "$user" npx prisma generate || {
        fail "Prisma generate failed; PM2 was not restarted."
        return 1
    }
    ok "Prisma migrations applied and client generated"
    ((step++))
}

install_node_runtime(){
    install_shieldpress_nodejs
}

select_node_domain(){
    DOMAIN_CHOICES=()
    local i=1

    echo ""
    echo "Node.js Domains:"
    echo "--------------------------------"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        [ "$APP_TYPE" = "nodejs" ] || continue
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        echo "  $i) $DOMAIN (port ${NODE_APP_PORT:-N/A})"
        DOMAIN_CHOICES[$i]=$(dirname "$(dirname "$env")")
        ((i++))
    done

    [ $i -eq 1 ] && { warn "No Node.js domains found"; return 1; }

    read -p "Select: " choice
    DOMAIN_PATH="${DOMAIN_CHOICES[$choice]}"
    [ -n "$DOMAIN_PATH" ] || { fail "Invalid selection"; return 1; }

    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2)
    CLEAN_DOMAIN=$(basename "$DOMAIN_PATH")
    NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')
    # Recover the configured proxy port for older/incomplete domain.env files.
    if ! [[ "$NODE_APP_PORT" =~ ^[0-9]+$ ]]; then
        NODE_APP_PORT=$(grep -oE 'proxy_pass http://127\.0\.0\.1:[0-9]+' \
            "/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
    fi
    NODE_APP_PORT="${NODE_APP_PORT:-3000}"
    if ! [[ "$NODE_APP_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_APP_PORT" -lt 1 ] || [ "$NODE_APP_PORT" -gt 65535 ]; then
        fail "Invalid Node.js app port in $ENV_FILE"
        return 1
    fi
    NODE_ENTRY=$(grep "^NODE_ENTRY=" "$ENV_FILE" | cut -d= -f2)
    NODE_ENTRY="${NODE_ENTRY:-app.js}"
    return 0
}

create_node_domain(){
    install_node_runtime || return 1
    ADD_DOMAIN_APP=nodejs bash "$DOMAIN_MODULE/add-domain.sh"
}

list_node_domains(){
    echo ""
    echo "Node.js Domains (PM2 overview):"
    printf '  %-25s %-7s %-9s %-6s %-10s %-8s %-8s %-10s %s\n' \
        "DOMAIN" "PORT" "LISTENING" "PM2 ID" "STATUS" "RESTARTS" "PID" "MEMORY" "RUN AS / UPTIME"
    printf '  %s\n' "----------------------------------------------------------------------------------------------------------------"
    local found=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "nodejs" ] || continue
        found=1
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        ROOT=$(grep "^ROOT=" "$env" | cut -d= -f2)
        NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        local pm2_name=$(basename "$(dirname "$(dirname "$env")")")
        local app_root="$(dirname "$(dirname "$env")")/public_html"
        local row=""
        local run_as="$pm2_name"
        if command -v pm2 >/dev/null 2>&1; then
            row=$(pm2_app_row "$pm2_name" "$pm2_name" "$app_root")
            if [ -z "$row" ]; then
                row=$(root_pm2_app_row "$pm2_name" "$app_root")
                [ -n "$row" ] && run_as="root (migrate)"
            fi
        fi
        local pm2_id="-" pm2_state="not running" restarts="-" pid="-" uptime="-" memory="-"
        [ -n "$row" ] && IFS='|' read -r pm2_id pm2_state restarts pid uptime memory <<< "$row"
        local listening="no"
        port_is_listening "$NODE_APP_PORT" && listening="yes"
        printf '  %-25s %-7s %-9s %-6s %-10s %-8s %-8s %-10s %s / %s\n' \
            "$DOMAIN" "$NODE_APP_PORT" "$listening" "$pm2_id" "$pm2_state" "$restarts" "$pid" \
            "$(format_pm2_memory "$memory")" "$run_as" "$(format_pm2_uptime "$uptime")"
    done
    [ "$found" = "0" ] && warn "No Node.js domains found"
}

list_running_node_apps(){
    echo ""
    echo "Running Node.js Apps (PM2):"
    echo "--------------------------------"
    if ! command -v pm2 >/dev/null 2>&1; then
        warn "PM2 is not installed"
        return
    fi
    # Each domain now runs its own PM2 daemon under its own Linux user (see
    # run_pm2), so there is no single global "pm2 status" anymore - show one
    # per domain.
    local found=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        [ "$(grep "^APP_TYPE=" "$env" | cut -d= -f2)" = "nodejs" ] || continue
        found=1
        local dom_user
        dom_user=$(basename "$(dirname "$(dirname "$env")")")
        echo "--- $dom_user ---"
        run_pm2 "$dom_user" pm2 status
        local root_row
        root_row=$(root_pm2_app_row "$dom_user" "$(dirname "$(dirname "$env")")/public_html")
        if [ -n "$root_row" ]; then
            warn "$dom_user also has a legacy root PM2 entry; migrate it before Start/Restart/Deploy."
            echo "--- $dom_user (root legacy) ---"
            pm2 status "$dom_user"
        fi
    done
    [ "$found" = "0" ] && warn "No Node.js domains found"
}

# ==========================================
# PM2 START APP
# ==========================================

start_node_app(){
    select_node_domain || return
    ensure_pm2 || return
    prepare_root_pm2_for_action || return
    migrate_legacy_domain_pm2_name || return
    assert_node_port_available || return
    cd "$DOMAIN_PATH/public_html" || return
    repair_selected_node_permissions || return

    local pm2_name="$CLEAN_DOMAIN"

    # Stop old systemd service if exists (migration)
    local old_service="${CLEAN_DOMAIN}-node.service"
    if systemctl is-active --quiet "$old_service" 2>/dev/null; then
        warn "Stopping old systemd service (migrating to PM2)..."
        systemctl stop "$old_service" 2>/dev/null
        systemctl disable "$old_service" 2>/dev/null
    fi

    echo ""
    echo "Start mode:"
    echo "  1) npm start (recommended for Next.js, etc.)"
    echo "  2) node $NODE_ENTRY"
    echo "  3) Next.js standalone (node .next-release/standalone/server.js or .next/standalone/server.js)"
    echo ""
    read -p "Select mode [1]: " PM2_MODE
    PM2_MODE="${PM2_MODE:-1}"

    # Keep an existing process. Repeated starts should restart the same PM2
    # app instead of deleting it and creating a second daemon entry.
    if run_pm2 "$pm2_name" pm2 describe "$pm2_name" >/dev/null 2>&1; then
        restart_pm2_app_with_config "$pm2_name" || {
            fail "PM2 restart failed"
            return 1
        }
        pm2_persist_startup "$pm2_name"
        ok "App restarted via PM2: $pm2_name (PORT=$NODE_APP_PORT)"
    else
    case "$PM2_MODE" in
        1)
            if is_nextjs_app; then
                start_pm2_next_app "$pm2_name" || {
                    fail "Next.js PM2 start failed on port $NODE_APP_PORT"
                    return 1
                }
            else
                run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start npm --name "$pm2_name" --update-env -- start || {
                    fail "PM2 start failed"
                    return 1
                }
            fi
            ;;
        2)
            if [ ! -f "$DOMAIN_PATH/public_html/$NODE_ENTRY" ]; then
                fail "Entry file not found: $NODE_ENTRY"
                return 1
            fi
            run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start "$NODE_ENTRY" --name "$pm2_name" --update-env || {
                fail "PM2 start failed"
                return 1
            }
            ;;
        3)
            local standalone_server=".next/standalone/server.js"
            [ -f ".next-release/standalone/server.js" ] && standalone_server=".next-release/standalone/server.js"
            if [ ! -f "$standalone_server" ]; then
                fail "Next.js standalone server not found. Run Deploy/Build first."
                return 1
            fi
            run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start "$standalone_server" --name "$pm2_name" --update-env || {
                fail "PM2 start failed"
                return 1
            }
            ;;
        *)
            fail "Invalid mode"
            return 1
            ;;
    esac

        pm2_persist_startup "$pm2_name"
        ok "App started with PM2: $pm2_name (PORT=$NODE_APP_PORT)"
    fi
    echo ""
    run_pm2 "$pm2_name" pm2 status "$pm2_name"
}

# ==========================================
# PM2 STOP APP
# ==========================================

stop_node_app(){
    select_node_domain || return
    ensure_pm2 || return

    local pm2_name="$CLEAN_DOMAIN"
    confirm_action "Stopping will take this app offline." || return
    if run_pm2 "$pm2_name" pm2 describe "$pm2_name" >/dev/null 2>&1; then
        run_pm2 "$pm2_name" pm2 stop "$pm2_name" 2>/dev/null && \
            ok "PM2 app stopped: $pm2_name" || fail "PM2 app could not be stopped: $pm2_name"
        return
    fi
    if [ -n "$(root_pm2_app_row "$pm2_name" "$DOMAIN_PATH/public_html")" ]; then
        warn "Stopping the matching legacy root PM2 app for this domain."
        pm2 stop "$pm2_name" 2>/dev/null && pm2 save --force >/dev/null 2>&1 && \
            ok "Legacy root PM2 app stopped: $pm2_name" || fail "Legacy root PM2 app could not be stopped: $pm2_name"
    else
        fail "PM2 app not found: $pm2_name"
    fi
}

# ==========================================
# PM2 RESTART APP
# ==========================================

restart_node_app(){
    select_node_domain || return
    ensure_pm2 || return
    prepare_root_pm2_for_action || return
    migrate_legacy_domain_pm2_name || return
    assert_node_port_available || return
    cd "$DOMAIN_PATH/public_html" || return
    repair_selected_node_permissions || return

    local pm2_name="$CLEAN_DOMAIN"
    restart_pm2_app_with_config "$pm2_name" && \
        ok "PM2 app restarted with updated environment (PORT=$NODE_APP_PORT)" || \
        fail "PM2 app not found or restart failed"
}

# ==========================================
# DEPLOY / BUILD (with Prisma support)
# ==========================================

deploy_node_app(){
    select_node_domain || return
    ensure_pm2 || return
    cd "$DOMAIN_PATH/public_html" || return

    if [ ! -f package.json ]; then
        warn "package.json not found"
        return
    fi

    select_node_deploy_mode || return
    confirm_action "This will deploy $DOMAIN." || return

    # A root-owned legacy PM2 app is invisible to run_pm2 and keeps the
    # configured port occupied. Migrate it before touching build artifacts so
    # deployment cannot fail later with EADDRINUSE or root-owned .next files.
    prepare_root_pm2_for_action || return
    migrate_legacy_domain_pm2_name || return
    assert_node_port_available || return

    if confirm_node_backup; then
        backup_selected_node_app || return
    else
        warn "Source backup skipped"
    fi

    # Repair ownership before npm can create node_modules or build output.
    # PM2 is started only after the final ownership pass below.
    local sysuser
    sysuser=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d= -f2)
    sysuser="${sysuser:-$CLEAN_DOMAIN}"
    local pm2_name="$CLEAN_DOMAIN"
    chown root:root "$DOMAIN_PATH"
    chmod 755 "$DOMAIN_PATH"
    [ -d "$DOMAIN_PATH/config" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/config" && chmod 750 "$DOMAIN_PATH/config"
    [ -f "$DOMAIN_PATH/config/domain.env" ] && chmod 640 "$DOMAIN_PATH/config/domain.env"
    fix_node_app_permissions "$sysuser" "$DOMAIN_PATH"
    [ -d "$DOMAIN_PATH/backup" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/backup" && chmod 750 "$DOMAIN_PATH/backup"
    [ -d "$DOMAIN_PATH/tmp" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/tmp" && chmod 755 "$DOMAIN_PATH/tmp"
    ok "Permissions fixed before build/start (owner: $sysuser)"

    echo ""
    local step=1

    if [ "$NODE_DEPLOY_MODE" = "2" ] || [ "$NODE_DEPLOY_MODE" = "3" ]; then
        echo "Step $step: Installing dependencies..."
        prepare_node_dependency_install "$sysuser" "$DOMAIN_PATH"
        if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
            run_pm2 "$sysuser" npm ci --include=dev || { fail "npm ci failed"; return 1; }
        else
            run_pm2 "$sysuser" npm install --include=dev || { fail "npm install failed"; return 1; }
        fi
        ok "Dependencies installed"
        ((step++))

        run_prisma_migrations "$sysuser" || return 1
    fi

    # Build only when package.json has an actual scripts.build entry. Parsing
    # JSON avoids false positives from npm's help output or unrelated script
    # names containing the word "build".
    local has_build_script
    has_build_script=$(node -e '
        const p = require("./package.json");
        process.stdout.write(p.scripts && typeof p.scripts.build === "string" ? "yes" : "no");
    ' 2>/dev/null || echo no)
    if [ "$has_build_script" = "yes" ]; then
        echo ""
        echo "Step $step: Building for production..."

        local previous_next=""
        local build_output=".next"
        local candidate_next=""
        local dist_dir_supported="no"

        if is_nextjs_app && next_app_supports_dist_dir; then
            dist_dir_supported="yes"
            candidate_next=".next.candidate.$$"
            build_output="$candidate_next"
            rm -rf "$candidate_next"
            mkdir -p "$candidate_next/server/app" || {
                fail "Could not prepare candidate output for $sysuser"
                return 1
            }
            chown -R "$sysuser:$sysuser" "$candidate_next" || {
                fail "Could not assign candidate output to $sysuser"
                return 1
            }
            echo "Building separately in $candidate_next; the live build remains untouched."
        else
            cleanup_stale_next_lock "$DOMAIN_PATH/public_html"
            # Legacy path for apps whose Next config does not expose NEXT_DIST_DIR.
            if [ -d ".next" ]; then
                previous_next=".next.deploy-backup.$$"
                echo "Saving previous .next build..."
                mv .next "$previous_next" || { fail "Could not save previous .next build"; return 1; }
            fi
            mkdir -p .next/server/app || {
                fail "Could not prepare .next for $sysuser"
                return 1
            }
            chown -R "$sysuser:$sysuser" .next || {
                fail "Could not assign .next to $sysuser"
                return 1
            }
        fi

        echo "Running build as Linux user: $sysuser"
        if ! run_node_build "$sysuser" "$DOMAIN_PATH/public_html" "$candidate_next"; then
            fail "Build failed"
            if [ "$dist_dir_supported" = "yes" ]; then
                rm -rf "$candidate_next"
            else
                rm -rf .next
                if [ -n "$previous_next" ] && [ -d "$previous_next" ]; then
                    mv "$previous_next" .next
                    fix_node_app_permissions "$sysuser" "$DOMAIN_PATH"
                    warn "Previous .next build restored; the running app was left untouched."
                fi
            fi
            return 1
        fi

        if [ "$dist_dir_supported" = "yes" ]; then
            if [ ! -s "$candidate_next/BUILD_ID" ]; then
                rm -rf "$candidate_next"
                fail "Candidate build has no BUILD_ID; live release was not changed."
                return 1
            fi
            # Preserve the current release until the candidate is complete.
            # The directory handoff is brief; the running PM2 process is then
            # reloaded with NEXT_DIST_DIR=.next-release.
            if [ -e .next-release ] || [ -L .next-release ]; then
                previous_next=".next-release.deploy-backup.$$"
                mv .next-release "$previous_next" || {
                    fail "Could not preserve the current .next-release"
                    return 1
                }
            fi
            mv "$candidate_next" .next-release || {
                [ -n "$previous_next" ] && mv "$previous_next" .next-release
                fail "Could not activate candidate build"
                return 1
            }
            build_output=".next-release"
        fi

        # Next.js standalone: copy public + static into the selected output.
        if [ -d "$build_output/standalone" ]; then
            echo "Detected Next.js standalone output, copying assets..."
            [ -d "public" ] && cp -r public "$build_output/standalone/"
            [ -d "$build_output/static" ] && mkdir -p "$build_output/standalone/.next" && cp -r "$build_output/static" "$build_output/standalone/.next/"
            ok "Copied public + static into standalone"
        fi

        ok "Build completed"
    fi

    # Build tools may have created new files; repair ownership before PM2.
    fix_node_app_permissions "$sysuser" "$DOMAIN_PATH"

    # Restart via PM2
    echo ""
    echo "Step $((step + 1)): Restarting app via PM2 and updating environment..."

    if run_pm2 "$pm2_name" pm2 describe "$pm2_name" >/dev/null 2>&1; then
        if restart_pm2_app_with_config "$pm2_name"; then
            ok "App reloaded via PM2 (environment updated, PORT=$NODE_APP_PORT)"
            if [ "$dist_dir_supported" = "yes" ] && [ -n "$previous_next" ]; then
                ok "Previous Next.js release retained at $previous_next for rollback"
            else
                [ -n "$previous_next" ] && rm -rf "$previous_next"
            fi
        else
                fail "PM2 restart failed"
                if [ "$dist_dir_supported" = "yes" ]; then
                    rm -rf .next-release
                    if [ -n "$previous_next" ] && [ -d "$previous_next" ]; then
                        mv "$previous_next" .next-release
                        restart_pm2_app_with_config "$pm2_name" .next-release >/dev/null 2>&1 || true
                        warn "Previous Next.js release restored after reload failure."
                    elif [ -d .next ]; then
                        restart_pm2_app_with_config "$pm2_name" .next >/dev/null 2>&1 || true
                        warn "Previous .next build retained after reload failure."
                    fi
                fi
                return 1
        fi
    else
        echo "App not yet running in PM2. Starting now..."
        echo ""
        echo "Start mode:"
        echo "  1) npm start (recommended)"
        echo "  2) node $NODE_ENTRY"
        echo "  3) Next.js standalone"
        echo ""
        read -p "Select mode [1]: " PM2_MODE
        PM2_MODE="${PM2_MODE:-1}"

        case "$PM2_MODE" in
            1)
                if is_nextjs_app; then
                    start_pm2_next_app "$pm2_name" || { fail "Next.js PM2 start failed"; return 1; }
                else
                    run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start npm --name "$pm2_name" --update-env -- start || { fail "PM2 start failed"; return 1; }
                fi
                ;;
            2) run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start "$NODE_ENTRY" --name "$pm2_name" --update-env || { fail "PM2 start failed"; return 1; } ;;
            3)
                local standalone_server=".next/standalone/server.js"
                [ -f ".next-release/standalone/server.js" ] && standalone_server=".next-release/standalone/server.js"
                run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start "$standalone_server" --name "$pm2_name" --update-env || { fail "PM2 start failed"; return 1; }
                ;;
            *) fail "Invalid mode"; return 1 ;;
        esac

        pm2_persist_startup "$pm2_name"
        ok "App started with PM2: $pm2_name (PORT=$NODE_APP_PORT)"
    fi

    echo ""
    run_pm2 "$pm2_name" pm2 status "$pm2_name"

}

# ==========================================
# PM2 LOGS
# ==========================================

node_logs(){
    select_node_domain || return
    ensure_pm2 || return
    local pm2_name="$CLEAN_DOMAIN"
    if run_pm2 "$pm2_name" pm2 describe "$pm2_name" >/dev/null 2>&1; then
        run_pm2 "$pm2_name" pm2 logs "$pm2_name"
    elif [ -n "$(root_pm2_app_row "$pm2_name" "$DOMAIN_PATH/public_html")" ]; then
        warn "Showing logs from the legacy root PM2 entry; migrate it before managing the app."
        pm2 logs "$pm2_name"
    else
        fail "PM2 app not found: $pm2_name"
    fi
}

# ==========================================
# PM2 STATUS (ALL)
# ==========================================

pm2_status_all(){
    ensure_pm2 || return
    list_running_node_apps
}

# ==========================================
# ADVANCED TOOLS
# ==========================================

fix_node_permissions(){
    FIX_APP_TYPE=nodejs bash "$DOMAIN_MODULE/fix-permission.sh"
}

change_node_port(){
    select_node_domain || return
    read -p "New local app port: " NEW_PORT

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        fail "Invalid port"
        return 1
    fi

    if [ "$NEW_PORT" != "$NODE_APP_PORT" ] && ss -tuln 2>/dev/null | grep -q ":${NEW_PORT} "; then
        fail "Port $NEW_PORT is already in use"
        return 1
    fi

    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    ENV_TMP="/tmp/${CLEAN_DOMAIN}.domain.env.$$"
    NGINX_TMP="/tmp/${CLEAN_DOMAIN}.nginx.conf.$$"

    confirm_action "Changing port updates Nginx and restarts the app." || return
    # Migrate while the old, configured port is still active; the migration
    # verifies the running root app against that port before any config edit.
    prepare_root_pm2_for_action || return
    assert_node_port_available "$NEW_PORT" || return
    backup_selected_node_app || return

    cp "$ENV_FILE" "$ENV_TMP" || return
    cp "$NGINX_CONF" "$NGINX_TMP" || return

    sed -i "s/^NODE_APP_PORT=.*/NODE_APP_PORT=$NEW_PORT/" "$ENV_FILE"
    sed -i "s/127\.0\.0\.1:${NODE_APP_PORT}/127.0.0.1:${NEW_PORT}/g" "$NGINX_CONF"

    if nginx -t; then
        systemctl reload nginx

        # Restart PM2 app with new port
        if command -v pm2 >/dev/null 2>&1; then
            local pm2_name="$CLEAN_DOMAIN"
            run_pm2 "$pm2_name" pm2 delete "$pm2_name" 2>/dev/null || true
            cd "$DOMAIN_PATH/public_html" || return
            NODE_APP_PORT="$NEW_PORT"
            if is_nextjs_app; then
                start_pm2_next_app "$pm2_name" || warn "Next.js PM2 restart failed"
            else
                run_pm2 "$pm2_name" PORT=${NEW_PORT} NODE_ENV=production pm2 start npm --name "$pm2_name" --update-env -- start 2>/dev/null || true
                pm2_persist_startup "$pm2_name"
            fi
        fi

        ok "Node.js port changed to $NEW_PORT"
    else
        fail "Nginx config invalid after port change"
        cp "$ENV_TMP" "$ENV_FILE"
        cp "$NGINX_TMP" "$NGINX_CONF"
        systemctl reload nginx 2>/dev/null || true
        warn "Port change rolled back."
    fi

    rm -f "$ENV_TMP" "$NGINX_TMP"
}

change_node_entry(){
    select_node_domain || return
    ensure_pm2 || return

    echo ""
    echo "Current entry: ${NODE_ENTRY:-app.js}"
    echo "Files in public_html:"
    find "$DOMAIN_PATH/public_html" -maxdepth 1 -type f \( -name "*.js" -o -name "*.mjs" -o -name "*.cjs" \) -printf " - %f\n" 2>/dev/null
    echo ""
    read -p "New entry file [server.js]: " NEW_ENTRY
    NEW_ENTRY="${NEW_ENTRY:-server.js}"

    if [[ "$NEW_ENTRY" == /* ]] || [[ "$NEW_ENTRY" == *".."* ]] || [[ "$NEW_ENTRY" == *"/"* ]]; then
        fail "Entry must be a file name inside public_html"
        return 1
    fi

    if [ ! -f "$DOMAIN_PATH/public_html/$NEW_ENTRY" ]; then
        fail "Entry file not found: $DOMAIN_PATH/public_html/$NEW_ENTRY"
        return 1
    fi

    ENV_FILE="$DOMAIN_PATH/config/domain.env"

    confirm_action "Changing entry will restart the app." || return
    prepare_root_pm2_for_action || return
    assert_node_port_available || return
    backup_selected_node_app || return

    if grep -q "^NODE_ENTRY=" "$ENV_FILE"; then
        sed -i "s|^NODE_ENTRY=.*|NODE_ENTRY=$NEW_ENTRY|" "$ENV_FILE"
    else
        echo "NODE_ENTRY=$NEW_ENTRY" >> "$ENV_FILE"
    fi

    # Restart PM2 with new entry
    if command -v pm2 >/dev/null 2>&1; then
        local pm2_name="$CLEAN_DOMAIN"
        run_pm2 "$pm2_name" pm2 delete "$pm2_name" 2>/dev/null || true
        cd "$DOMAIN_PATH/public_html" || return
        run_pm2 "$pm2_name" PORT=${NODE_APP_PORT} NODE_ENV=production pm2 start "$NEW_ENTRY" --name "$pm2_name" --update-env || {
            fail "PM2 restart failed"
            return 1
        }
        pm2_persist_startup "$pm2_name"
    fi

    ok "Node.js entry changed to $NEW_ENTRY"
}

node_health_check(){
    select_node_domain || return

    local nginx_conf="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    local pm2_name="$CLEAN_DOMAIN"
    local status_code

    echo ""
    echo "Health check: $DOMAIN"
    echo "--------------------------------"
    echo "PM2 name: $pm2_name"
    echo "Entry   : ${NODE_ENTRY:-app.js}"
    echo "Port    : ${NODE_APP_PORT:-N/A}"

    # Check PM2 process
    if command -v pm2 >/dev/null 2>&1; then
        if run_pm2 "$pm2_name" pm2 describe "$pm2_name" >/dev/null 2>&1; then
            ok "PM2 process found"
            local pm2_status
            pm2_status=$(run_pm2 "$pm2_name" pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    apps=json.load(sys.stdin)
    for a in apps:
        if a['name']=='$pm2_name':
            print(a['pm2_env']['status'])
            sys.exit()
    print('stopped')
except: print('unknown')
" 2>/dev/null || echo "unknown")
            if [ "$pm2_status" = "online" ]; then
                ok "PM2 status: online"
            else
                fail "PM2 status: $pm2_status"
            fi
        else
            fail "PM2 process not found: $pm2_name"
        fi
    else
        fail "PM2 is not installed"
    fi

    # Check port
    if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${NODE_APP_PORT}[[:space:]]|0\.0\.0\.0:${NODE_APP_PORT}[[:space:]]|:::${NODE_APP_PORT}[[:space:]]"; then
        ok "Port ${NODE_APP_PORT} is listening"
    else
        fail "Port ${NODE_APP_PORT} is not listening"
        return 1
    fi

    # Check HTTP response
    status_code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 "http://127.0.0.1:${NODE_APP_PORT}/" 2>/dev/null || echo "000")

    if [[ "$status_code" =~ ^[234][0-9][0-9]$ ]]; then
        ok "Local app responded with HTTP $status_code"
    else
        fail "Local app did not respond on http://127.0.0.1:${NODE_APP_PORT}/"
        return 1
    fi

    # Check Nginx
    if [ -f "$nginx_conf" ] && grep -q "127.0.0.1:${NODE_APP_PORT}" "$nginx_conf"; then
        ok "Nginx proxy points to 127.0.0.1:${NODE_APP_PORT}"
    else
        warn "Nginx config may not point to port ${NODE_APP_PORT}: $nginx_conf"
    fi
}

node_status(){
    echo ""
    echo "Runtime:"
    echo "Node.js : $(node -v 2>/dev/null || echo N/A)"
    echo "npm     : $(npm -v 2>/dev/null || echo N/A)"
    echo "PM2     : $(pm2 -v 2>/dev/null || echo 'Not installed')"
    list_node_domains
}

migrate_root_pm2(){
    select_node_domain || return
    command -v python3 >/dev/null 2>&1 || { fail "python3 is required"; return 1; }
    python3 "$BASE_DIR/modules/nodejs/migrate-root-pm2.py" \
        "$CLEAN_DOMAIN" "$NODE_APP_PORT" "$DOMAIN"
}

migrate_systemd_to_pm2(){
    echo ""
    echo "Migrating systemd Node.js services to PM2..."
    echo "--------------------------------"

    ensure_pm2 || return

    local migrated=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "nodejs" ] || continue

        local dpath=$(dirname "$(dirname "$env")")
        local clean=$(basename "$dpath")
        local port=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        local domain=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        local old_service="${clean}-node.service"
        port="${port:-3000}"

        if systemctl is-active --quiet "$old_service" 2>/dev/null; then
            echo ""
            echo "Migrating: $domain ($old_service -> PM2)"
            systemctl stop "$old_service" 2>/dev/null
            systemctl disable "$old_service" 2>/dev/null

            cd "$dpath/public_html" || continue
            run_pm2 "$clean" pm2 delete "$clean" 2>/dev/null || true
            DOMAIN_PATH="$dpath"
            DOMAIN="$domain"
            CLEAN_DOMAIN="$clean"
            NODE_APP_PORT="$port"
            NODE_ENTRY=$(grep "^NODE_ENTRY=" "$env" | cut -d= -f2 | tr -d '[:space:]')
            NODE_ENTRY="${NODE_ENTRY:-app.js}"
            if is_nextjs_app; then
                start_pm2_next_app "$clean" || {
                    warn "Failed to start $clean via Next.js/PM2, check manually"
                    continue
                }
            else
                run_pm2 "$clean" PORT=${port} NODE_ENV=production pm2 start npm --name "$clean" --update-env -- start || {
                    warn "Failed to start $clean via PM2, check manually"
                    continue
                }
                pm2_persist_startup "$clean"
            fi
            ok "$domain migrated to PM2 (running as $clean, not root)"
            ((migrated++))
        fi
    done

    if [ "$migrated" -eq 0 ]; then
        echo "No systemd Node.js services found to migrate."
    else
        ok "$migrated app(s) migrated to PM2"
    fi
}

node_advanced_menu(){
    while true; do
        clear
        sp_header "Node.js Advanced" "Port, entry, diagnostics"
        sp_menu_grid \
            "1|Change App Port|yellow" \
            "2|Change Entry File|blue" \
            "3|Health Check / 502|green" \
            "4|Migrate systemd to PM2|cyan" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) change_node_port ;;
            2) change_node_entry ;;
            3) node_health_check ;;
            4) migrate_systemd_to_pm2 ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

# ==========================================
# MAIN MENU
# ==========================================

while true; do
    clear
    sp_header "Node.js Manager" "Apps, PM2, deployments"
    sp_menu_grid \
        "1|Install/Update Runtime|green" \
        "2|Add Node.js Domain|green" \
        "3|List Node.js Domains|cyan" \
        "4|Running Apps (PM2)|cyan" \
        "5|Backup Node.js App|yellow" \
        "6|Deploy / Build|blue" \
        "7|Start / Ensure App (PM2)|green" \
        "8|Stop App (PM2)|red" \
        "9|Restart App (PM2)|yellow" \
        "10|View App Logs|magenta" \
        "11|Runtime / Status|cyan" \
        "12|Fix Permissions|green" \
        "13|Advanced Tools|yellow" \
        "14|Migrate root PM2 to user|cyan" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) install_node_runtime ;;
        2) create_node_domain ;;
        3) list_node_domains ;;
        4) pm2_status_all ;;
        5) backup_node_app ;;
        6) deploy_node_app ;;
        7) start_node_app ;;
        8) stop_node_app ;;
        9) restart_node_app ;;
        10) node_logs ;;
        11) node_status ;;
        12) fix_node_permissions ;;
        13) node_advanced_menu ;;
        14) migrate_root_pm2 ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
