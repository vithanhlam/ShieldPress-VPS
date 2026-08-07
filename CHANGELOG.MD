# ShieldPress VPS - Changelog

## v1.4.0 — 2026-08-06 — Email: SSL Fix on Reinstall, Webmail Reinstall Option, Optional HTTP Auth

### Email Server — Fix SSL on Reinstall (`modules/email/install-email.sh`)

**Problem:** Uninstalling and reinstalling the email server caused SSL to break for `mail.domain.com`. During reinstall, the installer always ran `certbot certonly --standalone` from scratch, which could fail if the certificate was not yet due for renewal or if there was a timing conflict with the existing Let's Encrypt cert.

**Fix:** The installer now checks whether a valid Let's Encrypt certificate already exists at `/etc/letsencrypt/live/mail.${MAIL_DOMAIN}/fullchain.pem` before calling certbot.

- If the certificate **exists and is valid** (not expired within 24h): reused directly — `smtpd_tls_cert_file` / `smtpd_tls_key_file` in Postfix and `ssl_cert` / `ssl_key` in Dovecot are updated without running certbot. Expiry date is shown.
- If the certificate **does not exist or is expired**: certbot runs as before (stops Nginx, standalone challenge, restarts Nginx).
- Error message updated to point to the new **[12] Install SSL** menu item instead of suggesting a full reinstall.

---

### Email Menu — New [12] Install SSL (mail) (`modules/email/email-menu.sh`, `modules/email/install-ssl-mail.sh`)

Added a dedicated **Install SSL (mail)** option as a standalone action, accessible any time without reinstalling the email server.

**New script `install-ssl-mail.sh`:**
- Shows current certificate status and expiry date (if cert exists)
- Option to force-renew even if cert is still valid
- Checks DNS: verifies `mail.domain.com` A record points to this server before running certbot
- Stops Nginx temporarily, runs `certbot certonly --standalone`, restarts Nginx
- On success: applies cert to Postfix + Dovecot and restarts both services
- On failure: shows diagnostic command

**Menu change:**
- `[12] Install SSL (mail)` — new
- `[13] Uninstall Email Server` — shifted from 12

---

### Webmail — Add Reinstall Option, Remove Redundant SMTP Fix (`modules/email/webmail-info.sh`)

**[4] option changed:**
- **Removed:** `[4] Fix SMTP config error (cannot send email)` — this fix is now handled automatically by the migration patch `SP_138_FIX_WEBMAIL_SMTP` (added in v1.3.8) which runs on update. The manual option is no longer needed.
- **Added:** `[4] Reinstall Webmail` — uninstalls Roundcube and immediately reinstalls it (calls `uninstall-webmail.sh` then `install-webmail.sh`). Asks for confirmation before proceeding.

---

### Webmail — HTTP Basic Auth Now Optional (`modules/email/install-webmail.sh`)

**Before:** Installation always required entering an HTTP Basic Auth username and password.

**After:** HTTP Auth setup is optional and context-aware:

- **If `.webmail_htpasswd` already exists** (set via Webmail settings → [1] Change HTTP Auth password, or from a previous install): prompts `Keep existing HTTP Auth? (Y/n)` — default Y. Existing credentials are preserved without re-entry.
- **Fresh install / no existing auth:** prompts `Set up HTTP Basic Auth? (y/N)` — default N. Skipping is the default; auth can be configured later from Webmail settings [1].
- The Nginx vhost now conditionally includes `auth_basic` / `auth_basic_user_file` only when a `.webmail_htpasswd` file is present — no Nginx errors when auth is skipped.
- Success screen adapts: shows auth username if configured, or a note to set it up later via settings [1].

---

## v1.3.9 — 2026-08-05 — Backup: Fix Unexpected Files on Google Drive After Upload

### Remote Backup Upload Fix (`modules/backup/_backup_helper.sh`, `modules/backup/remote-backup.sh`)

**Problem:** After backing up and uploading to Google Drive, an unexpected file with an unrecognized name appears in the remote storage.

**Root causes (two bugs):**

- **[Bug 1] `--create-empty-src-dirs` on single-file copy:** `rclone copy "$FILE" "$DEST" --create-empty-src-dirs` — this flag instructs rclone to replicate empty subdirectories from the source into the destination. When the source is a single file (not a directory), rclone may traverse the parent directory path and create placeholder entries on Google Drive, resulting in unexpected files/folders appearing alongside the actual backup. **Fix:** replaced with `--no-traverse` (tells rclone to skip the directory listing and upload the single file directly — faster and creates no side-effect entries).

- **[Bug 2] Test upload leaves `_test/` folder on Google Drive:** `test_remote()` used `rclone deletefile` to remove the test file after a successful test, but did **not** remove the `_test/` directory itself. The empty `_test/` folder (and the test file if `deletefile` failed silently) remained permanently in the remote. **Fix:** after deleting the test file, now also calls `rclone rmdir` to remove the empty `_test/` directory.

**Additional fix:** `prune_remote_backups()` now uses a named `mktemp` template (`/tmp/sp_prune_XXXXXX`) instead of anonymous `mktemp`, making temp files identifiable in `/tmp` if cleanup fails.

**Added:** file existence check in `remote_upload_backup()` — warns and skips upload if the backup file is not found instead of letting rclone error silently.

---

## v1.3.8 — 2026-08-05 — Webmail: Fix SMTP Config Error (Cannot Send Email)

### Roundcube SMTP Config Fix (`modules/email/install-webmail.sh`, `modules/email/webmail-info.sh`)

**Problem:** Roundcube shows "SMTP config error" when attempting to send email.

**Root causes (two separate bugs):**

- **[Bug 1] Duplicate port in `smtp_host`:** The config set `smtp_host = 'tls://localhost:587'` (port embedded in the host string) AND `smtp_port = 587` as a separate key. Roundcube/Net_SMTP parses the host string and tries to connect using the embedded port; having `smtp_port` set simultaneously causes a conflict that results in the SMTP config error.
- **[Bug 2] Missing `allow_self_signed`:** `smtp_conn_options` had `verify_peer => false` and `verify_peer_name => false` but was missing `allow_self_signed => true`. On some PHP/OpenSSL builds, the STARTTLS handshake with Postfix's self-signed certificate is still rejected even with `verify_peer = false` unless `allow_self_signed` is explicitly set.

**Fix — new installs (`install-webmail.sh`):**
- `smtp_host` changed to `tls://localhost` (no embedded port).
- `smtp_port = 587` kept as a dedicated key.
- Added `allow_self_signed => true` to both `smtp_conn_options` and `imap_conn_options`.
- Removed redundant `default_host` and `default_port` keys (superseded by `imap_host`).

**Fix — existing installs (`webmail-info.sh` → option [4] Fix SMTP config error):**
- New menu option that patches a running Roundcube config in-place without reinstalling.
- Rewrites `smtp_host` to `tls://localhost`, ensures `smtp_port = 587`, and injects `allow_self_signed => true` into both SMTP and IMAP conn_options.
- Removes leftover `default_host` / `default_port` entries if present.

---

## v1.3.7 — 2026-08-05 — Email: Amazon SES SMTP Credentials, Optional Password Confirm

### Amazon SES SMTP Credentials (`modules/email/install-email.sh`, `modules/email/setup-relay.sh`)

**Problem:** The SES relay setup prompted for "Access Key ID" and "Secret Access Key" (IAM terminology), which are **not** the correct credentials for SES SMTP. SES SMTP requires a separate set of credentials generated from *SES Console → SMTP Settings → Create SMTP Credentials*.

**Fix:**
- Renamed input labels from `SES Access Key ID / SES Secret Access Key` → `SES SMTP Username / SES SMTP Password` in both `install-email.sh` and `setup-relay.sh`.
- `SES SMTP Password` input is now hidden (`-sp` flag) to prevent the password from appearing on screen.
- Added a hint line pointing users to the correct location: *"Go to: SES Console → SMTP Settings → Create SMTP Credentials — SMTP Username and Password are separate from IAM credentials."*

---

### Optional Password Confirmation (`modules/email/install-email.sh`)

**Change:** During email server installation, the "Confirm password" step is now optional.

- After entering the password, a prompt `Confirm password? (y/N):` appears. Default is **N** (press Enter to skip).
- Choosing **N** accepts the password immediately without re-entry — faster for experienced users.
- Choosing **Y** requires typing the password a second time to confirm, identical to the previous behavior.

