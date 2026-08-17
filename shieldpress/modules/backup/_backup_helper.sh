#!/bin/bash
# Helper functions dùng chung cho backup module

DOMAINS_ROOT="/home/domains"
BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/backup.log"

mkdir -p "$LOG_DIR"

log(){   echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }
ok(){    echo "[OK] $1";    log "[OK] $1"; }
fail(){  echo "[FAIL] $1";  log "[FAIL] $1"; }
warn(){  echo "[WARN] $1";  log "[WARN] $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

# Chọn domain - đọc thẳng từ file tránh variable leak
select_domain_backup(){
    local -n _FOLDERS=$1   # nameref to caller's array
    _FOLDERS=()

    echo ""
    echo "Available Domains:"
    echo "--------------------------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        echo "$i) $DN"
        _FOLDERS[$i]=$(basename "$d")
        ((i++))
    done

    echo "--------------------------------------------------"
    read -p "Select domain number: " CHOICE
    echo "$CHOICE"
}

# Đọc domain info từ file
load_domain_info(){
    local DPATH=$1
    local ENV="$DPATH/config/domain.env"
    DOMAIN_PATH="$DPATH"
    DOMAIN=$(grep    "^DOMAIN="      "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_NAME=$(grep   "^DB_NAME="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_USER=$(grep   "^DB_USER="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_PASS=$(grep   "^DB_PASS="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    APP_TYPE=$(grep "^APP_TYPE=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    ROOT=$(grep "^ROOT=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    APP_TYPE="${APP_TYPE:-wordpress}"
    DB_CONNECTION="${DB_CONNECTION:-mysql}"
    ROOT="${ROOT:-$DPATH/public_html}"

    # Load per-domain backup config
    load_backup_config "$DPATH"
}

# ==================================================
# PER-DOMAIN BACKUP CONFIG
# ==================================================
# File: <domain>/config/backup.env
#
# BACKUP_PATHS=wp-content/themes,wp-content/plugins,wp-content/uploads
# BACKUP_EXCLUDE=cache,logs,*.log,tmp
# BACKUP_ENABLED=1
# BACKUP_RETENTION=7
# INCR_EXCLUDE=vendor,node_modules,.git

load_backup_config(){
    local DPATH="$1"
    local BENV="$DPATH/config/backup.env"

    # Reset per-domain overrides
    BK_CUSTOM_PATHS=""
    BK_CUSTOM_EXCLUDE=""
    BK_CUSTOM_INCR_EXCLUDE=""
    BK_ENABLED=1
    BK_RETENTION=""

    [ -f "$BENV" ] || return 0

    BK_CUSTOM_PATHS=$(grep "^BACKUP_PATHS=" "$BENV" 2>/dev/null | cut -d'=' -f2-)
    BK_CUSTOM_EXCLUDE=$(grep "^BACKUP_EXCLUDE=" "$BENV" 2>/dev/null | cut -d'=' -f2-)
    BK_CUSTOM_INCR_EXCLUDE=$(grep "^INCR_EXCLUDE=" "$BENV" 2>/dev/null | cut -d'=' -f2-)
    BK_ENABLED=$(grep "^BACKUP_ENABLED=" "$BENV" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    BK_RETENTION=$(grep "^BACKUP_RETENTION=" "$BENV" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')

    BK_ENABLED="${BK_ENABLED:-1}"
}

# Build --exclude flags from comma-separated list
build_exclude_opts(){
    local CSV="$1"
    local PREFIX="${2:-.}"
    local OPTS=""
    local IFS=','
    for item in $CSV; do
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$item" ] && continue
        OPTS="$OPTS --exclude=${PREFIX}/${item}"
    done
    echo "$OPTS"
}

# Build -not -path flags from comma-separated list (for find)
build_find_excludes(){
    local CSV="$1"
    local OPTS=""
    local IFS=','
    for item in $CSV; do
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$item" ] && continue
        OPTS="$OPTS -not -path */${item}/*"
    done
    echo "$OPTS"
}

# ==================================================
# PROGRESS BAR + ETA HELPERS
# ==================================================

format_duration(){
    local SECS=$1
    if [ "$SECS" -ge 3600 ]; then
        printf "%dh %dm %ds" $((SECS/3600)) $((SECS%3600/60)) $((SECS%60))
    elif [ "$SECS" -ge 60 ]; then
        printf "%dm %ds" $((SECS/60)) $((SECS%60))
    else
        printf "%ds" "$SECS"
    fi
}

# Get DB size in MB
get_db_size_mb(){
    local SIZE_MB=0
    case "$DB_CONNECTION" in
        mysql|mariadb)
            SIZE_MB=$(mysql -N -e "
                SELECT ROUND(SUM(data_length + index_length)/1024/1024, 0)
                FROM information_schema.tables
                WHERE table_schema='$DB_NAME';" 2>/dev/null)
            ;;
        pgsql|postgres|postgresql)
            SIZE_MB=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc \
                "SELECT ROUND(pg_database_size('$DB_NAME')/1024/1024);" 2>/dev/null)
            ;;
    esac
    echo "${SIZE_MB:-0}"
}

database_exists_for_backup(){
    if [ -z "$DB_NAME" ] || [ "$DB_CONNECTION" = "none" ]; then
        return 1
    fi

    case "$DB_CONNECTION" in
        mysql|mariadb)
            [ "$(mysql -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>/dev/null)" = "$DB_NAME" ]
            ;;
        pgsql|postgres|postgresql)
            runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | grep -q 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Estimate time based on size (MB) and operation type
# DB dump: ~50MB/s, File tar.gz: ~30MB/s, DB import: ~20MB/s, Restore extract: ~40MB/s
estimate_seconds(){
    local SIZE_MB=$1
    local OP_TYPE=$2
    local SPEED=30

    case "$OP_TYPE" in
        db_dump)    SPEED=50 ;;
        db_import)  SPEED=20 ;;
        tar_gz)     SPEED=30 ;;
        extract)    SPEED=40 ;;
        *)          SPEED=30 ;;
    esac

    local EST=$(( SIZE_MB / SPEED ))
    [ "$EST" -lt 1 ] && EST=1
    echo "$EST"
}

