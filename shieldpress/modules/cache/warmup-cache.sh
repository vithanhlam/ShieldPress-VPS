#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh
source "$BASE_DIR/core/paths.sh"

# Handle --auto mode for cron execution
AUTO_MODE=0
if [ "$1" = "--auto" ] && [ -n "$2" ]; then
    AUTO_MODE=1
    SELECTED_DOMAIN="$2"
    CLEAN_DOMAIN=$(echo "$SELECTED_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g')
    DOMAIN_PATH="/home/domains/$CLEAN_DOMAIN"
    ROOT="$DOMAIN_PATH/public_html"
    if [ ! -d "$DOMAIN_PATH" ]; then
        echo "Domain not found: $SELECTED_DOMAIN"
        exit 1
    fi
    _ENV="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    PHP_VERSION=$(grep "^PHP_VERSION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    SYSTEM_USER=$(grep "^SYSTEM_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
else
    select_domain || exit 1
fi

WP_CONFIG="$DOMAIN_PATH/public_html/wp-config.php"

LOG_FILE="$LOG_DIR/cache-warmup.log"
mkdir -p "$LOG_DIR"

log(){
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE" >&2
}

# =========================
# CONFIG
# =========================
PARALLEL=10
LIMIT=500
RETRY=2

HIT_COUNT=0
MISS_COUNT=0
FAIL_COUNT=0
TOTAL=0
DONE=0
RESULT_FILE="/tmp/cache-warmup-results-$$.log"
PROGRESS_FILE="/tmp/cache-warmup-progress-$$.log"
touch "$RESULT_FILE" "$PROGRESS_FILE"

cleanup_tmp_files(){
    rm -f "$RESULT_FILE" "$PROGRESS_FILE"
}
trap cleanup_tmp_files EXIT

# =========================
# GET DB INFO
# =========================
get_wp_db_info(){

if [ ! -f "$WP_CONFIG" ]; then
    log "[ERROR] wp-config.php not found!"
    return 1
fi

DB_NAME=$(grep "DB_NAME" "$WP_CONFIG" | cut -d"'" -f4)
DB_USER=$(grep "DB_USER" "$WP_CONFIG" | cut -d"'" -f4)
DB_PASS=$(grep "DB_PASSWORD" "$WP_CONFIG" | cut -d"'" -f4)
DB_HOST=$(grep "DB_HOST" "$WP_CONFIG" | cut -d"'" -f4)
TABLE_PREFIX=$(grep "table_prefix" "$WP_CONFIG" | cut -d"'" -f2)

[ -z "$DB_HOST" ] && DB_HOST="localhost"

echo "$DB_NAME|$DB_USER|$DB_PASS|$DB_HOST|$TABLE_PREFIX"
}

IFS='|' read DB_NAME DB_USER DB_PASS DB_HOST TABLE_PREFIX <<< "$(get_wp_db_info)"

# =========================
# GET SITE URL
# =========================
URL=$(mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -e "
SELECT option_value
FROM ${DB_NAME}.${TABLE_PREFIX}options
WHERE option_name='siteurl' LIMIT 1;
" 2>/dev/null)

if [ -z "$URL" ]; then
    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    SSL=$(grep "^SSL=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
    [ "$SSL" = "enabled" ] && PROTOCOL="https" || PROTOCOL="http"
    URL="${PROTOCOL}://${SELECTED_DOMAIN}"
fi

# normalize URL
URL=$(echo "$URL" | tr -d '[:space:]' | sed 's#/*$##')
if ! echo "$URL" | grep -qiE '^https?://'; then
    URL="https://$URL"
fi

# detect reachable base URL (prefer https)
WARM_BASE=""
BASE_CANDIDATES=(
    "$URL"
    "https://$SELECTED_DOMAIN"
    "https://www.$SELECTED_DOMAIN"
    "http://$SELECTED_DOMAIN"
    "http://www.$SELECTED_DOMAIN"
)
for base in "${BASE_CANDIDATES[@]}"; do
    base=$(echo "$base" | tr -d '[:space:]' | sed 's#/*$##')
    [ -z "$base" ] && continue
    CODE=$(curl -s -k -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$base/")
    if [[ "$CODE" =~ ^[1-5][0-9][0-9]$ ]] && [ "$CODE" != "000" ]; then
        WARM_BASE="$base"
        break
    fi
done
if [ -z "$WARM_BASE" ]; then
    log "[ERROR] Domain is unreachable from this server (connection refused/timeout on both HTTP and HTTPS)."
    log "[ERROR] Please verify DNS, web server (Nginx/Apache), firewall, and vhost mapping for $SELECTED_DOMAIN."
    exit 1
fi
URL="$WARM_BASE"

echo "===================================================="
echo "SMART CACHE WARMUP PRO++ - $SELECTED_DOMAIN"
echo "===================================================="

# =========================
# PROGRESS BAR
# =========================
progress(){
    PERCENT=$((DONE * 100 / TOTAL))
    echo -ne "\rProgress: $DONE/$TOTAL ($PERCENT%)"
}

# =========================
# CURL FUNCTION
# =========================
hit_url(){

    local url=$1
    local req_url="$url"

    if [[ "$WARM_BASE" =~ ^https:// ]] && [[ "$req_url" =~ ^http://([^/]+)(/.*)?$ ]]; then
        host="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
        [ -z "$path" ] && path="/"
        if [[ "$host" == "$SELECTED_DOMAIN" || "$host" == "www.$SELECTED_DOMAIN" ]]; then
            req_url="${WARM_BASE}${path}"
        fi
    fi

    for i in $(seq 1 $RETRY); do

        RESPONSE=$(curl -L --connect-timeout 8 --max-time 25 \
            -k \
            -sS -o /dev/null -D - \
            -A "Mozilla/5.0" \
            -H "Accept: text/html" \
            "$req_url" 2>&1)
        CURL_EXIT=$?

        STATUS=$(echo "$RESPONSE" | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -1 | awk '{print $2}')
        CACHE=$(echo "$RESPONSE" | grep -i "x-cache" | tr -d '\r')

        if [ "$CURL_EXIT" -eq 0 ] && [[ "$STATUS" =~ ^[0-9]{3}$ ]]; then

            if echo "$CACHE" | grep -qi "HIT"; then
                echo "[HIT] $req_url | $CACHE" >> "$LOG_FILE"
                echo ""
                echo "[HIT] $req_url | HTTP $STATUS | $CACHE"
                echo "HIT" >> "$RESULT_FILE"
            else
                echo "[MISS] $req_url | HTTP $STATUS | $CACHE" >> "$LOG_FILE"
                echo ""
                echo "[MISS] $req_url | HTTP $STATUS | $CACHE"
                echo "MISS" >> "$RESULT_FILE"
            fi

            echo 1 >> "$PROGRESS_FILE"
            DONE=$(wc -l < "$PROGRESS_FILE")
            progress
            return 0
        fi

    done

    echo "[FAILED] $req_url | curl_exit=$CURL_EXIT | status=${STATUS:-none}" >> "$LOG_FILE"
    echo ""
    echo "[FAILED] $req_url | curl_exit=$CURL_EXIT | status=${STATUS:-none}"
    echo "FAIL" >> "$RESULT_FILE"
    echo 1 >> "$PROGRESS_FILE"
    DONE=$(wc -l < "$PROGRESS_FILE")
    progress
}

# =========================
# PARALLEL
# =========================
run_parallel(){

    while read -r url; do
        [ -z "$url" ] && continue

        (
            hit_url "$url"
            sleep 0.2
            hit_url "$url"
        ) &

        while [ $(jobs -r | wc -l) -ge $PARALLEL ]; do
            sleep 0.1
        done
    done <<< "$1"

    wait
}

# =========================
# SITEMAP
# =========================
get_sitemap_urls(){

    fetch_sitemap_data(){
        local sm_url="$1"
        local tmp_file
        tmp_file=$(mktemp /tmp/smfetch.XXXXXX)

        curl -sL --connect-timeout 8 --max-time 30 \
            -k \
            --compressed -A "Mozilla/5.0 (CacheWarmupBot)" \
            "$sm_url" -o "$tmp_file"
        [ ! -s "$tmp_file" ] && { rm -f "$tmp_file"; return 1; }

        if gzip -t "$tmp_file" >/dev/null 2>&1; then
            gunzip -c "$tmp_file" 2>/dev/null
        else
            cat "$tmp_file"
        fi

        rm -f "$tmp_file"
    }

    extract_locs(){
        sed 's/></>\n</g' | \
        grep -oiE '<loc[^>]*>.*</loc>' | \
        sed -E 's#^<loc[^>]*>##I; s#</loc>$##I' | \
        sed -E 's#<!\[CDATA\[##g; s#\]\]>##g' | \
        tr -d '\r' | \
        sed 's/&amp;/\&/g' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    normalize_base(){
        echo "$1" | tr -d '[:space:]' | sed 's#/*$##'
    }

    URL_HOST=$(echo "$URL" | sed -E 's#^https?://##I' | cut -d'/' -f1)

    BASE_URLS=()
    BASE_URLS+=("$(normalize_base "$URL")")
    BASE_URLS+=("https://$SELECTED_DOMAIN")
    BASE_URLS+=("http://$SELECTED_DOMAIN")

    if [[ "$SELECTED_DOMAIN" != www.* ]]; then
        BASE_URLS+=("https://www.$SELECTED_DOMAIN")
        BASE_URLS+=("http://www.$SELECTED_DOMAIN")
    fi
    if [[ "$URL_HOST" != www.* ]]; then
        BASE_URLS+=("https://www.$URL_HOST")
        BASE_URLS+=("http://www.$URL_HOST")
    fi

    declare -A SEEN_CANDIDATES
    CANDIDATES=()

    for base in "${BASE_URLS[@]}"; do
        base=$(normalize_base "$base")
        [ -z "$base" ] && continue
        [ -n "${SEEN_CANDIDATES[$base]}" ] && continue
        SEEN_CANDIDATES["$base"]=1

        mapfile -t ROBOT_SITEMAPS < <(
            curl -sL -k --compressed "$base/robots.txt" | awk 'BEGIN{IGNORECASE=1} /^Sitemap:[[:space:]]*/ {print $2}'
        )

        for sm in "${ROBOT_SITEMAPS[@]}"; do
            [ -n "$sm" ] && CANDIDATES+=("$sm")
        done

        CANDIDATES+=("$base/sitemap_index.xml")
        CANDIDATES+=("$base/sitemap.xml")
        CANDIDATES+=("$base/wp-sitemap.xml")
    done

    INITIAL_SITEMAPS=()
    for candidate in "${CANDIDATES[@]}"; do
        [ -z "$candidate" ] && continue
        candidate=$(echo "$candidate" | tr -d '\r' | sed 's/[[:space:]]*$//')
        [ -z "$candidate" ] && continue
        if fetch_sitemap_data "$candidate" | grep -qiE "<(urlset|sitemapindex)[[:space:]>]|<loc[[:space:]>]"; then
            INITIAL_SITEMAPS+=("$candidate")
        fi
    done

    if [ ${#INITIAL_SITEMAPS[@]} -eq 0 ]; then
        log "[WARN] Could not detect valid sitemap (tried multiple http/https + robots.txt sources)"
        return 0
    fi

    log "Using sitemap seeds: ${#INITIAL_SITEMAPS[@]}"
    log "Using sitemap: ${INITIAL_SITEMAPS[0]}"

    declare -A SEEN_SITEMAPS
    declare -A SEEN_URLS
    URL_LIST=()
    SITEMAP_QUEUE=("${INITIAL_SITEMAPS[@]}")

    while [ ${#SITEMAP_QUEUE[@]} -gt 0 ]; do
        SM="${SITEMAP_QUEUE[0]}"
        SITEMAP_QUEUE=("${SITEMAP_QUEUE[@]:1}")

        [ -z "$SM" ] && continue
        [ -n "${SEEN_SITEMAPS[$SM]}" ] && continue
        SEEN_SITEMAPS["$SM"]=1

        log "Reading: $SM"
        DATA=$(fetch_sitemap_data "$SM")
        [ -z "$DATA" ] && continue

        mapfile -t LOCS < <(echo "$DATA" | extract_locs)

        for loc in "${LOCS[@]}"; do
            [ -z "$loc" ] && continue

            if [[ "$loc" == *.xml || "$loc" == *.xml.gz || "$loc" == *sitemap* ]]; then
                [ -z "${SEEN_SITEMAPS[$loc]}" ] && SITEMAP_QUEUE+=("$loc")
            else
                if [ -z "${SEEN_URLS[$loc]}" ]; then
                    SEEN_URLS["$loc"]=1
                    URL_LIST+=("$loc")
                    [ ${#URL_LIST[@]} -ge $LIMIT ] && break 2
                fi
            fi
        done
    done

    printf "%s\n" "${URL_LIST[@]}" | sed '/^$/d' | head -n "$LIMIT"
}

# =========================
# FALLBACK URLS FROM DB
# =========================
get_db_fallback_urls(){
    mysql -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASS" -N -e "
SELECT ID, post_type
FROM ${DB_NAME}.${TABLE_PREFIX}posts
WHERE post_status='publish'
  AND post_type IN ('post','page','product')
ORDER BY post_date DESC;
" 2>/dev/null | awk -v base="$URL" '
BEGIN{
    gsub(/[[:space:]]+$/, "", base);
}
{
    id=$1;
    type=$2;
    if(type=="page"){
        print base "/?page_id=" id;
    } else {
        print base "/?p=" id;
    }
}' | sed '/^$/d' | sort -u | head -n "$LIMIT"
}

# =========================
# FILTER
# =========================
filter_urls(){
    grep -Ev "/(gio-hang|cart|checkout|my-account|wp-admin|wp-login)"
}

# =========================
# CRON SETUP
# =========================
setup_cron(){

    CRON="${1:-0 0 * * *}"
    JOB="bash $0 --auto $SELECTED_DOMAIN"

    CURRENT=$(crontab -l 2>/dev/null)

    echo ""
    echo "======================================"
    echo "        CACHE WARMUP CRON"
    echo "======================================"

    # =========================
    # CHECK EXISTING
    # =========================
    if echo "$CURRENT" | grep -q "$JOB"; then

        echo "Cron already exists:"
        echo "$CRON $JOB"
        echo ""
        echo "1) Re-create (overwrite)"
        echo "2) Remove cron"
        echo "3) Keep current"
        echo "--------------------------------------"
        read -p "Select: " opt

        case $opt in

            1)
                (echo "$CURRENT" | grep -v "$JOB"; echo "$CRON $JOB") | crontab -
                log "[OK] Cron updated ($CRON)"
                ;;

            2)
                echo "$CURRENT" | grep -v "$JOB" | crontab -
                log "[OK] Cron removed"
                ;;

            3)
                log "[OK] Cron unchanged"
                ;;

            *)
                echo "Invalid option"
                ;;
        esac

    else

        # =========================
        # CREATE NEW
        # =========================
        (echo "$CURRENT"; echo "$CRON $JOB") | crontab -
        log "[OK] Cron created ($CRON)"

    fi
}

# =========================
# CRON PREF (ASK BEFORE WARMUP)
# =========================
ask_cron_pref(){
    local default_hour=0
    local default_min=0
    local hour_input
    local min_input
    local cron_expr

    read -p "Setup auto cron? (y/n, default n): " CR

    if [[ "$CR" =~ ^[yY]$ ]]; then
        read -p "Hour (0-23, default $default_hour): " hour_input
        read -p "Minute (0-59, default $default_min): " min_input

        if ! [[ "$hour_input" =~ ^[0-9]+$ ]] || [ "$hour_input" -lt 0 ] || [ "$hour_input" -gt 23 ]; then
            hour_input=$default_hour
        fi

        if ! [[ "$min_input" =~ ^[0-9]+$ ]] || [ "$min_input" -lt 0 ] || [ "$min_input" -gt 59 ]; then
            min_input=$default_min
        fi

        cron_expr="$min_input $hour_input * * *"
        setup_cron "$cron_expr"
    else
        echo "Manual cron: 0 0 * * * bash $0 --auto $SELECTED_DOMAIN"
    fi
}

# =========================
# START
# =========================
ask_cron_pref
log "Loading sitemap..."

URLS=$(get_sitemap_urls | filter_urls)

SITEMAP_URL_COUNT=$(echo "$URLS" | sed '/^$/d' | wc -l)
if [ "$SITEMAP_URL_COUNT" -eq 0 ]; then
    log "[WARN] Sitemap empty/unreachable, fallback to DB published URLs"
    URLS=$(get_db_fallback_urls | filter_urls)
    SITEMAP_URL_COUNT=$(echo "$URLS" | sed '/^$/d' | wc -l)
fi

TOTAL=$((SITEMAP_URL_COUNT * 2 + 2))

log "Found $SITEMAP_URL_COUNT sitemap URLs (total requests: $TOTAL)"

# =========================
# HOMEPAGE
# =========================
hit_url "$URL"
hit_url "$URL"

# =========================
# WARM URLS
# =========================
run_parallel "$URLS"

# =========================
# SUMMARY
# =========================
HIT_COUNT=$(awk '/^HIT$/{c++} END{print c+0}' "$RESULT_FILE")
MISS_COUNT=$(awk '/^MISS$/{c++} END{print c+0}' "$RESULT_FILE")
FAIL_COUNT=$(awk '/^FAIL$/{c++} END{print c+0}' "$RESULT_FILE")

echo ""
echo ""
log "======================"
log "WARMUP SUMMARY"
log "HIT   : $HIT_COUNT"
log "MISS  : $MISS_COUNT"
log "FAIL  : $FAIL_COUNT"
log "======================"

read -p "Press Enter..."