---

## v1.3.6 — 2026-08-03 — Security Hardening, MySQL/PHP Slow Log, SSL Fix, Auto-Guard

### Security Hardening (9 fixes)

**Files:** `core/helpers.sh`, `modules/security/security-menu.sh`, `modules/domain/helpers.sh`, `modules/isolation/isolation-menu.sh`, `modules/database/export-db.sh`, `modules/sftp/sftp-manager.sh`, `modules/wordpress/secure-wp.sh`, `modules/database/create-db.sh`

- **[C1]** `validate_ip()` — Validates each octet in the range 0–255 and CIDR prefix 0–32, instead of only checking the format pattern.
- **[C2]** `domain.env` + `config/` — Changed permissions to `root:root 700/600` so that the domain Linux user cannot read DB or SFTP passwords stored in `domain.env`. Applied automatically for new domains; existing domains are updated by running `Isolation → Repair All`.
- **[C3]** `export-db.sh` — `mysqldump` now uses `--defaults-extra-file` (temp file with mode 600) instead of passing `-p"$PASS"` on the command line, preventing password exposure via `ps aux`.
- **[H1]** `helpers.sh` — `mysql_defaults_file()` now applies `chmod 600` before writing credentials and uses `printf` instead of a heredoc, narrowing the race window between file creation and content write.
- **[H2]** PHP `open_basedir` — Removed the shared `/tmp` from `open_basedir` (which allowed cross-domain reads); replaced with the per-domain `$DOMAIN_PATH/tmp`. Applied to new domain creation and to `apply_open_basedir_all` in the isolation repair tool.
- **[H5]** `isolation-menu.sh` — `SYSTEM_USER` is now validated against `[a-zA-Z0-9_-]` before being passed to `chown`, preventing path traversal if `domain.env` is tampered with.
- **[H6]** Security menu — IP is now validated with `validate_ip()` before calling `fail2ban-client set sshd unbanip`.
- **[M1]** `log_ip_event()` — Strips `\n`, `\r`, and `|` from all user-controlled fields before writing to the IP history log, preventing log injection.
- **[M5/M6]** Increased entropy: WP salt fallback now uses `openssl rand -base64 48`; DB password length increased from 16 to 24 characters.

---

### MySQL Slow Query Log Viewer (`modules/monitor/monitor-menu.sh` — option 10)

Added **MySQL Slow Query Log Viewer** (Monitor menu → option 10):
- Checks whether `slow_query_log` is enabled in MariaDB/MySQL and offers to enable it if not (configurable `long_query_time`, persisted to `/etc/my.cnf.d/shieldpress-slow.cnf`).
- Analysis views: top 10 slowest queries (`mysqldumpslow -s t`), top 10 most frequent slow queries, summary stats (total count, average time, max time, top databases by slow query count).
- Option to disable slow query logging from the menu.

### PHP Slow Log Analyzer (`modules/monitor/monitor-menu.sh` — option 11)

Added **PHP Slow Log Analyzer** (Monitor menu → option 11):
- Select a domain to read its `$LOG_DIR_PHP_SLOW/{domain}-slow.log`.
- Views: top 10 slow scripts by frequency, summary stats (total entries, average and max execution time), last 30 raw log entries.

---

### SSL Fix — Multi-Provider Detection (`modules/ssl/check-ssl-status.sh`)

**Problem:** `check-ssl-status.sh` hardcoded the path `/etc/letsencrypt/live/$DOMAIN/fullchain.pem` for all SSL providers, causing ZeroSSL, Cloudflare Origin, and Custom certificates to show as `disabled` even when correctly installed.

**Fix:**
- Reads `SSL_TYPE` from `domain.env` and resolves the correct certificate path per provider:
  - `letsencrypt` / `zerossl` → `/etc/letsencrypt/live/$DOMAIN/fullchain.pem`
  - `cloudflare` → `/etc/nginx/ssl/{clean}/cloudflare-origin.pem`
  - `custom` → `/etc/nginx/ssl/{clean}/fullchain.pem`