# Show pre-operation info with size + ETA
show_operation_eta(){
    local OP_NAME="$1"
    local SIZE_MB="$2"
    local OP_TYPE="$3"

    local EST_SEC
    EST_SEC=$(estimate_seconds "$SIZE_MB" "$OP_TYPE")
    local EST_FMT
    EST_FMT=$(format_duration "$EST_SEC")

    echo -e "  Operation : $OP_NAME"
    echo -e "  Data size : ${SIZE_MB}MB"
    echo -e "  Est. time : ~${EST_FMT}"
    echo ""
}

# Show elapsed time after completion
show_elapsed(){
    local START=$1
    local END
    END=$(date +%s)
    local ELAPSED=$((END - START))
    local FMT
    FMT=$(format_duration "$ELAPSED")
    echo "  Elapsed   : $FMT"
}

# Run a command with pv progress if available (for piped data)
# Usage: run_with_progress INPUT_SIZE_BYTES command...
# For DB dump: pipe through pv
run_piped_with_progress(){
    local SIZE_BYTES=$1
    shift

    if command -v pv >/dev/null 2>&1 && [ "$SIZE_BYTES" -gt 0 ] 2>/dev/null; then
        "$@" | pv -s "$SIZE_BYTES" -p -t -e -r
    else
        "$@"
    fi
}

