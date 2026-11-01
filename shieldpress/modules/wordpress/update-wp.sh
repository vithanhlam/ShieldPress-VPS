#!/bin/bash
# Interactive updates for one WordPress installation or all managed sites.
# Functions can be sourced by isolated regression checks without starting a job.

config_value() {
    local key="$1" file="$2" line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*) printf '%s\n' "${line#*=}" | tr -d '\r'; return ;;
        esac
    done < "$file"
}

# Validate before arithmetic expansion: shell arithmetic also evaluates input.
valid_number() {
    [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$1 <= $2))
}

load_site() {
    DOMAIN_PATH="$1"
    ROOT="$DOMAIN_PATH/public_html"
    local env_file="$DOMAIN_PATH/config/domain.env" version
    SELECTED_DOMAIN=$(config_value DOMAIN "$env_file")
    SITE_USER=$(config_value SYSTEM_USER "$env_file")
    SITE_USER="${SITE_USER:-${DOMAIN_PATH##*/}}"
    CLEAN_DOMAIN="${DOMAIN_PATH##*/}"
    version=$(config_value PHP_VERSION "$env_file")
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "[FAIL] $SELECTED_DOMAIN: invalid PHP_VERSION in domain.env"
        return 1
    fi
    PHP_SHORT="${version//./}"
    PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
    if [ ! -f "$ROOT/wp-config.php" ] || [ ! -x "$PHP_BIN" ] ||
        [ "$SITE_USER" = root ] || ! id "$SITE_USER" >/dev/null 2>&1; then
        echo "[FAIL] $SELECTED_DOMAIN: missing WordPress, PHP binary or valid site user"
        return 1
    fi
}

wp() {
    # Keep plugin updater hooks loaded (including premium plugin providers).
    # Use the site's PHP and Unix account, never a string evaluated by the shell.
    # The site account's home is not writable, so give WP-CLI its own cache dir
    # (otherwise every run prints "Failed to create directory .../.wp-cli/cache").
    local cache_dir="/var/cache/shieldpress/wp-cli/$SITE_USER"
    [ -d "$cache_dir" ] || install -d -m 700 -o "$SITE_USER" "$cache_dir" 2>/dev/null || cache_dir=/tmp
    sudo -H -u "$SITE_USER" env WP_CLI_CACHE_DIR="$cache_dir" "$PHP_BIN" \
        -d 'error_reporting=E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED' \
        -d display_errors=0 "$WP_CLI_BIN" --path="$ROOT" --no-color "$@" 9>&-
}

ensure_wpcli() {
    WP_CLI_BIN=$(type -P wp || true)
    [ -n "$WP_CLI_BIN" ] || WP_CLI_BIN=/usr/local/bin/wp
    if [ -r "$WP_CLI_BIN" ] && "$PHP_BIN" "$WP_CLI_BIN" --info >/dev/null 2>&1; then
        return 0
    fi
    echo "WP-CLI is missing or invalid. Installing the official verified PHAR..."
    local download_dir expected actual
    download_dir=$(mktemp -d) || return 1
    if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 180 \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o "$download_dir/wp-cli.phar" ||
       ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 60 \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512 \
        -o "$download_dir/checksum"; then
        rm -rf -- "$download_dir"
        return 1
    fi
    read -r expected _ < "$download_dir/checksum"
    actual=$(sha512sum "$download_dir/wp-cli.phar")
    actual=${actual%% *}
    if ! [[ "$expected" =~ ^[a-fA-F0-9]{128}$ ]] ||
       [ "${expected,,}" != "$actual" ] ||
       ! "$PHP_BIN" "$download_dir/wp-cli.phar" --info >/dev/null 2>&1; then
        echo "[FAIL] WP-CLI checksum or PHP compatibility check failed."
        rm -rf -- "$download_dir"
        return 1
    fi
    WP_CLI_BIN=/usr/local/bin/wp
    mkdir -p /usr/local/bin
    if ! install -m 755 "$download_dir/wp-cli.phar" "$WP_CLI_BIN"; then
        rm -rf -- "$download_dir"
        return 1
    fi
    rm -rf -- "$download_dir"
}