- Auto-detects the certificate type for older domains that do not yet have `SSL_TYPE` set.
- Added a **Provider** column to the status table (Let's Encrypt / ZeroSSL / Cloudflare / Custom).
- Checks both `certbot.timer` and `acme.sh` cron for ZeroSSL auto-renew status.

---

### Auto-Guard — Automated Attacker Blocking (`modules/security/security-menu.sh` — option 18)

Added **Auto-Guard** (Security menu → option 18):
- Configurable thresholds for total requests, 4xx errors, and wp-login/xmlrpc hits over the last 10 minutes.
- Runs automatically on a **systemd timer** (default every 5 minutes, configurable).
- When any threshold is exceeded: triggers `auto_block_attackers`, writes to the auto-guard log, and sends a Telegram notification.
- Security dashboard compact now shows Auto-Guard status (ENABLED / off).
- Management menu: enable / reconfigure, disable, view log, run an immediate check.

---

## v1.3.1 — 2026-08-01 - Email Server: Webmail Session Fix, WordPress SMTP Guide & Cloudflare Warning

### Webmail Session Logout Fix (`modules/email/install-webmail.sh`, `modules/email/webmail-info.sh`)

**Problem:** Roundcube webmail logs users out unexpectedly, especially behind NAT, VPN, or mobile networks.

**Root cause:** `$config['ip_check'] = true` causes Roundcube to invalidate the session whenever the client IP changes mid-session. On shared NAT or networks where IP can rotate, this triggers a logout on nearly every page load.

**Fix — new installs:** `install-webmail.sh` now generates config with `ip_check = false` and `session_lifetime = 60` (was 30 minutes).

**Fix — existing installs:** `webmail-info.sh` now shows a session health indicator and a new option **[3] Fix session logout** that patches the running Roundcube config in-place (`/var/www/webmail/config/config.inc.php`) without reinstalling.

---

### WordPress SMTP Guide (`modules/email/client-guide.sh`)

Added **section 7 — WordPress SMTP** to the Client Setup Guide:
- Correct settings: Host = `mail.domain`, Port = `587`, Encryption = **TLS** (not SSL), Username = **full email address**
- Step-by-step instructions for WP Mail SMTP plugin
- Common mistakes table: SSL vs TLS, partial username vs full email
- Note on disabling SSL verification when using self-signed certificate

---

### WordPress SMTP Test (`modules/email/test-email.sh`)

Added **option [5] — Test WordPress SMTP** that simulates exactly how a WordPress SMTP plugin connects:
1. Checks port 587 is listening
2. Tests STARTTLS handshake
3. Runs SMTP AUTH PLAIN with the selected account credentials

On success: shows correct plugin settings side-by-side.
On failure: shows the specific cause (wrong password, account missing, SASL not connected to Postfix) with debug commands.

---

### Cloudflare Proxy Warning — Email Ports (`modules/email/dns-guide.sh`, `client-guide.sh`, `test-email.sh`)

**Problem confirmed:** When Cloudflare proxy (orange cloud) is enabled on the `mail` A record, ports 25, 587, and 993 are blocked. SMTP and IMAP connections from all clients (WordPress, Outlook, Thunderbird, mobile) fail even though the server itself is working correctly.

**Changes:**
- `dns-guide.sh` — A record entry now shows `Proxy: DNS only (grey cloud) — NEVER orange cloud` with a highlighted warning block explaining why
- `client-guide.sh` — Troubleshooting section now includes a dedicated **"Using Cloudflare?"** block with step-by-step instructions to set the `mail` record to grey cloud
- `test-email.sh` — WordPress SMTP test success message now includes Cloudflare as item #4 to check if WordPress still fails after server auth passes

---

## v1.3.0 — 2026-07-31 - SSL Overhaul, ZeroSSL, Cache & DB Import Improvements

### ZeroSSL Support (`modules/ssl/install-ssl-zerossl.sh`, `modules/ssl/ssl-menu.sh`)

Added ZeroSSL as a free SSL alternative to Let's Encrypt with less strict rate limits.

- Fully automatic — EAB credentials generated via ZeroSSL API, no manual registration needed
- Falls back to manual EAB input if API is unavailable
- Credentials saved to `config/zerossl-eab.env` for reuse
- Auto-renew via `certbot.timer` (certbot auto-detects ACME server per cert)
- Added progress message during ACME challenge ("This may take 1-2 minutes...")
- SSL menu updated: option 2 = ZeroSSL

### SSL Install Bug Fixes (`modules/ssl/install-ssl-cloudflare.sh`, `install-ssl.sh`, `install-ssl-custom.sh`)

**BUG — Duplicate SSL directives break Nginx (CRITICAL)**
- `sed` patterns like `/listen 80/a\...` matched both `listen 80;` and `listen [::]:80;`, inserting SSL directives twice → Nginx syntax error → rollback
- Fix: All `sed` append commands now use `0,/pattern/{/pattern/a\...}` to match only the first occurrence
- Also adds `listen [::]:443 ssl;` alongside `listen 443 ssl;` for proper IPv6 support

**BUG — Nginx errors hidden**
- `nginx -t 2>/dev/null` suppressed all error output → user sees "rolling back" with no explanation
- Fix: Captures error with `nginx -t 2>&1` and displays it before rollback

### SSL Type Switching (`modules/ssl/ssl-utils.sh`, `modules/ssl/remove-ssl.sh`)

Added `cleanup_old_ssl()` helper to safely switch between SSL types without conflicts.

- Called automatically by all 4 install scripts before installing new cert
- Removes old certbot certs (Let's Encrypt / ZeroSSL) via `certbot delete`
- Removes old cert files (Cloudflare / Custom) from `/etc/nginx/ssl/`
- Cleans all SSL directives from Nginx config (listen 443, ssl_certificate, HSTS, http2, etc.)
- `remove-ssl.sh` rewritten to use `cleanup_old_ssl()` — now handles all SSL types, not just certbot

### Cloudflare SSL UX Improvements (`modules/ssl/install-ssl-cloudflare.sh`)

- **No more Ctrl+D**: Paste auto-detects `-----END CERTIFICATE-----` / `-----END PRIVATE KEY-----` markers
- **File path input**: Option to provide cert/key file paths instead of pasting
- **Step-by-step guide**: Detailed 8-step instructions for creating Origin Certificate on Cloudflare dashboard
- **Better validation**: Shows SAN domains from cert, cleans up files on validation failure
- **Sudoers fix** (`install-wp.sh`): Changed `%www-data` to `ALL ALL` — PHP-FPM runs as domain user, not www-data

### Database Import — Table Prefix Check (`modules/database/import-domain.sh`)

After importing a database into a WordPress domain, the script now detects table prefix mismatches:

- Reads `$table_prefix` from `wp-config.php`
- Detects actual prefix from imported tables (finds `*_options` table)
- If mismatched, offers 3 options:
  1. Update `wp-config.php` to match DB (recommended, with backup)
  2. Rename all DB tables to match wp-config + update `wp_options` and `wp_usermeta` meta keys
  3. Skip

### Auto Cache Purge on Import & Permission Fix (`core/helpers.sh`, `modules/database/import-domain.sh`, `modules/domain/fix-permission.sh`, `modules/optimize/permission-fix.sh`)

- Added `purge_wp_cache()` helper in `core/helpers.sh` — clears FastCGI cache, Valkey/Redis, WP object cache, and reloads PHP-FPM OPcache
- Called automatically after DB import (WordPress domains only)
- Called automatically after fixing permissions (single domain and all-domains)

### WordPress Cache Purge Button — Complete Rewrite (`templates/wp-mu-plugins/shieldpress-cache-purge.php`, `bin/process-purge-signals`)

**BUG — White screen when clicking Purge Cache**
- Old URL `admin.php?shieldpress_purge=1` has no page handler → blank page
- Fix: Changed to `admin-post.php?action=shieldpress_purge` with `wp_safe_redirect()` back to referrer

**BUG — Purge never works due to 3 layered restrictions**
- `exec()` disabled via `php_admin_value[disable_functions]` in PHP-FPM pool → Method 1 (sudo script) always fails
- `open_basedir` restricts PHP to domain directory → `is_dir('/var/cache/nginx/...')` returns false → Method 2 (direct delete) fails
- `PrivateTmp=true` in systemd PHP-FPM service → PHP's `/tmp` is isolated from system `/tmp` → file signal to `/tmp` invisible to cron

**Fix — Domain tmp file signal approach:**
- PHP writes signal file to `$DOMAIN_PATH/tmp/.purge-cache` (always accessible: within `open_basedir`, not affected by `PrivateTmp`, no `exec` needed)
- Cron job (`/etc/cron.d/shieldpress-cache-purge`) runs every minute as root, scans `/home/domains/*/tmp/.purge-cache`, executes actual cache purge
- New script: `bin/process-purge-signals` — processes signal files and runs `purge-fastcgi-cache`
- `auto-purge.sh` and `install-wp.sh` updated to setup cron job automatically

**BUG — Always shows "success" even when purge fails**
- Fix: `purge()` returns `'ok'` or `'fail'`; notice shows green success or red error with fix instructions

**UI — Icon**: Changed from emoji to WordPress dashicon `dashicons-update`

---

## v1.2.9 — 2026-07-31 - Monitor Metrics Sync & Bug Fixes

### WordPress Install Fix (`modules/wordpress/helpers.sh`, `modules/wordpress/install-wp.sh`)

**Problem:** Installing WordPress fails with `ERROR: PHP socket not found: /var/opt/remi/php84/run/php-fpm/.sock` — domain name missing from socket path.

**Root cause:** `select_domain()` in `helpers.sh` correctly computes `CLEAN_DOMAIN` at line 48 via `domain_to_clean()`, but then line 69 overwrites it with `grep "^CLEAN_DOMAIN=" domain.env` which returns empty because `domain.env` was never created with a `CLEAN_DOMAIN=` line.

**Fix (3 files):**
- `modules/wordpress/helpers.sh` — Only overwrite `CLEAN_DOMAIN` if grep returns a non-empty value
- `modules/wordpress/reset-password.sh` — Same fix
- `modules/domain/helpers.sh` — Added `CLEAN_DOMAIN=` to `create_domain_env()` template so future domains include it

### ShieldPress Monitor — Full Metrics Parity with VPS Agent (`modules/shieldpress/shieldpress-monitor.sh`)

`shieldpress-monitor.sh` now collects all metrics that `vps-agent.sh` (standalone agent) already had, achieving full parity. Added 10 new collection functions:

| Function | Data collected |
|----------|---------------|
| **OS Info** (in `collect_system_metrics`) | `os.name`, `os.version`, `os.kernel`, `os.arch` |
| **CPU Model** (in `collect_system_metrics`) | `cpu.model` from `/proc/cpuinfo` |
| **Disk I/O** (in `collect_system_metrics`) | `disk.read_kbps`, `disk.write_kbps` — sampled from `/proc/diskstats` (combined 1s sample with network bandwidth, no extra sleep) |
| `collect_versions_json()` | 15 software versions (nginx, mysql, mariadb, postgresql, redis, nodejs, python, docker, composer, npm, git, openssl, curl, apache, litespeed) + `php_versions` array with per-version status |
| `collect_security_config_json()` | `firewall_type`, `firewall_status`, `selinux`, `apparmor`, `open_files_limit`, `max_processes`, `ntp_synced`, `timezone` |
| `collect_top_processes_json()` | Top 15 processes by CPU usage (pid, user, cpu%, mem%, cmd) |
| `collect_listening_ports_json()` | Up to 30 listening ports with process names from `ss -tlnp` |
| `collect_docker_containers_json()` | Running containers (name, image, status, ports) from `docker ps` |
| `collect_current_users_json()` | Currently logged-in users from `who` |
| `collect_recent_logins_json()` | Last 10 logins from `last` |
| `collect_logs_json()` | 10 log types (nginx error/access, apache error/access, mysql, mysql slow, redis, php-fpm, fail2ban, syslog) — last 50 lines each, JSON-encoded via python3 using env vars for safe escaping |

Also added Valkey/valkey-server detection for `services.redis` status.

### Remote Commands Bug Fixes

**BUG 1 — Route conflict (CRITICAL)** (`api-shieldpress/src/routes/vps/index.ts`)
- `GET /commands/pending` was registered AFTER `GET /:id` — Express matched `/:id` first with `id="commands"` → 404. **All remote commands were broken.**
- Fix: Moved `/commands/pending` and `/commands/:commandId/result` routes before `/:id`

**BUG 2 — OPcache reset ineffective** (`shieldpress-monitor.sh`)
- `_cmd_clear_opcache()` ran `php -r 'opcache_reset()'` from CLI, which only resets the CLI process's OPcache, not PHP-FPM's web OPcache
- Fix: Now reloads PHP-FPM service(s) via `systemctl reload` to actually clear web OPcache

**BUG 3 — Redis CLI mismatch** (`shieldpress-monitor.sh`)
- `clear_redis` used `redis-cli` but ShieldPress VPS installs Valkey (Redis fork) which provides `valkey-cli`
- Fix: Checks `valkey-cli` first, falls back to `redis-cli`

**BUG 4 — Valkey service not detected** (`shieldpress-monitor.sh`)
- `restart_redis` only checked `valkey`, `redis`, `redis-server` — missed `valkey-server` (AlmaLinux service name)
- Fix: Checks all 4 service names: `valkey`, `valkey-server`, `redis`, `redis-server`. Falls back to `list-unit-files` if none are active.

**BUG 7 — Nginx cache clears all domains** (`shieldpress-monitor.sh`)
- `clear_nginx_cache` ran `find /var/cache/nginx -type f -delete` (all domains) even when API sends a specific `domain` parameter
- Fix: When `domain` is specified, only clears `/var/cache/nginx/${clean_domain}/`

**Affected files:**
- `modules/wordpress/helpers.sh` — Safe `CLEAN_DOMAIN` override
- `modules/wordpress/reset-password.sh` — Same fix
- `modules/domain/helpers.sh` — Added `CLEAN_DOMAIN` to `domain.env` template
- `modules/shieldpress/shieldpress-monitor.sh` — 10 new metric collectors, 4 remote command bug fixes
- `api-shieldpress/src/routes/vps/index.ts` — Route order fix

---

## v1.2.8 — 2026-07-23 - PHP-FPM Boot Crash Fix

### Bug Fix: PHP-FPM fails to start when slowlog directory is missing

**Problem:** After server reboot or directory cleanup, PHP-FPM (all versions) crashes with:
```
ERROR: Unable to create or open slowlog(/var/shieldpress/logs/php-slow/...-slow.log): No such file or directory
ERROR: FPM initialization failed
```
This causes **502 Bad Gateway** for all sites. The slowlog directory `/var/shieldpress/logs/php-slow/` was only created when running ShieldPress menu (`ensure_shieldpress_dirs()`) or adding a domain — not guaranteed to exist at boot time.

**Fix (3 changes):**

1. **`modules/domain/helpers.sh`** — `create_php_pool()` now runs `mkdir -p "$SLOW_LOG_DIR"` before writing pool config, ensuring the directory exists every time a pool is created or rebuilt.

2. **`modules/install/install-stack.sh`** — `install_php()` now calls `ensure_shieldpress_dirs()` before validating and starting PHP-FPM, preventing crash during initial install.

3. **`modules/install/install-stack.sh`** — NEW: Creates `/etc/tmpfiles.d/shieldpress.conf` so systemd automatically creates all ShieldPress directories (`/var/shieldpress/logs/`, `/var/shieldpress/logs/php-slow/`, `/var/shieldpress/logs/malware/`, `/var/shieldpress/data/`) at every boot, before any service starts. This is the root fix — PHP-FPM will never crash due to missing directories again.

**Affected files:**
- `modules/domain/helpers.sh` — Added `mkdir -p` in `create_php_pool()`
- `modules/install/install-stack.sh` — Added `ensure_shieldpress_dirs()` in `install_php()`, added tmpfiles.d setup

**Hotfix for existing servers:**
```bash
mkdir -p /var/shieldpress/logs/php-slow
systemctl start php84-php-fpm
```

---

## v1.2.7 — 2026-07-18 - Security Hardening, Monitoring & Upgrade Safety

### PostgreSQL Manager Improvements (`modules/database/pg-menu.sh`)

**Database List — shows database size**
- `pg_list_db()` now queries `pg_size_pretty(pg_database_size())` for each database
- Output: `db_name | 15 MB | user db_user | created 2024-12-15`
- Falls back to `N/A` if PostgreSQL is unreachable

**Configure Auto Backup — reworked**
- **Before:** Single prompt for HH:MM time, always daily, hardcoded 14-day age-based retention
- **After:** 3 prompts, all with defaults for quick Enter-through:

| Prompt | Input | Default |
|--------|-------|---------|
| Backup hour | 0-23 | 23 |
| Frequency | 1=Daily, 2=Weekly (Sunday), 3=Monthly (1st) | 1 (Daily) |
| Retention | Number of backups to keep | 7 |

- Backup script now uses file-count retention (keeps N newest files) instead of age-based deletion
- `ensure_pg_backup_script()` accepts retention parameter, generates script with `ls -1t | tail -n +$(($KEEP + 1)) | xargs rm`

### Backup & Restore Menu Simplified (`modules/backup/backup-menu.sh`)

- **Before:** 11 items split into 4 sections (BACKUP, SCHEDULE, REMOTE & CLOUD, MANAGE) with `sp_section` headers
- **After:** Flat menu with all 11 items numbered 1-11 + 0 (Back), no section grouping
- All functionality and order preserved

### Upgrade Manager — Safety Mechanisms (`modules/upgrade/upgrade-gate.sh`) — MAJOR

**Graceful Stop (`graceful_stop_service()`)** — NEW

Replaces hard `systemctl stop` across all upgrade scripts. Each service uses the safest shutdown method with timeout fallback:

| Service | Graceful method | Fallback |
|---------|----------------|----------|
| Nginx | `nginx -s quit` (finish current requests) | `systemctl stop` after 30s |
| MariaDB | `mysqladmin shutdown --wait=3` (drain connections) | Force stop after 30s |
| PostgreSQL | `pg_ctl stop -m smart` (wait for clients) | Fast mode → force stop |
| PHP-FPM | `kill -QUIT` / SIGQUIT (finish requests) | `systemctl stop` after 30s |
| Node.js/PM2 | `pm2 stop all` before upgrade | `pm2 restart all` after |

Shows active connection/query count before stopping. Displays wait time.

**Auto-Rollback (`auto_rollback()`)** — NEW

When upgrade fails (command error or post-upgrade validation failure), the system:

1. Asks confirmation (default = yes, Enter to rollback)
2. Restores config snapshot (extracts tar.gz, overwrites all config files)
3. Restores database dump if available (MariaDB: `gunzip | mysql`, PostgreSQL: `gunzip | psql`)
4. Restarts service with restored config and validates
5. Sends Telegram notification about rollback
6. Logs everything to `upgrade.log`

If user declines rollback, shows paths to snapshot and dump for manual restore.

**`pre_upgrade_actions()` updated** — Now exports `_ROLLBACK_SNAPSHOT` and `_ROLLBACK_DUMP` paths for use by auto-rollback.

**`upgrade_service()` updated** — Handles both scenarios:
- Upgrade command fails → prompt rollback
- Upgrade succeeds but validation fails → prompt rollback

**Files changed:**
- `modules/upgrade/upgrade-gate.sh` — Added `graceful_stop_service()`, `auto_rollback()`, updated `pre_upgrade_actions()`, `upgrade_service()`
- `modules/upgrade/upgrade-nginx.sh` — Uses `graceful_stop_service nginx`
- `modules/upgrade/upgrade-mariadb.sh` — Uses `graceful_stop_service mariadb`
- `modules/upgrade/upgrade-postgresql.sh` — Uses `graceful_stop_service postgresql`
- `modules/upgrade/upgrade-php.sh` — Uses `graceful_stop_service phpXX`
- `modules/upgrade/upgrade-nodejs.sh` — Graceful `pm2 stop all` before upgrade, checks restart status after

### Monitoring Center — 3 New Features (`modules/monitor/monitor-menu.sh`)

Menu expanded from 8 to 11 options.

**7) Log Viewer** — NEW

Multi-type, multi-domain log viewer with 2-step flow:

Step 1 — Choose log type:
1. Nginx Access Log (per domain)
2. Nginx Error Log (per domain)
3. PHP-FPM Error Log (select PHP version)
4. PHP Slow Log (per domain)
5. MariaDB / MySQL Log
6. PostgreSQL Log (file or journalctl fallback)
7. Nginx Global Error Log

Step 2 — Choose view mode:
- Last 50 lines
- Last 100 lines
- Realtime (`tail -f`, Ctrl+C to stop)

Shows file path, size and total line count before viewing.

**8) Service Status Dashboard** — NEW