backup_db_to_file(){
    local OUT_FILE="$1"

    if [ -z "$DB_NAME" ] || [ "$DB_CONNECTION" = "none" ]; then
        warn "No database configured for $DOMAIN"
        return 2
    fi

    if ! database_exists_for_backup; then
        warn "Database does not exist: $DB_NAME"
        return 2
    fi

    local DB_SIZE_MB
    DB_SIZE_MB=$(get_db_size_mb)
    local DB_SIZE_BYTES=$((DB_SIZE_MB * 1024 * 1024))
    local START_TIME
    START_TIME=$(date +%s)

    show_operation_eta "Database backup ($DB_CONNECTION)" "$DB_SIZE_MB" "db_dump"

    # Use defaults-extra-file to avoid password in process list
    local MYSQL_CNF=""
    if [ "$DB_CONNECTION" = "mysql" ] || [ "$DB_CONNECTION" = "mariadb" ]; then
        MYSQL_CNF=$(mktemp /tmp/shieldpress_mycnf_XXXXXX)
        chmod 600 "$MYSQL_CNF"
        cat > "$MYSQL_CNF" <<CNFEOF
[client]
user=$DB_USER
password=$DB_PASS
CNFEOF
    fi

    case "$DB_CONNECTION" in
        mysql|mariadb)
            if command -v pv >/dev/null 2>&1 && [ "$DB_SIZE_BYTES" -gt 0 ]; then
                ( set -o pipefail; mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --triggers \
                    "$DB_NAME" | pv -s "$DB_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE" )
            else
                ( set -o pipefail; mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --triggers \
                    "$DB_NAME" | gzip > "$OUT_FILE" )
            fi
            ;;
        pgsql|postgres|postgresql)
            if command -v pv >/dev/null 2>&1 && [ "$DB_SIZE_BYTES" -gt 0 ]; then
                ( set -o pipefail; PGPASSWORD="$DB_PASS" pg_dump \
                    -h 127.0.0.1 \
                    -U "$DB_USER" \
                    -d "$DB_NAME" \
                    --no-owner \
                    --no-privileges | pv -s "$DB_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE" )
            else
                ( set -o pipefail; PGPASSWORD="$DB_PASS" pg_dump \
                    -h 127.0.0.1 \
                    -U "$DB_USER" \
                    -d "$DB_NAME" \
                    --no-owner \
                    --no-privileges | gzip > "$OUT_FILE" )
            fi
            ;;
        *)
            fail "Unsupported DB connection: $DB_CONNECTION"
            return 1
            ;;
    esac

    local STATUS=$?
    [ -n "$MYSQL_CNF" ] && rm -f "$MYSQL_CNF"
    if [ $STATUS -eq 0 ]; then
        show_elapsed "$START_TIME"
    fi
    return $STATUS
}

restore_db_from_sql(){
    local SQL_FILE="$1"
    local FILE_SIZE
    FILE_SIZE=$(stat -c '%s' "$SQL_FILE" 2>/dev/null || echo 0)
    local FILE_SIZE_MB=$((FILE_SIZE / 1024 / 1024))
    local START_TIME
    START_TIME=$(date +%s)

    show_operation_eta "Database import ($DB_CONNECTION)" "$FILE_SIZE_MB" "db_import"

    # Use defaults-extra-file to avoid password in process list
    local MYSQL_CNF=""
    if [ "$DB_CONNECTION" = "mysql" ] || [ "$DB_CONNECTION" = "mariadb" ]; then
        MYSQL_CNF=$(mktemp /tmp/shieldpress_mycnf_XXXXXX)
        chmod 600 "$MYSQL_CNF"
        cat > "$MYSQL_CNF" <<CNFEOF
[client]
user=$DB_USER
password=$DB_PASS
CNFEOF
    fi

    case "$DB_CONNECTION" in
        mysql|mariadb)
            if command -v pv >/dev/null 2>&1 && [ "$FILE_SIZE" -gt 0 ]; then
                pv -s "$FILE_SIZE" -p -t -e -r "$SQL_FILE" | mysql --defaults-extra-file="$MYSQL_CNF" "$DB_NAME"
            else
                mysql --defaults-extra-file="$MYSQL_CNF" "$DB_NAME" < "$SQL_FILE"
            fi
            ;;
        pgsql|postgres|postgresql)
            if command -v pv >/dev/null 2>&1 && [ "$FILE_SIZE" -gt 0 ]; then
                pv -s "$FILE_SIZE" -p -t -e -r "$SQL_FILE" | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME"
            else
                PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" < "$SQL_FILE"
            fi
            ;;
        *)
            fail "Unsupported DB connection: $DB_CONNECTION"
            return 1
            ;;
    esac

    local STATUS=$?
    [ -n "$MYSQL_CNF" ] && rm -f "$MYSQL_CNF"
    if [ $STATUS -eq 0 ]; then
        show_elapsed "$START_TIME"
    fi
    return $STATUS
}

