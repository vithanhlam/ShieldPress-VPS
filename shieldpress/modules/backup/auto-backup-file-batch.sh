#!/bin/bash
# Create one sequential, app-aware file-backup job for many domains.

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
pause(){ echo ""; read -rp "Press Enter..."; }
valid_number(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

clear
echo "===================================================="
echo "              AUTO BACKUP FILE (BATCH)"
echo "===================================================="
echo "  Select multiple domains; each archive runs sequentially."
echo ""
declare -a PATHS DOMAINS TYPES; index=1
for path in "$DOMAINS_ROOT"/*/; do
    env="$path/config/domain.env"; [ -f "$env" ] || continue
    domain=$(grep '^DOMAIN=' "$env" | cut -d= -f2- | tr -d '[:space:]'); [ -n "$domain" ] || continue
    type=$(grep '^APP_TYPE=' "$env" | cut -d= -f2- | tr -d '[:space:]'); type=${type:-wordpress}
    PATHS[$index]="${path%/}"; DOMAINS[$index]="$domain"; TYPES[$index]="$type"
    printf '  %2d) %-35s %s\n' "$index" "$domain" "$type"; ((index++))
done
[ "$index" -gt 1 ] || { echo "No domains found."; pause; exit 1; }
echo "----------------------------------------------------"; read -rp "Choose numbers (e.g. 1,3-5) or 'all': " selected
declare -a PICKED
if [ "$selected" = all ]; then for ((n=1;n<index;n++)); do PICKED+=("$n"); done
else
  IFS=',' read -ra pieces <<< "$selected"
  for piece in "${pieces[@]}"; do
    if [[ "$piece" =~ ^([0-9]+)-([0-9]+)$ ]]; then for ((n=${BASH_REMATCH[1]};n<=${BASH_REMATCH[2]};n++)); do [ -n "${PATHS[$n]}" ] && PICKED+=("$n"); done
    elif [[ "$piece" =~ ^[0-9]+$ ]] && [ -n "${PATHS[$piece]}" ]; then PICKED+=("$piece"); fi
  done
fi
[ "${#PICKED[@]}" -gt 0 ] || { echo "No valid domains selected."; pause; exit 1; }
echo ""; echo "Backup method:"; echo "  1) Smart app backup (recommended: WP content; Laravel/Node source)"; echo "  2) Latest changed files (last 24 hours: uploads/source)"; echo "  3) Full source (excludes dependencies/build cache)"
read -rp "Select (1-3): " mode
case "$mode" in 1) mode=smart;; 2) mode=recent;; 3) mode=full;; *) echo "Invalid method."; pause; exit 1;; esac
while ! valid_number "$RETENTION" 1 30; do read -rp "Keep how many backups per domain (1-30): " RETENTION; done
while ! valid_number "$HOUR" 0 23; do read -rp "Start hour (0-23): " HOUR; done
while ! valid_number "$DELAY" 5 3600; do read -rp "Seconds to wait between domains (5-3600): " DELAY; done
echo "1) Daily   2) Weekly   3) Monthly"; read -rp "Frequency: " freq
case "$freq" in 1) CRON_TIME="30 $HOUR * * *";; 2) while ! valid_number "$dow" 0 6; do read -rp "Day of week (0=Sun): " dow; done; CRON_TIME="30 $HOUR * * $dow";; 3) while ! valid_number "$dom" 1 28; do read -rp "Day of month (1-28): " dom; done; CRON_TIME="30 $HOUR $dom * *";; *) echo "Invalid frequency."; pause; exit 1;; esac

mkdir -p "$BASE_DIR/config/auto-backup"; AUTO_SCRIPT="$BASE_DIR/config/auto-backup/auto-backup-file-batch.sh"
{
cat <<'RUNNER'
#!/bin/bash
set -o pipefail
BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
RUN_LOG_FILE="$LOG_DIR/auto-backup.log"
LOCK_FILE="$DATA_DIR/auto-backup-file-batch.lock"
exec 9>"$LOCK_FILE"; flock -n 9 || { echo "$(date '+%F %T') | SKIP: file batch is already running" >> "$RUN_LOG_FILE"; exit 0; }
backup_one(){
 local domain_path="$1" domain="$2" app_type="$3" mode="$4" retention="$5" date dir file status targets list
 [ -d "$domain_path/public_html" ] || { echo "$(date '+%F %T') | SKIP: $domain source missing" >> "$RUN_LOG_FILE"; return; }
 dir="$domain_path/backup/files"; mkdir -p "$dir"; date=$(date +%F_%H-%M-%S); file="$dir/files_${mode}_$date.tar.gz"; status=1
 case "$mode:$app_type" in
   smart:wordpress|smart:*)
     if [ "$app_type" = wordpress ] && [ -d "$domain_path/public_html/wp-content" ]; then
       targets=""; [ -f "$domain_path/public_html/wp-config.php" ] && targets="wp-config.php"; [ -d "$domain_path/public_html/wp-content/themes" ] && targets="$targets wp-content/themes"; [ -d "$domain_path/public_html/wp-content/plugins" ] && targets="$targets wp-content/plugins"; [ -d "$domain_path/public_html/wp-content/uploads" ] && targets="$targets wp-content/uploads"
       [ -n "$targets" ] && tar -czf "$file" -C "$domain_path/public_html" $targets
     elif [ "$app_type" = laravel ]; then tar -czf "$file" --exclude='./vendor' --exclude='./node_modules' --exclude='./.git' --exclude='./bootstrap/cache' --exclude='./storage/logs' --exclude='./storage/framework/cache' --exclude='./storage/framework/sessions' --exclude='./storage/framework/views' -C "$domain_path/public_html" .
     else tar -czf "$file" --exclude='./node_modules' --exclude='./.git' --exclude='./.next' --exclude='./.nuxt' --exclude='./dist' --exclude='./build' --exclude='./.cache' --exclude='./.turbo' -C "$domain_path/public_html" .; fi ;;
   recent:*)
     list=$(mktemp /tmp/sp_recent_XXXXXX); find "$domain_path/public_html" -type f -mmin -1440 -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -not -path '*/backup/*' > "$list" 2>/dev/null
     [ -s "$list" ] && tar -czf "$file" -T "$list" --transform="s|^$domain_path/public_html/|./|"; status=$?; rm -f "$list"; [ "${status:-1}" -eq 0 ] || { echo "$(date '+%F %T') | SKIP: $domain no changed files" >> "$RUN_LOG_FILE"; rm -f "$file"; return; } ;;
   full:*) tar -czf "$file" --exclude='./node_modules' --exclude='./vendor' --exclude='./.git' --exclude='./.next' --exclude='./.nuxt' --exclude='./dist' --exclude='./build' --exclude='./.cache' --exclude='./.turbo' --exclude='./backup' -C "$domain_path/public_html" . ;;
 esac
 status=$?
 if [ "$status" -eq 0 ] && [ -f "$file" ]; then
   echo "$(date '+%F %T') | SUCCESS: batch files $domain ($mode): $file" >> "$RUN_LOG_FILE"
   find "$dir" -maxdepth 1 -type f -name "files_${mode}_*.tar.gz" -printf '%T@ %p\n' | sort -nr | tail -n +$((retention+1)) | cut -d' ' -f2- | xargs -r rm -f
   source "$BASE_DIR/modules/backup/_backup_helper.sh"; remote_upload_backup "$file" files
 else echo "$(date '+%F %T') | FAILED: batch files $domain ($mode)" >> "$RUN_LOG_FILE"; rm -f "$file"; fi
}
RUNNER
printf 'MODE=%q\nRETENTION=%q\nDELAY=%q\n' "$mode" "$RETENTION" "$DELAY"
printf 'JOBS=(\n'; for n in "${PICKED[@]}"; do printf '  %q\n' "${PATHS[$n]}|${DOMAINS[$n]}|${TYPES[$n]}"; done; printf ')\n'
cat <<'RUNNER'
for job in "${JOBS[@]}"; do IFS='|' read -r path domain type <<< "$job"; backup_one "$path" "$domain" "$type" "$MODE" "$RETENTION"; sleep "$DELAY"; done
RUNNER
} > "$AUTO_SCRIPT"
chmod 700 "$AUTO_SCRIPT"
(crontab -l 2>/dev/null | grep -vF "$AUTO_SCRIPT"; echo "$CRON_TIME $AUTO_SCRIPT") | crontab -
echo ""; echo "[OK] Scheduled ${#PICKED[@]} domains using '$mode' mode ($CRON_TIME)."; echo "     Script: $AUTO_SCRIPT"; pause