Real-time status of all services in one view:
- Nginx, PHP-FPM (per version with domain count), MariaDB, PostgreSQL, Valkey, Redis
- Node.js version, PM2 online app count
- Firewalld, Fail2Ban, Cron, SSH
- Memory usage per service (via systemd MemoryCurrent)
- Server uptime
- Color coded: green = running, red = stopped

**9) Domain Health Check** — NEW

Curl-based health check for all domains:
- Checks both HTTP and HTTPS via localhost (bypasses DNS with `Host` header and `--resolve`)
- Shows HTTP status code, HTTPS status code, response time
- Color coded: 2xx/3xx = green, others = red
- Summary: Total / OK / Failed count
- Lists failed domains with status codes
- 5s connect timeout, 10s max per domain

### Security Center — 4 New Features (`modules/security/security-menu.sh`)

Menu expanded from 14 to 18 options.

**11) Fail2ban Nginx Protection** — NEW

Creates 2 fail2ban jails for Nginx:

| Jail | Trigger | Threshold | Ban time |
|------|---------|-----------|----------|
| `nginx-badbots` | 403/404 errors | 30/60s | 1 hour |
| `nginx-5xx` | 500/502/503/504 errors | 15/120s | 2 hours |

- Auto-detects log paths for all domains (`/var/log/nginx/domains/*/access.log`)
- Ignores static file requests (css, js, images) to prevent false positives
- Whitelists current SSH IP
- Tests config before restart