archive_source_to_file(){
    local OUT_FILE="$1"
    local BACKUP_TARGET=""
    local EXCLUDE_OPTS=""
    local SRC_SIZE_MB=0
    local START_TIME

    # Check if backup is disabled for this domain
    if [ "$BK_ENABLED" = "0" ]; then
        warn "Backup disabled for $DOMAIN (BACKUP_ENABLED=0 in backup.env)"
        return 2
    fi

    # === CUSTOM PATHS MODE ===
    # If backup.env has BACKUP_PATHS, use those instead of defaults
    if [ -n "$BK_CUSTOM_PATHS" ]; then
        BACKUP_TARGET="custom"

        # Build targets from comma-separated paths
        local TARGETS=""
        local IFS=','
        for p in $BK_CUSTOM_PATHS; do
            p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$p" ] && continue
            if [ -e "$DOMAIN_PATH/public_html/$p" ]; then
                TARGETS="$TARGETS $p"
            else
                warn "Path not found, skipping: $p"
            fi
        done
        unset IFS

        if [ -z "$TARGETS" ]; then
            fail "No valid BACKUP_PATHS found in backup.env"
            return 1
        fi

        # Custom excludes
        if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
            EXCLUDE_OPTS=$(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")
        fi

        SRC_SIZE_MB=$(du -sm $(for t in $TARGETS; do echo "$DOMAIN_PATH/public_html/$t"; done) 2>/dev/null | awk '{sum+=$1} END{print sum+0}')

        echo "  Mode      : Custom paths (backup.env)"
        echo "  Paths     :$TARGETS"
        [ -n "$EXCLUDE_OPTS" ] && echo "  Exclude   : $BK_CUSTOM_EXCLUDE"

    else
        # === DEFAULT MODE per APP_TYPE ===
        case "$APP_TYPE" in
            laravel)
                BACKUP_TARGET="."
                EXCLUDE_OPTS="--exclude=./vendor --exclude=./node_modules --exclude=./.git --exclude=./backup"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./bootstrap/cache"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./storage/logs/*.log"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./storage/framework/cache/data"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./storage/framework/sessions"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./storage/framework/views"
                # Append custom excludes from backup.env
                if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
                    EXCLUDE_OPTS="$EXCLUDE_OPTS $(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")"
                fi
                SRC_SIZE_MB=$(du -sm "$DOMAIN_PATH/public_html" --exclude="$DOMAIN_PATH/public_html/vendor" --exclude="$DOMAIN_PATH/public_html/node_modules" 2>/dev/null | awk '{print $1}')
                ;;
            nodejs)
                BACKUP_TARGET="."
                EXCLUDE_OPTS="--exclude=./node_modules --exclude=./.git --exclude=./backup"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./.next --exclude=./.nuxt --exclude=./dist --exclude=./build"
                EXCLUDE_OPTS="$EXCLUDE_OPTS --exclude=./.cache --exclude=./.turbo"
                if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
                    EXCLUDE_OPTS="$EXCLUDE_OPTS $(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")"
                fi
                SRC_SIZE_MB=$(du -sm "$DOMAIN_PATH/public_html" --exclude="$DOMAIN_PATH/public_html/node_modules" 2>/dev/null | awk '{print $1}')
                ;;
            *)
                BACKUP_TARGET="public_html"
                EXCLUDE_OPTS=""
                if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
                    EXCLUDE_OPTS=$(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")
                fi
                SRC_SIZE_MB=$(du -sm "$DOMAIN_PATH/public_html" 2>/dev/null | awk '{print $1}')
                ;;
        esac
    fi

    SRC_SIZE_MB=${SRC_SIZE_MB:-0}
    local SRC_SIZE_BYTES=$((SRC_SIZE_MB * 1024 * 1024))
    START_TIME=$(date +%s)

    show_operation_eta "Archive files - $APP_TYPE (tar.gz)" "$SRC_SIZE_MB" "tar_gz"

    if [ "$BACKUP_TARGET" = "custom" ]; then
        # Custom paths: tar specific dirs
        if command -v pv >/dev/null 2>&1 && [ "$SRC_SIZE_BYTES" -gt 0 ]; then
            tar -cf - $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS | pv -s "$SRC_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE"
        else
            tar -czf "$OUT_FILE" $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS
        fi
    elif [ "$BACKUP_TARGET" = "." ]; then
        # Laravel/Node.js: backup from inside public_html
        if command -v pv >/dev/null 2>&1 && [ "$SRC_SIZE_BYTES" -gt 0 ]; then
            tar -cf - $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" . | pv -s "$SRC_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE"
        else
            tar -czf "$OUT_FILE" $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" .
        fi
    else
        # WordPress/PHP: backup public_html directory
        if command -v pv >/dev/null 2>&1 && [ "$SRC_SIZE_BYTES" -gt 0 ]; then
            tar -cf - $EXCLUDE_OPTS -C "$DOMAIN_PATH" public_html | pv -s "$SRC_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE"
        else
            tar -czf "$OUT_FILE" $EXCLUDE_OPTS -C "$DOMAIN_PATH" public_html
        fi
    fi

    local STATUS=$?
    if [ $STATUS -eq 0 ]; then
        show_elapsed "$START_TIME"
    fi
    return $STATUS
}