find_sites() {
    SITE_PATHS=()
    SITE_NAMES=()
    local path app domain
    for path in "$DOMAINS_ROOT"/*; do
        [ -f "$path/config/domain.env" ] && [ -f "$path/public_html/wp-config.php" ] || continue
        app=$(config_value APP_TYPE "$path/config/domain.env")
        [ -z "$app" ] || [ "$app" = wordpress ] || continue
        domain=$(config_value DOMAIN "$path/config/domain.env")
        [ -n "$domain" ] || continue
        SITE_PATHS+=("$path")
        SITE_NAMES+=("$domain")
    done
}

choose_sites() {
    local choice i
    echo "1) One website"
    echo "2) All WordPress websites (${#SITE_PATHS[@]})"
    echo "0) Back"
    read -rp "Update scope: " choice || return 1
    case "$choice" in
        0) return 1 ;;
        2) TARGET_PATHS=("${SITE_PATHS[@]}"); TARGET_NAMES=("${SITE_NAMES[@]}") ;;
        1)
            for i in "${!SITE_PATHS[@]}"; do echo "$((i + 1))) ${SITE_NAMES[$i]}"; done
            read -rp "Website number (0 = back): " choice || return 1
            valid_number "$choice" "${#SITE_PATHS[@]}" || return 1
            i=$((10#$choice - 1))
            TARGET_PATHS=("${SITE_PATHS[$i]}"); TARGET_NAMES=("${SITE_NAMES[$i]}")
            ;;
        *) echo "Invalid scope."; return 1 ;;
    esac
}

choose_plugins() {
    PLUGIN_MODE=all
    SELECTED_PLUGINS=()
    declare -gA PLUGIN_PREVIEW_ROWS=()
    [[ "$ACTION" = 2 || "$ACTION" = 4 ]] || return 0
    local choice path output slug current target state i token
    local -a tokens
    local -A seen=() selected=() details=()
    echo "1) Update all plugins"
    echo "2) Choose one or more plugins"
    echo "0) Back"
    read -rp "Plugin selection: " choice || return 1
    case "$choice" in
        1) return 0 ;;
        2) PLUGIN_MODE=selected ;;
        *) return 1 ;;
    esac
    echo "Reading installed plugins across selected websites..."
    PLUGIN_CATALOG=()
    for path in "${TARGET_PATHS[@]}"; do
        load_site "$path" || continue
        if ! output=$(component_rows plugin); then
            echo "[WARN] Cannot read plugins on $SELECTED_DOMAIN (see log)."
            continue
        fi
        PLUGIN_PREVIEW_ROWS[$path]="$output"
        while IFS=$'\t' read -r slug current target state; do
            [[ "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || continue
            if [ -z "${seen[$slug]+present}" ]; then
                seen[$slug]=1
                PLUGIN_CATALOG+=("$slug")
            fi
            details[$slug]+="    $SELECTED_DOMAIN: $(version_note "$current" "$target" "$state")"$'\n'
        done <<< "$output"
    done
    if [ "${#PLUGIN_CATALOG[@]}" -eq 0 ]; then
        echo "No plugins available for selection."
        return 1
    fi
    for i in "${!PLUGIN_CATALOG[@]}"; do
        slug=${PLUGIN_CATALOG[$i]}
        echo "$((i + 1))) $slug"
        printf '%s' "${details[$slug]}"
    done
    read -rp "Plugin numbers, separated by spaces or commas (0 = back): " choice || return 1
    choice=${choice//,/ }
    read -ra tokens <<< "$choice"
    [ "${#tokens[@]}" -gt 0 ] || return 1
    for token in "${tokens[@]}"; do
        if ! valid_number "$token" "${#PLUGIN_CATALOG[@]}"; then
            echo "Invalid plugin number: $token"
            return 1
        fi
        slug=${PLUGIN_CATALOG[$((10#$token - 1))]}
        if [ -z "${selected[$slug]+present}" ]; then
            SELECTED_PLUGINS+=("$slug")
            selected[$slug]=1
        fi
    done
}

component_rows() {
    local component="$1" output
    output=$(wp "$component" list --fields=name,status,version,update,update_version --format=json) || return 1
    # JSON handles quoted names/versions correctly; tab-separated output always
    # uses placeholders so Bash cannot collapse empty fields into other columns.
    printf '%s' "$output" | "$PHP_BIN" -r '
        try {
            $rows = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($rows)) { exit(1); }
            foreach ($rows as $row) {
                if (!is_array($row)) { exit(1); }
                if ($argv[1] === "plugin" && !in_array($row["status"] ?? "", ["active", "inactive", "active-network"], true)) { continue; }
                $slug = $row["name"] ?? "";
                if (!preg_match("/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/D", $slug)) { continue; }
                $fields = [$slug, $row["version"] ?? "", $row["update_version"] ?? "", $row["update"] ?? "unknown"];
                $fields = array_map(function ($value) {
                    $value = preg_replace("/[\\x00-\\x1F\\x7F]/", " ", (string)$value);
                    return $value === "" ? "-" : $value;
                }, $fields);
                echo implode("\t", $fields), PHP_EOL;
            }
        } catch (Throwable $error) {
            fwrite(STDERR, "Could not parse WordPress version information." . PHP_EOL);
            exit(1);
        }
    ' "$component"
}

list_updatable_plugins() {
    local output slug rest
    output=$(component_rows plugin) || return 1
    while IFS=$'\t' read -r slug rest; do
        [ -n "$slug" ] && printf '%s\n' "$slug"
    done <<< "$output"
    return 0
}

version_note() {
    local current="$1" target="$2" state="$3"
    [ "$target" != - ] || target=unknown
    case "$state" in
        available) printf '%s -> %s [update available]' "$current" "$target" ;;
        none) printf '%s -> %s [no update reported]' "$current" "$current" ;;
        *) printf '%s -> unknown [update information unavailable]' "$current" ;;
    esac
}

# Prints the available core version (nothing when already up to date).
# Returns 1 for an invalid response and 2 when the check itself failed.
core_update_target() {
    local output
    output=$(wp core check-update --format=json) || return 2
    printf '%s' "$output" | "$PHP_BIN" -r '
        try {
            $rows = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($rows)) { exit(1); }
            if (!$rows) { exit(0); }
            $version = $rows[0]["version"] ?? "";
            if (!preg_match("/^[0-9][a-zA-Z0-9.+_-]*$/D", $version)) { exit(1); }
            echo $version;
        } catch (Throwable $error) { exit(1); }
    '
}

show_core_preview() {
    local current target status=0 suffix=""
    [[ "$ACTION" = 1 || "$ACTION" = 4 ]] || suffix=" (not selected)"
    if ! current=$(wp core version); then
        echo "  WordPress core: unknown [version check failed]$suffix"
        return
    fi
    target=$(core_update_target) || status=$?
    if [ "$status" -eq 2 ]; then
        echo "  WordPress core: $current -> unknown [update check failed]$suffix"
    elif [ "$status" -ne 0 ]; then
        echo "  WordPress core: $current -> unknown [invalid update response]$suffix"
    elif [ -n "$target" ]; then
        echo "  WordPress core: $(version_note "$current" "$target" available)$suffix"
    else
        echo "  WordPress core: $(version_note "$current" "$current" none)$suffix"
    fi
}

# --- Plugin / theme from a local ZIP file -----------------------------------

package_kind() {
    case "$ACTION" in 5) echo plugin ;; 6) echo theme ;; esac
}

# Reads a header value ("Version", "Plugin Name", ...) from a file inside the ZIP.
zip_header() {
    local zip="$1" entry="$2" field="$3" head
    head=$({ unzip -p "$zip" "$entry" 2>/dev/null | head -c 8192; } || true)
    printf '%s\n' "$head" | tr -d '\r' |
        sed -n "s/^[[:space:]*#\\/]*$field:[[:space:]]*//Ip" | head -n 1
}