**12) Fail2ban Nginx Manager** — NEW

- Shows banned IP count per jail
- View all banned IPs
- Unban specific IP (searches both jails)
- Disable all Nginx jails (removes config files)

**16) SSH Hardening** — NEW

Dashboard shows current SSH config (port, password auth status, authorized key count).

**Change SSH Port:**
- Validates port 1024-65535, checks port not already in use
- Opens new port in firewall BEFORE changing sshd (prevents lockout)
- Updates SELinux policy if present
- Tests `sshd -t` before restart — auto-reverts sshd_config if test fails
- Closes old port AFTER successful restart
- Updates fail2ban SSH jail port
- Backs up sshd_config before every change

**Disable Password Auth:**
- Checks `authorized_keys` first — if 0 keys found, REFUSES with instructions to add SSH key
- Only allows disable when keys exist
- Tests + auto-reverts on failure

**Enable Password Auth:**
- Re-enables password login, tests + auto-reverts on failure

**17) Auto-block Attackers** — NEW

One-click scan of all domain access logs:
- Finds IPs exceeding request threshold (default 200, customizable)
- Finds IPs with >100 4xx errors
- Displays table: HITS | IP | ACTION
- Skips protected IPs (SSH IP, localhost, private ranges, server IP)
- Skips already-blocked IPs
- Blocks via firewalld rich rules
- Logs all actions to IP block history
- Sends Telegram notification with count

---

## v1.2.4 — 2026-07-16 - Smart Backup & Remote Storage Overhaul

### Remote Backup: Auto-Install & Simplified Setup (`modules/backup/remote-backup.sh`) — REWRITTEN

**Problem:** Selecting "Configure S3 / Google Drive / OneDrive" required rclone to be pre-installed and used interactive `rclone config`, which is complex on headless servers.

**Now:**
- **Auto-install rclone** — Detects OS (dnf/yum/apt), falls back to official install script if package manager fails
- **S3 paste-key setup** — User selects provider (AWS, Cloudflare R2, DO Spaces, Backblaze B2, MinIO), pastes Access Key + Secret Key + Bucket. Script writes `rclone.conf` directly, no interactive prompts
- **Google Drive headless support** — 3 auth methods:
  1. Service Account JSON (upload key file)
  2. OAuth Token (run `rclone authorize "drive"` on local machine, paste token on server)
  3. OAuth Interactive (server has browser)
- **OneDrive headless support** — Same token-paste flow for servers without browser
- **New options:** Delete local backup after upload (`DELETE_LOCAL_AFTER_UPLOAD`), View Remote Storage info, Edit Options without reconfiguring remote
- Auto-tests connection after configuration

### Backup Menu Restructured (`modules/backup/backup-menu.sh`)

- **Before:** 13 flat items, no grouping
- **After:** 11 items in 4 visual sections: BACKUP, SCHEDULE, REMOTE & CLOUD, MANAGE
- 3 auto-backup menus (DB/Files/Full) consolidated into unified **Auto Backup Setup** submenu (`auto-backup.sh`) with "View All Schedules" and "Remove a Schedule"

### Smart Daily Backup — Incremental Mode (NEW)

When selecting **Daily** frequency for auto-backup, a new option appears:

**WordPress — Smart mode:**
- Only backs up `wp-content/themes/`, `wp-content/plugins/`, `wp-content/uploads/`
- Skips WP core files (`wp-admin/`, `wp-includes/`, `wp-*.php`) — download from wordpress.org to restore
- File naming: `files_wp-content_*.tar.gz` / `full_incr_*.tar.gz`

**Laravel — Incremental mode:**
- Only files changed in last 24h (`find -mmin -1440`)
- Skips: vendor, node_modules, .git, bootstrap/cache, storage/framework/cache|sessions|views, storage/logs
- If no files changed → skip backup, log `SKIP: no files changed in 24h`

**Node.js / Next.js — Incremental mode:**
- Only files changed in last 24h
- Skips: node_modules, .git, .next, .nuxt, dist, build, .cache, .turbo

DB dump is always full regardless of mode. Incremental files have separate naming (`files_incr_*`, `full_incr_*`) so retention prune doesn't mix with full backups.

**Files changed:** `auto-backup-files.sh`, `auto-backup-full.sh`, `_backup_helper.sh` (`archive_source_incremental()`)

### Per-Domain Backup Config — `backup.env` (NEW)

Each domain now has `<domain>/config/backup.env`, auto-generated when creating a domain with defaults matching the app type.

| Config | Purpose |
|--------|---------|
| `BACKUP_ENABLED=0` | Skip this domain entirely (manual + auto) |
| `BACKUP_PATHS=src,config,routes` | Override: only backup these paths (relative to public_html) |
| `BACKUP_EXCLUDE=coverage,test,*.map` | Additional excludes (appended to app-type defaults) |
| `INCR_EXCLUDE=tmp,temp` | Extra excludes for incremental/daily mode only |
| `BACKUP_RETENTION=5` | Override global retention for this domain |

Priority: `BACKUP_PATHS` set → custom targeted backup. Empty → app-type defaults.
Users customize by editing `nano /home/domains/myapp_com/config/backup.env`.

**Files changed:** `modules/domain/helpers.sh` (`create_backup_env()`), `modules/domain/add-domain.sh`, `modules/backup/_backup_helper.sh` (`load_backup_config()`, `build_exclude_opts()`, `build_find_excludes()`, updated `archive_source_to_file()`, `archive_source_incremental()`), `auto-backup-files.sh`, `auto-backup-full.sh`

### Exclude Lists Synchronized & Extended

Added missing excludes across all backup methods (manual, auto-full, auto-files, helper):

| App Type | Added Excludes |
|----------|---------------|
| Laravel | `bootstrap/cache/`, `storage/framework/cache/data`, `storage/framework/sessions/`, `storage/framework/views/`, `backup/` |
| Node.js | `build/`, `.cache/`, `.turbo/`, `backup/` |

### Bug Fixes

- **Auto DB backup missing remote upload** — Generated cron script in `auto-backup-db.sh` now calls `remote_upload_backup "$FILE" "db"` (files and full already had it)
- **Restore can't see encrypted backups** — `restore-site.sh` now lists both `*.tar.gz` and `*.enc` files, shows `[ENCRYPTED]` tag, auto-decrypts before extraction
- **Telegram backup WordPress-only** — `backup-telegram.sh` removed dependency on `modules/wordpress/helpers.sh`, now uses generic `backup_db_to_file()` + `archive_source_to_file()` from `_backup_helper.sh`. Works with WordPress, Laravel, and Node.js
- **Telegram cron hardcoded WP paths** — `run_cron()` replaced `mysqldump` + `cp wp-content` with generic helpers
- **`DELETE_LOCAL_AFTER_UPLOAD` support** — `_backup_helper.sh` `load_remote_config()` + `remote_upload_backup()` now reads and acts on this config. Only deletes local file when ALL remote uploads succeed

---