# ==================================================
# INCREMENTAL ARCHIVE (daily - only changed files)
# ==================================================
# WordPress : only themes + plugins + uploads (skip WP core)
# Laravel   : only files changed in last 24h, skip vendor/node_modules/cache
# Node.js   : only files changed in last 24h, skip node_modules/build

archive_source_incremental(){
    local OUT_FILE="$1"
    local HOURS="${2:-24}"
    local SRC_SIZE_MB=0
    local START_TIME FILE_COUNT=0

    # Check if backup is disabled for this domain
    if [ "$BK_ENABLED" = "0" ]; then
        warn "Backup disabled for $DOMAIN (BACKUP_ENABLED=0 in backup.env)"
        return 2
    fi

    START_TIME=$(date +%s)

    # Build extra find excludes from backup.env INCR_EXCLUDE + BACKUP_EXCLUDE
    local EXTRA_FIND_EXCLUDES=""
    if [ -n "$BK_CUSTOM_INCR_EXCLUDE" ]; then
        EXTRA_FIND_EXCLUDES=$(build_find_excludes "$BK_CUSTOM_INCR_EXCLUDE")
    fi
    if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
        EXTRA_FIND_EXCLUDES="$EXTRA_FIND_EXCLUDES $(build_find_excludes "$BK_CUSTOM_EXCLUDE")"
    fi

    # If backup.env has BACKUP_PATHS, use them for WP-style targeted backup
    if [ -n "$BK_CUSTOM_PATHS" ]; then
        echo "  Mode      : Custom paths from backup.env"

        local TARGETS=""
        local IFS=','
        for p in $BK_CUSTOM_PATHS; do
            p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$p" ] && continue
            [ -e "$DOMAIN_PATH/public_html/$p" ] && TARGETS="$TARGETS $p"
        done
        unset IFS

        if [ -z "$TARGETS" ]; then
            warn "No valid BACKUP_PATHS found"
            return 2
        fi

        local EXCLUDE_OPTS=""
        [ -n "$BK_CUSTOM_EXCLUDE" ] && EXCLUDE_OPTS=$(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")

        echo "  Paths     :$TARGETS"
        [ -n "$BK_CUSTOM_EXCLUDE" ] && echo "  Exclude   : $BK_CUSTOM_EXCLUDE"

        tar -czf "$OUT_FILE" $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS 2>/dev/null
        local STATUS=$?

    else
        case "$APP_TYPE" in
            laravel)
                echo "  Mode      : Incremental (files changed in ${HOURS}h)"
                echo "  Excluding : vendor, node_modules, .git, bootstrap/cache, storage/framework"
                [ -n "$BK_CUSTOM_EXCLUDE" ] && echo "  + Custom  : $BK_CUSTOM_EXCLUDE"

                local TMP_LIST
                TMP_LIST=$(mktemp /tmp/sp_incr_XXXXXX)
                eval find "$DOMAIN_PATH/public_html" -mmin "-$((HOURS * 60))" -type f \
                    -not -path "*/vendor/*" \
                    -not -path "*/node_modules/*" \
                    -not -path "*/.git/*" \
                    -not -path "*/bootstrap/cache/*" \
                    -not -path "*/storage/framework/cache/*" \
                    -not -path "*/storage/framework/sessions/*" \
                    -not -path "*/storage/framework/views/*" \
                    -not -path "*/storage/logs/*" \
                    -not -path "*/backup/*" \
                    $EXTRA_FIND_EXCLUDES \
                    > "$TMP_LIST" 2>/dev/null

                FILE_COUNT=$(wc -l < "$TMP_LIST" | tr -d '[:space:]')
                echo "  Files     : $FILE_COUNT changed"

                if [ "$FILE_COUNT" -eq 0 ]; then
                    echo "  [INFO] No files changed in last ${HOURS}h, skipping."
                    rm -f "$TMP_LIST"
                    return 2
                fi

                tar -czf "$OUT_FILE" -T "$TMP_LIST" --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
                local STATUS=$?
                rm -f "$TMP_LIST"
                ;;

            nodejs)
                echo "  Mode      : Incremental (files changed in ${HOURS}h)"
                echo "  Excluding : node_modules, .git, .next, .nuxt, dist, build, .cache, .turbo"
                [ -n "$BK_CUSTOM_EXCLUDE" ] && echo "  + Custom  : $BK_CUSTOM_EXCLUDE"

                local TMP_LIST
                TMP_LIST=$(mktemp /tmp/sp_incr_XXXXXX)
                eval find "$DOMAIN_PATH/public_html" -mmin "-$((HOURS * 60))" -type f \
                    -not -path "*/node_modules/*" \
                    -not -path "*/.git/*" \
                    -not -path "*/.next/*" \
                    -not -path "*/.nuxt/*" \
                    -not -path "*/dist/*" \
                    -not -path "*/build/*" \
                    -not -path "*/.cache/*" \
                    -not -path "*/.turbo/*" \
                    -not -path "*/backup/*" \
                    $EXTRA_FIND_EXCLUDES \
                    > "$TMP_LIST" 2>/dev/null

                FILE_COUNT=$(wc -l < "$TMP_LIST" | tr -d '[:space:]')
                echo "  Files     : $FILE_COUNT changed"

                if [ "$FILE_COUNT" -eq 0 ]; then
                    echo "  [INFO] No files changed in last ${HOURS}h, skipping."
                    rm -f "$TMP_LIST"
                    return 2
                fi

                tar -czf "$OUT_FILE" -T "$TMP_LIST" --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
                local STATUS=$?
                rm -f "$TMP_LIST"
                ;;

            *)
                # WordPress: only backup themes + plugins + uploads (skip WP core)
                echo "  Mode      : WordPress smart (themes + plugins + uploads only)"

                local WP_ROOT="$DOMAIN_PATH/public_html/wp-content"
                local TARGETS=""
                [ -d "$WP_ROOT/themes" ]  && TARGETS="$TARGETS wp-content/themes"
                [ -d "$WP_ROOT/plugins" ] && TARGETS="$TARGETS wp-content/plugins"
                [ -d "$WP_ROOT/uploads" ] && TARGETS="$TARGETS wp-content/uploads"

                if [ -z "$TARGETS" ]; then
                    echo "  [WARN] No wp-content subdirectories found."
                    return 2
                fi

                local EXCLUDE_OPTS=""
                [ -n "$BK_CUSTOM_EXCLUDE" ] && EXCLUDE_OPTS=$(build_exclude_opts "$BK_CUSTOM_EXCLUDE" ".")

                SRC_SIZE_MB=$(du -sm $(for t in $TARGETS; do echo "$DOMAIN_PATH/public_html/$t"; done) 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
                echo "  Targets   :$TARGETS"
                echo "  Size      : ${SRC_SIZE_MB}MB"
                [ -n "$BK_CUSTOM_EXCLUDE" ] && echo "  + Exclude : $BK_CUSTOM_EXCLUDE"

                tar -czf "$OUT_FILE" $EXCLUDE_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS 2>/dev/null
                local STATUS=$?
                ;;
        esac
    fi

    if [ ${STATUS:-1} -eq 0 ]; then
        show_elapsed "$START_TIME"
    fi
    return ${STATUS:-1}
}