# Validates the archive and sets PKG_SLUG / PKG_NAME / PKG_VERSION.
inspect_package() {
    local kind="$1" zip="$2" entries entry top="" first main="" name version
    command -v unzip >/dev/null 2>&1 || { echo "[FAIL] 'unzip' is not installed."; return 1; }
    unzip -tq "$zip" >/dev/null 2>&1 || { echo "[FAIL] The file is not a valid ZIP archive."; return 1; }
    entries=$(unzip -Z1 "$zip" | grep -v '^__MACOSX/') || true
    [ -n "$entries" ] || { echo "[FAIL] The ZIP archive is empty."; return 1; }
    while IFS= read -r entry; do
        if [[ "$entry" = /* || "$entry" =~ (^|/)\.\.(/|$) ]]; then
            echo "[FAIL] Unsafe path in ZIP: $entry"
            return 1
        fi
        first=${entry%%/*}
        if [ "$first" = "$entry" ]; then
            echo "[FAIL] The ZIP must contain a single top-level folder (found file: $entry)."
            return 1
        fi
        if [ -z "$top" ]; then
            top=$first
        elif [ "$top" != "$first" ]; then
            echo "[FAIL] The ZIP has more than one top-level folder ($top, $first)."
            return 1
        fi
    done <<< "$entries"
    if ! [[ "$top" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        echo "[FAIL] Unsupported folder name in ZIP: $top"
        return 1
    fi
    if [ "$kind" = theme ]; then
        grep -Fxq "$top/style.css" <<< "$entries" && main="$top/style.css"
        name=$([ -n "$main" ] && zip_header "$zip" "$main" 'Theme Name')
    else
        while IFS= read -r entry; do
            [[ "$entry" =~ ^"$top"/[a-zA-Z0-9._-]+\.php$ ]] || continue
            if [ -n "$(zip_header "$zip" "$entry" 'Plugin Name')" ]; then main=$entry; break; fi
        done <<< "$entries"
        name=$([ -n "$main" ] && zip_header "$zip" "$main" 'Plugin Name')
    fi
    if [ -z "$main" ] || [ -z "$name" ]; then
        echo "[FAIL] This ZIP does not look like a WordPress $kind (no $kind header found)."
        return 1
    fi
    version=$(zip_header "$zip" "$main" 'Version')
    [[ "$version" =~ ^[0-9][a-zA-Z0-9.+_~-]*$ ]] || version=unknown
    PKG_SLUG=$top
    PKG_NAME=${name//[^[:print:]]/ }
    PKG_VERSION=$version
}

cleanup_package() {
    [ -n "$PKG_STAGE" ] && [ -d "$PKG_STAGE" ] && rm -rf -- "$PKG_STAGE"
    PKG_STAGE=""
}

choose_package() {
    [[ "$ACTION" = 5 || "$ACTION" = 6 ]] || return 0
    local kind source answer
    kind=$(package_kind)
    PKG_STAGE=""
    PKG_INSTALL_NEW=0
    read -rp "Path to the $kind ZIP file (empty = back): " source || return 1
    source=${source#\'}; source=${source%\'}; source=${source#\"}; source=${source%\"}
    [ -n "$source" ] || return 1
    if [ ! -f "$source" ] || [ ! -r "$source" ] || [[ "${source,,}" != *.zip ]]; then
        echo "[FAIL] Not a readable .zip file: $source"
        return 1
    fi
    inspect_package "$kind" "$source" || return 1
    # Site accounts run WP-CLI, so stage a copy they can read.
    PKG_STAGE=$(mktemp -d) || return 1
    chmod 755 "$PKG_STAGE"
    PKG_FILE="$PKG_STAGE/package.zip"
    if ! cp -- "$source" "$PKG_FILE" || ! chmod 644 "$PKG_FILE"; then
        echo "[FAIL] Could not stage the ZIP file."
        cleanup_package
        return 1
    fi
    echo "Package: $PKG_NAME (slug $PKG_SLUG, version $PKG_VERSION)"
    read -rp "Also install it on websites where it is not installed yet (left inactive)? [y/N]: " answer || return 1
    case "$answer" in y|Y) PKG_INSTALL_NEW=1 ;; esac
}

package_site_note() {
    local kind="$1" installed
    if ! wp core is-installed >/dev/null 2>&1; then
        echo "unknown [cannot read this WordPress installation]"
        return
    fi
    if ! wp "$kind" is-installed "$PKG_SLUG"; then
        if [ "$PKG_INSTALL_NEW" -eq 1 ]; then
            echo "not installed -> $PKG_VERSION [will be installed, inactive]"
        else
            echo "not installed [skipped]"
        fi
        return
    fi
    installed=$(wp "$kind" get "$PKG_SLUG" --field=version) || installed=unknown
    if [ "$installed" = "$PKG_VERSION" ]; then
        echo "$installed -> $PKG_VERSION [same version, files will be replaced]"
    elif [ "$PKG_VERSION" != unknown ] && [ "$installed" != unknown ] &&
        [ "$(printf '%s\n%s\n' "$installed" "$PKG_VERSION" | sort -V | head -n 1)" = "$PKG_VERSION" ]; then
        echo "$installed -> $PKG_VERSION [WARNING: older than installed]"
    else
        echo "$installed -> $PKG_VERSION [update from file]"
    fi
}

show_component_preview() {
    local component="$1" path="$2" output slug current target state
    if [[ "$component" = plugin && -n "${PLUGIN_PREVIEW_ROWS[$path]+present}" ]]; then
        output=${PLUGIN_PREVIEW_ROWS[$path]}
    elif ! output=$(component_rows "$component"); then
        echo "  [WARN] Could not read $component versions."
        return
    fi
    while IFS=$'\t' read -r slug current target state; do
        [ -n "$slug" ] || continue
        if [[ "$component" = plugin && "$PLUGIN_MODE" = selected ]]; then
            [[ " ${SELECTED_PLUGINS[*]} " = *" $slug "* ]] || continue
        fi
        printf '  %-36s %s\n' "$slug" "$(version_note "$current" "$target" "$state")"
    done <<< "$output"
}

show_update_preview() {
    local path
    echo ""
    echo "=== Version preview (current -> available) ==="
    for path in "${TARGET_PATHS[@]}"; do
        load_site "$path" || continue
        echo "$SELECTED_DOMAIN"
        show_core_preview
        if [[ "$ACTION" = 2 || "$ACTION" = 4 ]]; then show_component_preview plugin "$path"; fi
        if [[ "$ACTION" = 3 || "$ACTION" = 4 ]]; then show_component_preview theme "$path"; fi
        if [[ "$ACTION" = 5 || "$ACTION" = 6 ]]; then
            printf '  %-36s %s\n' "$PKG_SLUG" "$(package_site_note "$(package_kind)")"
        fi
    done
}

backup_site() {
    # Core and plugin upgrades can also change the DB: wp-content alone is
    # insufficient for restoration. Keep the whole installation and DB together.
    local backup_root="$DOMAIN_PATH/backup/files" tar_status=0
    mkdir -p "$backup_root" || return 1
    PRE_UPDATE_BACKUP=$(mktemp -d "$backup_root/pre-update_$(date '+%Y-%m-%d_%H-%M-%S')_XXXXXX") || return 1
    chmod 700 "$PRE_UPDATE_BACKUP" || return 1
    echo "Backing up files and database: $PRE_UPDATE_BACKUP"
    if ! wp db export - --single-transaction --quick --add-drop-table | gzip > "$PRE_UPDATE_BACKUP/database.sql.gz"; then
        echo "[FAIL] Database backup failed. Website will not be updated."
        return 1
    fi
    LC_ALL=C tar -czf "$PRE_UPDATE_BACKUP/wordpress.tar.gz" -C "$ROOT" . \
        2> "$PRE_UPDATE_BACKUP/tar.log" || tar_status=$?
    if [ "$tar_status" -eq 1 ] &&
        grep -Eq '^tar: .+: file changed as we read it$' "$PRE_UPDATE_BACKUP/tar.log" &&
        ! grep -Evq '^tar: .+: file changed as we read it$' "$PRE_UPDATE_BACKUP/tar.log"; then
        echo "[WARN] Files changed during the live backup; checking the archive before continuing."
        cat "$PRE_UPDATE_BACKUP/tar.log"
    elif [ "$tar_status" -ne 0 ]; then
        cat "$PRE_UPDATE_BACKUP/tar.log"
        echo "[FAIL] File backup failed. Website will not be updated."
        return 1
    fi
    if ! gzip -t "$PRE_UPDATE_BACKUP/wordpress.tar.gz" ||
        ! tar -tzf "$PRE_UPDATE_BACKUP/wordpress.tar.gz" >/dev/null; then
        echo "[FAIL] Backup archive validation failed. Website will not be updated."
        return 1
    fi
    printf 'Domain: %s\nDate: %s\nAction: %s\nPlugins: %s\n' \
        "$SELECTED_DOMAIN" "$(date -Is)" "$ACTION" "${SELECTED_PLUGINS[*]:-all}" > "$PRE_UPDATE_BACKUP/manifest.txt"
}

cleanup_backup() {
    [ -n "$PRE_UPDATE_BACKUP" ] || return 0
    case "$PRE_UPDATE_BACKUP" in
        "$DOMAIN_PATH"/backup/files/pre-update_*)
            if rm -rf -- "$PRE_UPDATE_BACKUP"; then
                echo "[OK] Temporary backup removed after successful update."
            else
                echo "[WARN] Could not remove backup: $PRE_UPDATE_BACKUP"
            fi
            ;;
        *) echo "[WARN] Backup path was unexpected; keeping it: $PRE_UPDATE_BACKUP" ;;
    esac
}

purge_site_cache() {
    echo "Clearing caches (object cache, FastCGI page cache, PHP-FPM opcache)..."
    wp cache flush || echo "[WARN] Could not flush the WordPress object cache."
    # Do not purge the legacy shared FastCGI cache for other websites.
    local cache_dir="/var/cache/nginx/$CLEAN_DOMAIN"
    if [ -d "$cache_dir" ]; then
        find "$cache_dir" -type f -delete || echo "[WARN] FastCGI cache purge failed."
    fi
    echo "[OK] Caches cleared for $SELECTED_DOMAIN."
    systemctl reload "php${PHP_SHORT}-php-fpm" || echo "[WARN] PHP-FPM reload failed."
}

update_site() {
    local path="$1" output slug failed=0 multisite
    local -a site_plugins=()
    local -A installed=()
    load_site "$path" || return 1
    echo ""
    echo "=== $SELECTED_DOMAIN ==="
    PRE_UPDATE_BACKUP=""
    if ! wp core is-installed; then
        echo "[FAIL] WordPress/database preflight failed; skipping $SELECTED_DOMAIN."
        return 1
    fi
    if [[ "$ACTION" = 2 || "$ACTION" = 4 ]] && [ "$PLUGIN_MODE" = selected ]; then
        if ! output=$(list_updatable_plugins); then
            echo "[FAIL] Cannot read the plugin list."
            return 1
        fi
        while IFS= read -r slug; do
            [[ "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] && installed[$slug]=1
        done <<< "$output"
        for slug in "${SELECTED_PLUGINS[@]}"; do
            if [ -n "${installed[$slug]+present}" ]; then
                site_plugins+=("$slug")
            else
                echo "[SKIP] $slug is not installed on $SELECTED_DOMAIN."
            fi
        done
        if [ "$ACTION" = 2 ] && [ "${#site_plugins[@]}" -eq 0 ]; then
            echo "[SKIP] No selected plugins installed here."
            return 2
        fi
    fi
    if [[ "$ACTION" = 5 || "$ACTION" = 6 ]]; then
        if ! wp "$(package_kind)" is-installed "$PKG_SLUG" && [ "${PKG_INSTALL_NEW:-0}" -ne 1 ]; then
            echo "[SKIP] $PKG_SLUG is not installed on $SELECTED_DOMAIN."
            return 2
        fi
    fi
    if [ "${BACKUP_ENABLED:-1}" -eq 1 ]; then
        backup_site || return 1
    else
        echo "[INFO] Backup disabled by user."
    fi
    if [[ "$ACTION" = 1 || "$ACTION" = 4 ]]; then
        local target status=0 run_db=1
        target=$(core_update_target) || status=$?
        if [ "$status" -eq 0 ] && [ -z "$target" ]; then
            echo "[OK] WordPress core is already the latest version ($(wp core version)); nothing to download."
        else
            [ "$status" -eq 0 ] || echo "[WARN] Could not check for a core update; trying the update anyway."
            echo "Updating WordPress core..."
            wp core update || { failed=1; run_db=0; }
        fi
        if [ "$run_db" -eq 1 ]; then
            if ! multisite=$(wp eval 'echo is_multisite() ? "yes" : "no";'); then
                failed=1
            elif [ "$multisite" = yes ]; then
                wp core update-db --network || failed=1
            else
                wp core update-db || failed=1
            fi
        fi
    fi
    if [[ "$ACTION" = 2 || "$ACTION" = 4 ]]; then
        if [ "$PLUGIN_MODE" = all ]; then
            wp plugin update --all || failed=1
        elif [ "${#site_plugins[@]}" -gt 0 ]; then
            wp plugin update "${site_plugins[@]}" || failed=1
        fi
    fi
    if [[ "$ACTION" = 3 || "$ACTION" = 4 ]]; then
        wp theme update --all || failed=1
    fi
    if [[ "$ACTION" = 5 || "$ACTION" = 6 ]]; then
        local kind installed
        kind=$(package_kind)
        echo "Installing $kind $PKG_SLUG from the ZIP file..."
        if wp "$kind" install "$PKG_FILE" --force; then
            installed=$(wp "$kind" get "$PKG_SLUG" --field=version) || installed=""
            if [ "$PKG_VERSION" != unknown ] && [ "$installed" != "$PKG_VERSION" ]; then
                echo "[FAIL] Installed version is '${installed:-unknown}', expected $PKG_VERSION."
                failed=1
            fi
        else
            failed=1
        fi
    fi
    purge_site_cache
    if [ "$failed" -ne 0 ]; then
        echo "[FAIL] $SELECTED_DOMAIN: update finished with errors."
        [ -z "$PRE_UPDATE_BACKUP" ] || echo "Backup retained for recovery: $PRE_UPDATE_BACKUP"
        return 1
    fi
    echo "[OK] $SELECTED_DOMAIN: update commands completed successfully."
    cleanup_backup
}

run_updates() {
    local path result ok=0 failed=0 skipped=0
    for path in "${TARGET_PATHS[@]}"; do
        update_site "$path"
        result=$?
        case "$result" in
            0) ok=$((ok + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done
    echo ""
    echo "Completed: $ok successful, $failed failed, $skipped skipped."
    echo "Log: $LOG_FILE"
    [ "$failed" -eq 0 ]
}

main() {
    set -o pipefail
    umask 077
    BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
    source "$BASE_DIR/core/paths.sh" || return 1
    if [ "$EUID" -ne 0 ]; then echo "Please run ShieldPress as root."; return 1; fi
    mkdir -p "$LOG_DIR" "$DATA_DIR" || return 1
    LOG_FILE="$LOG_DIR/wp-update.log"
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE" || return 1
    exec > >(tee -a "$LOG_FILE") 2>&1
    exec 9>"$DATA_DIR/wp-update.lock"
    flock -n 9 || { echo "Another WordPress update is running."; return 1; }
    find_sites
    if [ "${#SITE_PATHS[@]}" -eq 0 ]; then echo "No WordPress websites found."; return 1; fi
    echo "=== WordPress Core / Plugin / Theme Updates ==="
    choose_sites || return 0
    echo "1) WordPress core"
    echo "2) Plugins"
    echo "3) Themes"
    echo "4) Core + plugins + themes"
    echo "5) Plugin from a local ZIP file (update/install on the selected websites)"
    echo "6) Theme from a local ZIP file (update/install on the selected websites)"
    echo "0) Back"
    read -rp "Update action: " ACTION || return 0
    case "$ACTION" in
        0) return 0 ;;
        [1-6]) ;;
        *) echo "Invalid action."; return 1 ;;
    esac
    # Find a usable PHP runtime for WP-CLI setup without excluding failed sites
    # from the final batch summary.
    local path ready=0 confirm backup_choice
    for path in "${TARGET_PATHS[@]}"; do
        if load_site "$path"; then ready=1; break; fi
    done
    [ "$ready" -eq 1 ] || return 1
    ensure_wpcli || { echo "[FAIL] WP-CLI is unavailable. No websites updated."; return 1; }
    choose_plugins || return 0
    choose_package || return 0
    trap cleanup_package EXIT
    show_update_preview
    echo ""
    echo "Websites (${#TARGET_PATHS[@]}): ${TARGET_NAMES[*]}"
    echo "Action: $ACTION (1=core, 2=plugins, 3=themes, 4=all, 5=plugin ZIP, 6=theme ZIP)"
    if [[ "$ACTION" = 5 || "$ACTION" = 6 ]]; then
        echo "Package: $PKG_NAME $PKG_VERSION ($PKG_SLUG) from a local ZIP file"
    fi
    if [[ "$ACTION" = 2 || "$ACTION" = 4 ]]; then
        echo "Plugins: ${SELECTED_PLUGINS[*]:-all installed plugins}"
    fi
    read -rp "Create file and database backup before updating? [Y/n]: " backup_choice || return 0
    case "$backup_choice" in
        ''|y|Y) BACKUP_ENABLED=1; echo "Backups: removed after successful updates; retained after failed updates." ;;
        n|N) BACKUP_ENABLED=0; echo "Backups: disabled for this run." ;;
        *) echo "Invalid backup choice. No websites updated."; return 1 ;;
    esac
    read -rp "Start updates? [y/N]: " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled. No websites updated."; return 0; }
    echo "Started: $(date -Is)"
    run_updates
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    UPDATE_RESULT=$?
    read -rp "Press Enter..." _ || true
    exit "$UPDATE_RESULT"
fi