## 2026-07-14 - PostgreSQL Manager Improvements

### Moved: PostgreSQL Install & Management to DB Manager
- PostgreSQL can now be installed directly from **Database Manager → PostgreSQL Manager** (no longer requires going through Laravel Manager)
- When PostgreSQL is not installed, the PostgreSQL Manager menu shows an "Install PostgreSQL" option instead of just a warning
- When creating a DB and PostgreSQL is not installed, auto-prompts to install immediately
- Removed "Install PostgreSQL" (option 2) and "PostgreSQL Manager" (option 5) from Laravel Manager menu
- Laravel Manager renumbered from 20 to 18 options

### Fixed: "could not change directory to /root: Permission denied"
- Added `cd /tmp` before all `runuser -u postgres` commands in both `pg-menu.sh` and `laravel-menu.sh`
- Affected functions: create DB, delete DB, change password, backup
- The error was cosmetic (DB operations still succeeded) but now fully resolved

**Files changed:**
- `modules/database/pg-menu.sh` — Added `install_postgresql_stack()`, `configure_shieldpress_postgresql()`, updated menu flow, fixed `cd /tmp`
- `modules/laravel/laravel-menu.sh` — Removed PostgreSQL menu items, renumbered, fixed `cd /tmp`

---

## 2026-07-14 - Directory Restructure & Nginx Password Protection

### Architecture: Directory Restructure (50+ files)

**Problem:** `/opt/shieldpress` mixed source code with runtime data (logs, backups, database lists), making updates risky and disk management unclear.

**New Structure:**
- `/opt/shieldpress/` — Source code only (scripts, modules, templates)
- `/var/shieldpress/logs/` — All ShieldPress operational logs (domain, backup, ssl, monitor, php-slow, malware, etc.)
- `/var/shieldpress/data/` — Runtime data (auth metadata, laravel-databases, tmp-backups, valkey auth, databases.list)
- `/home/backup-all/` — Global backups (replaces `/opt/shieldpress/backups-global/`)
- `/home/domains/{domain}/logs/` — Per-domain nginx access/error logs (replaces `/var/log/nginx/domains/`)

**New Files:**
- **`core/paths.sh`** — Centralized path constants sourced by all modules. Defines `LOG_DIR`, `DATA_DIR`, `BACKUP_GLOBAL_DIR`, `DATA_DIR_AUTH`, `DATA_DIR_LARAVEL_DB`, `DATA_DIR_TMP_BACKUPS`, `LOG_DIR_PHP_SLOW`, `LOG_DIR_MALWARE`, plus helper functions `domain_log_dir()`, `domain_backup_dir()`, `global_backup_dir()`, `ensure_shieldpress_dirs()`, `create_compat_symlinks()`
- **`modules/tools/migrate-paths.sh`** — Interactive migration script: moves data from old locations, updates nginx configs, creates backward-compatible symlinks. Idempotent (safe to run multiple times). Tests `nginx -t` before reload with auto-rollback on failure.

**Backward Compatibility:**
- Symlinks created automatically: `/opt/shieldpress/logs → /var/shieldpress/logs`, `/opt/shieldpress/data → /var/shieldpress/data`, `/opt/shieldpress/backups-global → /home/backup-all`
- Per-domain symlinks: `/var/log/nginx/domains/{domain} → /home/domains/{domain}/logs`
- Auto-migration on first startup after update (detected by checking if `/opt/shieldpress/logs` is a real directory vs symlink)
- Old scripts, cron jobs, and running services continue working via symlinks without restart

**Files Updated (50+):**
- `core/helpers.sh`, `core/logger.sh` — Source `paths.sh`, use `$LOG_DIR`
- `modules/domain/helpers.sh` — Nginx configs now write logs to `/home/domains/{domain}/logs/`, directory structure includes `logs/`, PHP slow logs use `$LOG_DIR_PHP_SLOW`, database paths use `$DATA_DIR`
- `modules/backup/*` (11 files) — All `LOG_FILE` and `mkdir` use `$LOG_DIR`
- `modules/database/*` (14 files) — `$LOG_DIR`, `$DATA_DIR`, `$DATA_DIR_LARAVEL_DB`, `$DATA_DIR_TMP_BACKUPS`
- `modules/wordpress/*` (5 files) — `$LOG_DIR`, systemd heredocs use literal `/var/shieldpress/logs/`
- `modules/monitor/`, `modules/optimize/`, `modules/tools/` (9 files) — `$LOG_DIR`, `$LOG_DIR_PHP_SLOW`
- `modules/security/`, `modules/repair/`, `modules/upgrade/` (8 files) — `$LOG_DIR`
- `modules/laravel/`, `modules/nodejs/`, `modules/disk/`, `modules/ssl/`, `modules/sftp/`, `modules/notification/`, `modules/isolation/`, `modules/clone/`, `modules/email/`, `modules/shieldpress/` — `$LOG_DIR`, `$DATA_DIR`, `$BACKUP_GLOBAL_DIR`
- `modules/install/install-stack.sh` — `$LOG_DIR`, `$DATA_DIR` for valkey auth
- `modules/update/updater.sh` — Migration logic for old-style directories during update
- `shieldpress.sh` — Sources `paths.sh` at startup, calls `ensure_shieldpress_dirs()`, auto-migrates old paths
- `modules/tools/tools-menu.sh` — Added option 10: "Migrate Paths"

### New Feature: Nginx Password Protection (`modules/nginx/nginx-auth.sh`)

**Basic Auth module** for protecting websites with username/password via nginx `auth_basic`.

**Two protection modes:**
1. **Protect specific URL** — Only the specified path requires authentication (e.g. `/admin`, `/wp-login.php`); all other URLs remain public
2. **Protect entire domain** — Every request to the domain requires authentication

**Menu (6 options):**
- **Overview Status** — Shows all domains with ON/OFF status, protection mode, and username
- **View Domain Details** — Full details: status, mode, protected URL, username, password
- **Enable Protection** — Interactive setup: select domain → choose mode → set credentials → inject into nginx config
- **Disable Protection** — Removes auth directives and cleans up htpasswd files
- **Toggle ON/OFF** — Temporarily disable/enable without losing configuration (comments/uncomments nginx directives using `# SP_AUTH_OFF#` prefix)
- **Change Credentials** — Update username/password without reconfiguring

**Implementation details:**
- htpasswd files stored in `/etc/nginx/auth/{domain}.htpasswd` (chmod 640, owned root:nginx)
- Auth metadata stored in `/var/shieldpress/data/auth/{domain}.auth` (chmod 600) — tracks mode, URL, username, password (plaintext for display), status
- Nginx config injection uses marker comments (`# >>> ShieldPress Auth Protection Start/End <<<`) for safe add/remove
- Auto-detects app type from existing config: PHP apps get `fastcgi_pass` with correct socket, Node.js apps get `proxy_pass`, fallback uses `try_files`
- Backs up nginx config before every change, runs `nginx -t`, rolls back automatically on test failure
- Auto-installs `httpd-tools`/`apache2-utils` if `htpasswd` not found
- Added as option 11 in Nginx Manager menu (options 12-15 renumbered)

---

## 2026-07-13 (Part 2) - Security Hardening, Core Framework & New Features

### Security Fixes (Critical)

**Telegram Proxy Removed** (`modules/backup/backup-telegram.sh`)
- Removed hardcoded personal Cloudflare Worker proxy (`telegram.vithanhlamseo.workers.dev`)
- All Telegram API calls now use `TELEGRAM_API_BASE` variable (defaults to `https://api.telegram.org`)
- Consistent with `telegram-notify.sh` which already used the configurable approach

**Restore Site Protection** (`modules/backup/restore-site.sh`)
- Fixed critical bug: `public_html` was deleted BEFORE checking if `files.tar.gz` exists in backup
- Now validates backup archive exists before any destructive operation
- Prevents accidental site deletion from incomplete backup packages

**Source Injection Prevention** (Multiple files)
- Replaced unsafe `source "$file"` with safe `grep | cut` parsing across all modules:
  - `modules/wordpress/helpers.sh` - domain selector + config loading
  - `modules/backup/backup-telegram.sh` - config + domain env loading
  - `modules/database/config-db.sh`, `optimize-db.sh`, `change-pass.sh` - domain loops
  - `modules/database/adminer.sh` - data file loading
  - `modules/wordpress/reset-password.sh`, `staging.sh` - domain/staging env
  - `modules/license/license-core.sh` - license status file