prune_local_backups(){
    local DIR="$1"
    local KEEP="$2"
    local PATTERN="${3:-*.gz}"

    [ -d "$DIR" ] || return 0
    [ "$KEEP" -gt 0 ] 2>/dev/null || return 0
    find "$DIR" -maxdepth 1 -type f -name "$PATTERN" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | awk -v keep="$KEEP" 'NR>keep {sub(/^[^ ]+ /,""); print}' \
        | xargs -r rm -f
}

remote_env_file(){
    echo "$BASE_DIR/config/backup-remote.env"
}

load_remote_config(){
    REMOTE_ENABLED=0
    RCLONE_REMOTE=""
    RCLONE_REMOTES=""
    RCLONE_PATH="shieldpress-backups"
    REMOTE_RETENTION=0
    DELETE_LOCAL_AFTER_UPLOAD=0

    local ENV_FILE
    ENV_FILE=$(remote_env_file)
    [ -f "$ENV_FILE" ] || return 0

    REMOTE_ENABLED=$(grep "^REMOTE_ENABLED=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    RCLONE_REMOTE=$(grep "^RCLONE_REMOTE=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    RCLONE_REMOTES=$(grep "^RCLONE_REMOTES=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '[:space:]')
    RCLONE_PATH=$(grep "^RCLONE_PATH=" "$ENV_FILE" | cut -d'=' -f2- | sed 's#^/##;s#/$##')
    REMOTE_RETENTION=$(grep "^REMOTE_RETENTION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    DELETE_LOCAL_AFTER_UPLOAD=$(grep "^DELETE_LOCAL_AFTER_UPLOAD=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

    REMOTE_ENABLED="${REMOTE_ENABLED:-0}"
    RCLONE_REMOTES="${RCLONE_REMOTES:-$RCLONE_REMOTE}"
    RCLONE_PATH="${RCLONE_PATH:-shieldpress-backups}"
    REMOTE_RETENTION="${REMOTE_RETENTION:-0}"
    DELETE_LOCAL_AFTER_UPLOAD="${DELETE_LOCAL_AFTER_UPLOAD:-0}"
}

remote_upload_backup(){
    local FILE="$1"
    local TYPE="$2"

    load_remote_config
    [ "$REMOTE_ENABLED" = "1" ] || return 0
    [ -n "$RCLONE_REMOTES" ] || { warn "Remote backup enabled but RCLONE_REMOTES is empty"; return 0; }
    command -v rclone >/dev/null 2>&1 || { warn "rclone not installed; remote upload skipped"; return 0; }

    # Validate file exists before attempting upload
    if [ ! -f "$FILE" ]; then
        warn "Remote upload skipped: file not found: $FILE"
        return 1
    fi

    local REMOTE DEST UPLOAD_OK=1
    while read -r REMOTE; do
        REMOTE="${REMOTE%:}"
        [ -z "$REMOTE" ] && continue
        DEST="${REMOTE}:${RCLONE_PATH}/${DOMAIN}/${TYPE}"
        # Use --no-traverse for single-file uploads; omit --create-empty-src-dirs
        # (that flag is for directory copies and creates unexpected empty folders/files
        # on Google Drive when the source is a single file path)
        if rclone copy "$FILE" "$DEST" --no-traverse; then
            ok "Remote uploaded: $DEST/$(basename "$FILE")"
            prune_remote_backups "$DEST" "$REMOTE_RETENTION"
        else
            warn "Remote upload failed: $DEST"
            UPLOAD_OK=0
        fi
    done <<< "$(echo "$RCLONE_REMOTES" | tr ',' '\n')"

    # Delete local file after successful upload if configured
    if [ "$DELETE_LOCAL_AFTER_UPLOAD" = "1" ] && [ "$UPLOAD_OK" = "1" ] && [ -f "$FILE" ]; then
        rm -f "$FILE"
        ok "Local backup deleted: $(basename "$FILE")"
    fi
}

prune_remote_backups(){
    local DEST="$1"
    local KEEP="$2"

    [ "$KEEP" -gt 0 ] 2>/dev/null || return 0
    command -v rclone >/dev/null 2>&1 || return 0

    local TMP
    TMP=$(mktemp /tmp/sp_prune_XXXXXX)
    rclone lsf "$DEST" --files-only 2>/dev/null | sort > "$TMP"
    local COUNT
    COUNT=$(wc -l < "$TMP" | tr -d '[:space:]')
    if [ "$COUNT" -gt "$KEEP" ]; then
        head -n "$((COUNT - KEEP))" "$TMP" | while read -r OLD_FILE; do
            [ -n "$OLD_FILE" ] && rclone deletefile "$DEST/$OLD_FILE" >/dev/null 2>&1
        done
    fi
    rm -f "$TMP"
}

shieldpress_notify_event(){
    local CATEGORY="$1"
    local TITLE="$2"
    local BODY="$3"
    local NOTIFY_SCRIPT="$BASE_DIR/modules/notification/telegram-notify.sh"

    [ -f "$NOTIFY_SCRIPT" ] || return 0
    bash "$NOTIFY_SCRIPT" send "$CATEGORY" "$TITLE" "$BODY" >/dev/null 2>&1 || true
}

# Kiểm tra disk space
check_disk_space(){
    local MIN_MB=$1
    local REQUIRED_MB=${2:-0}
    FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

    if [ "$FREE_MB" -lt "$MIN_MB" ]; then
        fail "Not enough disk space! Only ${FREE_MB}MB free, need ${MIN_MB}MB"
        return 1
    fi
    if [ "$REQUIRED_MB" -gt 0 ] && [ "$FREE_MB" -lt "$REQUIRED_MB" ]; then
        fail "Not enough space: ${FREE_MB}MB free, source is ${REQUIRED_MB}MB"
        return 1
    fi
    return 0
}

# Validate hour input
validate_hour(){
    local H=$1
    [[ "$H" =~ ^[0-9]+$ ]] && [ "$H" -ge 0 ] && [ "$H" -le 23 ]
}

# Build cron schedule
build_cron_schedule(){
    local HOUR=$1
    echo ""
    echo "Backup Frequency:"
    echo "1) Daily"
    echo "2) Weekly (choose day)"
    echo "3) Monthly (choose date)"
    echo "--------------------------------------------------"
    read -p "Select: " FREQ

    case $FREQ in
        1)
            CRON_TIME="0 $HOUR * * *"
            ;;
        2)
            read -p "Day of week (0-6, 0=Sunday): " DOW
            if ! [[ "$DOW" =~ ^[0-6]$ ]]; then
                fail "Invalid day"; return 1
            fi
            CRON_TIME="0 $HOUR * * $DOW"
            ;;
        3)
            read -p "Day of month (1-28): " DOM
            if ! [[ "$DOM" =~ ^[0-9]+$ ]] || [ "$DOM" -lt 1 ] || [ "$DOM" -gt 28 ]; then
                fail "Invalid date (use 1-28)"; return 1
            fi
            CRON_TIME="0 $HOUR $DOM * *"
            ;;
        *)
            fail "Invalid option"; return 1
            ;;
    esac
    return 0
}