- Prevents privilege escalation from domain user to root via modified `.env` files

**MySQL Password Exposure** (`modules/backup/_backup_helper.sh`)
- Replaced `-u "$DB_USER" -p"$DB_PASS"` with `--defaults-extra-file` temp config
- Database passwords no longer visible in process list (`ps aux`)
- Temp MySQL config files use `chmod 600` and are cleaned up after use

**Credential File Permissions**
- `modules/database/adminer.sh`: Added `chmod 600` for `adminer.env`
- `modules/database/create-db.sh`: Added `chmod 600` for `databases.list`
- `modules/wordpress/install-wp.sh`: Added `chmod 600` for `db.txt`
- `modules/wordpress/reset-password.sh`: Added `chmod 600` for `db.txt`
- `modules/backup/auto-backup-db.sh`: Changed `chmod +x` to `chmod 700` for generated scripts
- `modules/backup/auto-backup-full.sh`: Changed `chmod +x` to `chmod 700` for generated scripts
- `modules/license/license-core.sh`: Added `chmod 600` for `license.key` and `license.status`

**Sudoers Rule Tightened** (`modules/wordpress/install-wp.sh`)
- Changed `ALL ALL=(root) NOPASSWD:` to `%www-data ALL=(root) NOPASSWD:`
- Cache purge script no longer executable by every user on the system

**Firewall Geo-Unblock Fix** (`modules/security/security-menu.sh`)
- `unblock_bot_countries_real()` now only removes rules related to `shieldpress_geo` ipset
- Previously deleted ALL reject rules, destroying user's manual IP blocks

**License Bypass Hardened** (`modules/license/license-core.sh`)
- Replaced loose `grep "VALID"` with strict JSON pattern matching
- Added license key format validation
- Added curl timeout for API calls

**Install Stack Security** (`modules/install/install-stack.sh`)
- Enabled `gpgcheck=1` with GPG key for Nginx repo (was `gpgcheck=0`)
- SELinux: Replaced `semanage permissive -a httpd_t` (full permissive) with targeted `setsebool` flags

### Bug Fixes

**Dashboard Crash** (`shieldpress.sh`)
- Fixed division-by-zero when `RAM_TOTAL=0` (container/VPS edge case)
- Fixed `get_mysql_queries()`: `tr -d 'Queries:'` removed individual chars (e,i,s) from numbers; replaced with `awk`
- Fixed `HEALTH_TEXT` logic: mixed `||` and `&&` without grouping caused incorrect operator precedence
- Quoted all variables throughout: `$PHP_BIN`, `$MODULE_DIR/*`, `$1` in check_service, `$LOG` paths

**Variable Leak Between Domains** (`modules/wordpress/helpers.sh`)
- `select_domain()` loop used `source` inside iteration, leaking vars between domains
- Replaced with `grep` for listing, safe `grep | cut` for loading selected domain

**Malware Scanner Table Prefix** (`modules/wordpress/malware-scan.sh`)
- Hardcoded `wp_options`, `wp_posts`, `wp_users`, `wp_usermeta` now dynamically detect `$table_prefix` from `wp-config.php`
- Sites with custom prefixes are now properly scanned

**Domain Name Inconsistency** (3 files)
- `modules/helpers/domain-utils.sh`: `domain_to_clean()` now truncates to 30 chars (was unlimited)
- `modules/repair/auto-repair.sh`: `CLEAN` now uses `[^a-zA-Z0-9]` regex (was `[^a-zA-Z0-9.-]`)
- Both now consistent with `domain/helpers.sh` `clean_domain_name()`

**Pipe Subshell Exit Code** (`modules/backup/_backup_helper.sh`, `remote-backup.sh`)
- `remote_upload_backup()`: pipe-into-while subshell silently swallowed failures
- Replaced with heredoc-fed while loop so exit codes propagate correctly
- Same fix applied to `remote-backup.sh` `test_remote()` function

**Cache Hit Ratio** (`modules/cache/cache-hit.sh`)
- `grep -c "HIT"` matched URLs containing "HIT" (false positives)
- Changed to `grep -cE '"HIT"'` to match only quoted cache status values

**Cache Warmup Cron** (`modules/cache/warmup-cache.sh`)
- Cron setup created job with `--auto` argument but script had no argument parser
- Added `--auto $DOMAIN` handling for non-interactive cron execution

**Config Domain Grep** (`modules/domain/config-domain.sh`)
- `grep memory_limit` matched commented lines (`;memory_limit`)
- Changed to `grep -E '^[^;]*memory_limit'` to exclude commented-out directives

**Backup Size Calculation** (`modules/backup/list-domain-backup.sh`)
- `awk '{sum+=$1}'` tried to sum human-readable sizes ("1.2G", "500M")
- Replaced with `du -sb` (bytes) then convert to human-readable

**Backup Full Temp Cleanup** (`modules/backup/backup-full.sh`)
- Added `trap 'rm -rf "$TMP"' EXIT INT TERM` for temp directory cleanup
- Replaced predictable `/tmp/` path with `mktemp -d`

**Clone Lock Race Condition** (`modules/clone/clone-menu.sh`)
- Changed lock from `touch` (TOCTOU race) to `mkdir` (atomic)
- Trap now only runs unlock if lock was actually acquired (prevents stealing another process's lock)

**Staging Lock** (`modules/wordpress/staging.sh`)
- Same atomic `mkdir` lock fix as clone-menu

**Install.sh Quoting** (`install.sh`)
- Quoted all `$BASE_DIR` variables in chmod/ln commands

### New Features

**Core Framework** (`core/`)

- **`core/validator.sh`** - NEW: Input validation framework
  - `validate_domain()`, `validate_ip()`, `validate_ipv4()`, `validate_ipv6()`
  - `validate_port()`, `validate_db_name()`, `validate_db_user()`, `validate_username()`
  - `validate_email()`, `validate_hour()`, `validate_php_version()`, `validate_path()`, `validate_url()`
  - Sanitizers: `sanitize_identifier()`, `sanitize_domain_folder()`, `sanitize_sql()`, `sanitize_log()`, `sanitize_filename()`
  - Interactive helper: `ask_validated()` - prompt with retry on validation failure

- **`core/helpers.sh`** - NEW: Shared utility library
  - `clean_domain_name()` - canonical domain-to-folder conversion
  - `read_domain_env()` - safe single-value reader (grep-based, never source)
  - `load_domain_env()` - load all standard domain variables safely
  - `select_domain_interactive()` - interactive domain picker
  - `list_domain_paths()`, `list_domain_names()` - iterators for scripts
  - `set_env_value()` - safe key=value updater for .env files
  - `mysql_defaults_file()` - create temp MySQL auth file (hides password from ps)
  - `get_server_ip()` - IP detection with timeout

- **`core/system-info.sh`** - NEW: Centralized system metrics
  - CPU: `sysinfo_cpu_load()`, `sysinfo_cpu_cores()`
  - Memory: `sysinfo_ram_total_mb()`, `sysinfo_ram_used_mb()`, `sysinfo_ram_percent()`, swap variants
  - Disk: `sysinfo_disk_percent()`, `sysinfo_disk_used()`, `sysinfo_disk_total()`, `sysinfo_disk_free_mb()`
  - Services: `sysinfo_service_active()`, `sysinfo_service_state()`
  - Network: `sysinfo_nginx_connections()`, `sysinfo_open_port_count()`
  - Database: `sysinfo_mysql_queries()`, `sysinfo_db_public()`
  - Cache: `sysinfo_valkey_memory()`, `sysinfo_nginx_cache_active()`, `sysinfo_http3_enabled()`
  - PHP: `sysinfo_php_opcache_enabled()`, `sysinfo_php_jit_enabled()`
  - `collect_system_metrics()` - populate all SYS_* variables in one call

- **`core/logger.sh`** - Implemented shared logging
  - `sp_log()`, `sp_ok()`, `sp_fail()`, `sp_warn()`, `sp_pause()`
  - Backward-compatible aliases: `log()`, `ok()`, `fail()`, `warn()`, `pause()`

**Backup Encryption** (`modules/backup/backup-encrypt.sh`) - NEW
- AES-256-CBC encryption with PBKDF2 key derivation (100k iterations)
- Key management: generate, show, import, backup old keys
- Enable/disable encryption globally (applies to all new backups)
- Manual encrypt/decrypt for existing backup files
- Integrated into `_backup_helper.sh`:
  - `backup_encrypt_enabled()` - check if encryption is active
  - `maybe_encrypt_backup()` - auto-encrypt if enabled
  - `decrypt_for_restore()` - decrypt .enc files for restore
- Encryption status dashboard
- Added as option 13 in Backup & Restore menu

**Server Migration Tool** (`modules/tools/migrate.sh`) - NEW
- **Export Domain**: Creates portable migration package containing:
  - Domain configuration (`domain.env`, `staging.env`)
  - Database dump (MariaDB or PostgreSQL, compressed)
  - Source files archive (`public_html`)
  - SSL certificates (Let's Encrypt or Cloudflare)
  - Nginx vhost configuration
  - Cron jobs related to the domain
  - Migration metadata (version, date, source server)
- **Import Domain**: Restores from migration package:
  - Creates system user and directory structure
  - Restores database (creates DB + user if needed)
  - Restores files with correct ownership
  - Restores Nginx config (validates before reload)
  - Handles both MariaDB and PostgreSQL
  - Supports overwrite of existing domains (with confirmation)
- **Pull from Remote**: SSH-based live migration
  - Connects to remote ShieldPress server
  - Auto-exports domain on remote, downloads package, imports locally
  - Requires SSH key authentication
- Supports encrypted migration packages (integrates with backup encryption)
- Non-interactive `--export-auto` mode for remote pull operations
- Added as option 9 in Tools & Utilities menu

---

## 2026-07-13

### VPS Monitor (`modules/shieldpress/shieldpress-monitor.sh`)

**Site Health Monitoring**
- Added site health check: scans all domains in `/home/domains/*/config/domain.env`
- Detects site type (wordpress, laravel, static) and HTTP status code
- Sends `site_health` array in metrics payload to API:
  ```json
  { "domain": "example.com", "http_status": 200, "type": "wordpress", "healthy": true }
  ```
- Reads real domain name from `domain.env` instead of folder name

**Remote Commands (Pull Model)**
- VPS agent polls `GET /api/vps/commands/pending` every cycle for pending commands
- HMAC signature verification: `sha256(commandId + action + sha256(secret))`
- Strict command whitelist (17 allowed actions, all others rejected):
  - Services: `reload_nginx`, `restart_nginx`, `restart_php_fpm`, `restart_mariadb`, `restart_redis`
  - Cache: `clear_opcache`, `clear_file_cache`, `clear_redis`, `clear_nginx_cache`, `clear_all_cache`
  - WordPress: `wp_maintenance_on/off`, `wp_update_core/plugins/themes`, `wp_clear_transients`
  - Recovery: `auto_recovery`
- Reports results back via `POST /api/vps/commands/{id}/result`
- All commands logged locally

### WordPress Auto-Recovery (`modules/wordpress/wp-auto-recovery.sh`) - NEW

- Standalone module for detecting and fixing 500/502/503/504 errors
- Recovery flow: Clear OPcache -> file cache -> WP transients -> Redis -> Memcached -> Nginx cache -> Restart PHP-FPM -> Reload Nginx
- Reads PHP version from `domain.env` for correct PHP-FPM service restart
- Cooldown 5 minutes per domain to prevent recovery loops
- Telegram notifications on recovery (success/failure)
- 3 modes: `--scan` (one-shot), `--daemon` (continuous every 60s), interactive menu
- Systemd service support (`shieldpress-wp-recovery.service`)
- Added to WordPress Manager menu as option 10

### Install Stack (`modules/install/install-stack.sh`)

- Auto-installs and enables `shieldpress-wp-recovery` systemd daemon during stack installation
- No manual configuration needed - auto-recovery runs immediately after install

### WordPress Menu (`modules/wordpress/wp-menu.sh`)

- Added option 10: "Auto-Recovery (500 Fix)"

---

## Shield Monitor WordPress Plugin (`shieldpress` plugin)

### Push Metrics to API - NEW (`class-shield-monitor-push.php`)

- New class `Shield_Monitor_Push`: pushes WordPress metrics to `POST /api/sites/metrics`
- Runs every 5 minutes via WP-Cron (not every minute - too heavy)
- Caches collected payload for 5 minutes in transient (avoids expensive `collect()` calls)
- Lock mechanism prevents overlapping pushes
- try/catch wrapper with `safe_collect()` fallback on error
- Authenticates with license key as Bearer token
- Payload matches VPS Agent structure: `shieldpress_version`, `source: "wordpress"`, `metrics`, `logins`, `file_changes`, `wordpress` (full WP data)

### 500 Error Prevention Fixes

**WAF Log Bloat Fix** (`class-shield-monitor-waf.php`)
- Changed WAF blocked log from `update_option()` to `set_transient()` with 24h auto-expiry
- Prevents unbounded option growth that exceeds MySQL `max_allowed_packet` causing persistent 500 errors
- URI truncated to 200 chars

**File Monitor Safety** (`class-shield-monitor-file-monitor.php`)
- Table creation check moved to admin/cron only (was running on every `init`)
- Added `safe_scan()` wrapper with try/catch for cron callback
- `maybe_scan_when_cron_overdue()` wrapped in try/catch - scan errors no longer crash admin pages
- Increased admin scan lock from 5 to 30 minutes

**Malware Scanner Safety** (`class-shield-monitor-malware-scanner.php`)
- Table creation check moved to admin/cron only
- Added `safe_scan()` wrapper with try/catch for cron callback
- Added `cleanup_cache` action on daily cleanup hook

**SQL Injection Fix** (`class-shield-monitor-threat-intelligence.php`)
- Fixed unescaped LIKE clause in `external_script_scan()` - now uses `$wpdb->prepare()`

**Dashboard WAF Log Read** (`class-shield-monitor-security-dashboard.php`)
- Updated to read WAF log from `get_transient()` instead of `get_option()` (matches WAF change)

### Integration Files Updated
- `shield-monitor.php`: Added `require_once` for push class
- `class-shield-monitor.php`: Registers push hooks + `cron_schedules` filter
- `class-shield-monitor-activator.php`: Clears push cron on deactivate, cleans up push options on uninstall

---

## API Server (`api-shieldpress`)

### Remote Commands System - NEW

**Prisma Schema** (`prisma/schema.prisma`)
- New model `VpsCommand`: id, vpsId, action, domain, params, signature (HMAC), status, output, createdBy, createdAt, executedAt, expiresAt
- New enum `VpsCommandStatus`: PENDING, EXECUTING, COMPLETED, FAILED, REJECTED, EXPIRED
- Added `commands` relation to `VpsServer`

**VPS Library** (`src/lib/vps.ts`)
- Added `VPS_ALLOWED_COMMANDS` whitelist (17 actions)
- Added `VPS_COMMAND_TTL_MS` (5 minute auto-expiry)
- Added `signVpsCommand()`: `sha256(commandId + action + secretHash)`

**API Endpoints** (`src/routes/vps/index.ts`)
- `POST /api/vps/:id/commands` - Dashboard creates command (JWT auth, rate limited to 10 pending)
- `GET /api/vps/commands/pending` - VPS agent polls for commands (Bearer auth, auto-expires old commands)
- `POST /api/vps/commands/:commandId/result` - VPS agent reports result (Bearer auth)
- `GET /api/vps/:id/commands` - Dashboard views command history (JWT auth)

**Migration required:** `npx prisma migrate dev --name add-vps-commands`

---

## Web App (`app-shieldpress`)

### VPS Detail Page Auto-Refresh

- Auto-refreshes data every 2 minutes without page reload
- Countdown timer displayed next to refresh button (e.g. `1:45`)
- Manual refresh button with spinning icon during fetch
- Silent refresh (no UI flicker) for automatic updates

### Remote Actions Panel - NEW (`VpsActions.tsx`)

- Only shown on VPS running ShieldPress Agent (detected via `shieldpressVersion` in metrics)
- 3 action groups: Services, Cache, WordPress
- 10 action buttons: Reload Nginx, Restart PHP-FPM/MariaDB/Redis, Clear All Cache/OPcache/Redis/Nginx Cache, Clear WP Transients, Auto Recovery
- Real-time status feedback: sending -> pending -> completed/failed
- Polls command results every 2s with 60s timeout
- Toast notifications for success/failure
- Last command output displayed in panel
- Uses `api()` helper with JWT authentication