# =====================================================
# BACKUP ENCRYPTION HELPERS
# =====================================================

ENCRYPT_KEY_FILE="/etc/shieldpress/backup.key"
ENCRYPT_CONF="/etc/shieldpress/backup-encrypt.env"

# Check if encryption is enabled
backup_encrypt_enabled(){
    [ -f "$ENCRYPT_CONF" ] || return 1
    local val
    val=$(grep "^ENCRYPT_ENABLED=" "$ENCRYPT_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    [ "$val" = "1" ] && [ -f "$ENCRYPT_KEY_FILE" ]
}

# Encrypt file if encryption is enabled. Echoes final file path.
# Usage: FINAL=$(maybe_encrypt_backup "/path/to/file.tar.gz")
maybe_encrypt_backup(){
    local FILE="$1"
    if backup_encrypt_enabled; then
        local KEY ENC_FILE
        KEY=$(cat "$ENCRYPT_KEY_FILE")
        ENC_FILE="${FILE}.enc"
        if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -in "$FILE" -out "$ENC_FILE" -pass "pass:$KEY" 2>/dev/null; then
            rm -f "$FILE"
            log "Encrypted: $ENC_FILE"
            echo "$ENC_FILE"
        else
            warn "Encryption failed, keeping unencrypted: $FILE"
            rm -f "$ENC_FILE"
            echo "$FILE"
        fi
    else
        echo "$FILE"
    fi
}

# Decrypt a .enc file for restore. Echoes decrypted file path.
# Usage: DECRYPTED=$(decrypt_for_restore "/path/to/file.tar.gz.enc")
decrypt_for_restore(){
    local ENC_FILE="$1"
    [ ! -f "$ENCRYPT_KEY_FILE" ] && { fail "Encryption key not found"; return 1; }
    local KEY DEC_FILE
    KEY=$(cat "$ENCRYPT_KEY_FILE")
    DEC_FILE="${ENC_FILE%.enc}"
    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$ENC_FILE" -out "$DEC_FILE" -pass "pass:$KEY" 2>/dev/null; then
        echo "$DEC_FILE"
    else
        fail "Decryption failed. Wrong key or corrupted file."
        rm -f "$DEC_FILE"
        return 1
    fi
}
