# ShieldPress VPS User Guide

This guide covers the normal installation, operation, backup, security and
failover workflows for ShieldPress VPS on AlmaLinux 9 or 10.

## 1. Requirements and installation

Use a fresh AlmaLinux 9/10 server with at least 900 MB exposed RAM (a 1 GB plan
is recommended), 5 GB free disk and
root SSH access. Before installing, make sure DNS and provider firewall rules
are under your control.

```bash
curl -fsSL https://install.shieldpress.net -o /tmp/shieldpress-install.sh
bash /tmp/shieldpress-install.sh
rm -f /tmp/shieldpress-install.sh
shieldpress
```

The installer checks the operating system and resources, installs the selected
server stack, creates the `shieldpress` command and starts the dashboard. The
base installation does not install PostgreSQL or pgBackRest unless selected or
needed by a feature.

## 2. Dashboard and menu map

Run `shieldpress` for the dashboard or `shieldpress menu` for the full menu.
The dashboard shows CPU, RAM, disk, domains, services, alerts and cache state.
The main areas are Server/Core, Nginx, PHP, Domains, SSL, WordPress, Laravel,
Node.js, Databases, Backup & Restore, Cache, Security, Monitoring, Upgrades,
Repair, Optimization, RAM, Disk, SFTP, Tools, Telegram, ShieldPress Monitor,
Email and About.

Useful shortcuts:

```bash
shieldpress help
shieldpress domain
shieldpress ssl
shieldpress backup
shieldpress cache
shieldpress update
```

## 3. Domains, Nginx and SSL

Open `Domain Manager` to add, list, lock/unlock, edit, repair permissions or
delete a domain. Select the application type during creation: WordPress/PHP,
Laravel or Node.js. Point the domain DNS to the VPS before requesting SSL.

In `SSL Manager` you can install, renew, remove and inspect Let's Encrypt,
ZeroSSL, Cloudflare Origin or custom certificates. Wildcard/auto SSL requires
the DNS challenge and its provider credentials.

Nginx Manager controls server/domain configuration, HTTP/3, upload limits,
FastCGI cache and reload/validation. Always validate Nginx configuration before
reloading after manual edits:

```bash
nginx -t && systemctl reload nginx
```

## 4. WordPress

Use `WordPress Manager` to install WordPress, update core/plugins/themes,
harden security, optimize performance, reset an admin password, switch WP-Cron
to system cron, scan malware and manage staging environments.

In `WordPress Manager > Update Core / Plugins / Themes`, choose one website or
all managed WordPress websites, then core, plugins, themes, or all components.
For plugins, choose all installed plugins or select one or more numbered plugins
(separate numbers with spaces or commas). The selection list combines plugins
across the selected websites; sites without a selected plugin are skipped for
plugin-only updates. Must-use plugins and drop-ins are excluded from selection.

The numbered plugin list shows installed and available versions per website.
Before confirmation, a version preview shows core and selected plugin/theme
versions. Components with no reported update are labeled accordingly; failed
version checks are shown as unknown rather than as up to date.

Review the website/component selection and confirm before starting. The updater
installs WP-CLI with SHA-512 verification if it is missing. Each website uses its
configured PHP version and Unix account. Choose whether to create a backup before
updating (default: yes). When enabled, the updater saves a complete file archive
and database dump in a private directory under
`/home/domains/<site>/backup/files/pre-update_*`; failed backups stop that site's
update. A tar exit-1 warning containing only live-file-change messages is allowed
after archive integrity checks; real read, compression or archive errors still
stop the update. Backups are automatically deleted after successful updates and
retained after failed updates for manual restoration. Choosing no backup skips
both the archive and database dump for that run.
Core updates also run the WordPress database upgrade.
Failed websites do not stop the batch. Review the final success/failure/skip
counts and `/var/shieldpress/logs/wp-update.log` for details. Backups are retained
only after failures; updates are not automatically rolled back.

Keep plugins/themes updated and review malware findings before deleting files.

## 5. Laravel

`Laravel Manager` installs Laravel runtime/components, creates Laravel domains,
prepares Composer and frontend dependencies, runs builds and deploys production
applications. It also provides `.env` editing, Artisan commands, queue restart,
scheduler operations, cache optimization, logs, status and permissions repair.

Typical post-deploy actions are:

```bash
php artisan migrate --force
php artisan storage:link
php artisan optimize:clear
php artisan queue:restart
```

Run these from the application directory and only after taking a backup.

## 6. Node.js and Next.js

`Node.js Manager` installs/updates Node.js, creates Node domains, manages PM2,
builds and deploys applications, changes ports/entry files, displays logs and
performs health checks. Next.js applications must use the domain's configured
port; ShieldPress passes the explicit port to the PM2 process and refreshes its
environment on restart.

For a project with configuration outside the project root, put the file where
the application expects it or load it explicitly in the PM2 ecosystem/start
command. For example, `/home/domains/example/config/.env` is not automatically
read by Next.js merely because it exists there. Use PM2 `env`/`env_production`,
`dotenv` in application code, or copy/link the file to the project root with
secure ownership. Never expose secrets through a public directory.

After changing `.env` or the port, use Node.js Manager restart/redeploy so PM2
receives the new environment; a normal web reload does not change an existing
process environment.

### Deploy modes and Prisma migrations

Node.js Manager → `Deploy / Build` provides three choices:

- **Standard update** builds the application and restarts its existing PM2 app
  with refreshed environment values. Use it for code or `.env` changes that do
  not change dependencies or the database schema.
- **Initial deploy** installs dependencies, applies reviewed Prisma migrations,
  builds, and starts the app when it has no PM2 process yet.
- **Dependencies + DB migration** installs dependencies, applies reviewed
  Prisma migrations, builds, and restarts the existing app.

Builds run in a systemd service capped at 60% of physical RAM. Early memory
throttling is disabled; the hard RAM cap still applies to all build children.
The swap budget is the smallest of free swap minus a 512 MB reserve, twice the
RAM budget, and 4096 MB, with a minimum of zero. ShieldPress never creates swap
or changes database settings. Heap limits include a small swap allowance and
are rounded down to 64 MB increments, with a maximum of 4096 MB.

Example profiles with 4096 MB of **free** swap and at least four CPU cores:

| Physical RAM | Build RAM cap | Build swap cap | V8 heap per process | CPU cap | Timeout |
| --- | --- | --- | --- | --- | --- |
| 1 GB | 614 MB | 1228 MB | 768 MB | 1 | 90 min |
| 2 GB | 1228 MB | 2456 MB | 1152 MB | 1 | 90 min |
| 3 GB | 1843 MB | 3584 MB | 1600 MB | 1 | 60 min |
| 4 GB | 2457 MB | 3584 MB | 1984 MB | 1 | 60 min |
| 8 GB | 4915 MB | 3584 MB | 3648 MB | 2 | 60 min |
| 16 GB+ | 60% | up to 4096 MB | up to 4096 MB | up to 4 | 60 min |

Actual values use reported RAM, free swap and available CPU cores. Next.js
builds are refused before compilation if the combined RAM/swap budget is
below 1536 MB. This is a minimum admission check, not a guarantee that a
project will fit. Swap can make compilation considerably slower. For a large
project on a 1–2 GB VPS, build on another machine and deploy its artifact.
Set `SHIELDPRESS_BUILD_TIMEOUT=120m` in the environment launching ShieldPress
to allow more time (positive integer with `s`, `m` or `h` suffix).

For Next.js 15+ using webpack, merge these settings into the application's
existing `next.config.*` (keep its other options):

```ts
const nextConfig = {
  distDir: process.env.NEXT_DIST_DIR || ".next-release",
  experimental: {
    cpus: 1,
    workerThreads: false,
    webpackBuildWorker: true,
    webpackMemoryOptimizations: true,
  },
};
```

Custom webpack hooks disable the build worker by default; explicitly enabling
it and memory optimizations helped the Mythuatbui deployment fit within a
2192 MB RAM cap. Check compatibility with custom plugins. ShieldPress warns
when an existing Next.js config lacks memory optimizations; it does not rewrite
application configuration automatically. See the
[Next.js memory guide](https://nextjs.org/docs/app/guides/memory-usage).
Ensure Tailwind ignores generated/candidate/rollback output; the candidate
deployment path adds `/.next*/` to `.gitignore` automatically.

Build output passes through a pipe so systemd does not receive a regular log
file descriptor under SELinux. The original build exit status is preserved.
On an OOM or timeout, the menu cleans up candidate output and retains the live
release; it never stops the database to make room for the build.

After dependencies and migrations
succeed but a build fails, retry with **Standard update**; database migrations
have already been applied and are not rolled back by a build failure.

For Next.js projects whose `next.config.*` reads `NEXT_DIST_DIR` into `distDir`,
Deploy / Build writes to a separate `.next.candidate.<pid>` directory and checks
for `BUILD_ID` before replacing `.next-release`. The previous release is kept
as `.next-release.deploy-backup.<pid>` after a successful PM2 reload. The app
must keep using `NEXT_DIST_DIR=.next-release` at runtime. PM2 reload can avoid
downtime in cluster mode; in fork mode PM2 may fall back to a restart. Apps
without this config support continue using the standard `.next` build path.

For a Prisma project, create and test migrations locally with `npx prisma
migrate dev --name <change>`, then commit the generated `prisma/migrations/`
directory with the application code. On the VPS ShieldPress runs `npx prisma
migrate deploy`, not `prisma db push`; it requires migration files and asks for
confirmation that a current database backup exists and the migration SQL was
reviewed. Use an expand/contract release sequence for destructive schema
changes such as dropping columns or changing data types.

## 7. MariaDB and PostgreSQL

`Database Manager` supports database/user creation, listing, information,
password rotation, SQL import, deletion, tuning and Adminer where applicable.
For an existing MariaDB or PostgreSQL database, `Create User for Existing DB`
creates a separate login with selectable data permissions: read (`SELECT`),
view (`SHOW VIEW`/table read), edit (`INSERT`/`UPDATE`) and delete (`DELETE`).
Privileges are not granted unless selected. `Network / Port Configuration`
can change the database bind address and port; remote binding requires an
explicit source IP/CIDR and can add a restricted firewalld rule. Keep the
default loopback bind unless remote database access is necessary.
After changing the network settings, use `Test Database Connection` (or choose
the immediate test prompt) to select a database and login account and verify a
real TCP `SELECT 1` connection.
Database ports should remain private unless a restricted firewall rule is
intentional.

PostgreSQL WAL policy is selected by database number. A shared PostgreSQL
cluster has one WAL stream; domains using that cluster cannot have physically
separate WAL archives. The domain records participation and health, while
PostgreSQL/pgBackRest archives at cluster level. The one-minute check never runs
`pg_dump`.

## 8. Backup and remote storage

`Backup & Restore` provides database, files, full, automatic, remote, Telegram
backup, restore, deletion and status views. Existing daily ShieldPress backups
remain unchanged when WAL or replication is enabled.

Configure remote storage in `Backup & Restore → Remote Storage`:

- S3/S3-compatible: AWS, Cloudflare R2, DigitalOcean Spaces, Backblaze, MinIO.
- Google Drive or OneDrive through rclone.
- An existing rclone remote, including FTP/SFTP.

Normal backup archives upload after they are created. PostgreSQL WAL is written
locally first and an every-minute systemd job copies the pgBackRest repository
to configured remotes. A cloud outage does not block local WAL archiving. Check:

```bash
systemctl status shieldpress-pgbackrest-wal-remote.timer
tail -f /var/log/shieldpress/pgbackrest-wal-remote.log
```

WAL remote copies are append-safe and are not automatically deleted. Configure
credentials only as root; never commit rclone or pgBackRest secret files.

## 9. PostgreSQL streaming replication

This is asynchronous physical replication: Laravel writes only to Primary.
There is no application dual-write. Use two separate AlmaLinux servers with
private, reliable connectivity.

On Primary, open `Database → PostgreSQL Manager → Streaming Replication` and
choose `Configure Primary + S3 pgBackRest`. Enter the Standby IPv4 address,
replication role/password, slot name, bind address/port and S3 settings. The
module creates a physical replication slot, restricts `pg_hba.conf` and
firewall access to the Standby IP, enables `wal_level=replica`, configures
pgBackRest repo2 as S3 and installs a one-minute health timer.

Before initializing Standby, create a pgBackRest full backup:

```bash
sudo -u postgres pgbackrest --stanza=<stanza> check
sudo -u postgres pgbackrest --stanza=<stanza> backup --type=full
```

On Standby, choose `Initialize Standby`. It uses `pg_basebackup -R -X stream`
and the existing slot. Replacing the data directory requires typing `REPLACE`.
Check both machines:

```bash
/opt/shieldpress/modules/database/postgres-replication.sh --health
systemctl status shieldpress-postgresql-replication-health.timer
```

For a safe PITR check, choose `Test isolated restore`; it restores into a
temporary directory and does not replace the running cluster. For failover:

1. Confirm the old Primary is fenced or powered off to prevent split brain.
2. On Standby, choose `Promote Standby` and confirm.
3. Verify PostgreSQL accepts writes and run an application health check.
4. Move the DNS/load-balancer/application endpoint to the promoted server.
5. Rebuild the old Primary as a Standby before returning it to service.

Promotion does not automatically change DNS, Laravel `.env`, queues or the
load balancer. Do not reconnect both writable servers at the same time.

## 10. Cache and performance

Cache Manager handles OPcache, Valkey, WordPress object cache, FastCGI cache,
per-domain purge/warmup, hit ratio and global cache clearing. Optimization
handles PHP-FPM, MariaDB, Nginx, Valkey, PHP JIT, HTTP/3, upload limits and
automatic RAM tuning. Apply tuning after checking available RAM and workload.

## 11. Security and CVE checks

Security Center manages firewalld, ports, IP block/whitelist/history, Fail2ban,
WordPress brute-force protection, bot-country rules, SSH hardening, Auto-Guard,
audits and CVE/dependency checks for system packages, Composer, npm,
WordPress core/plugins/themes and service versions.

Keep SSH restricted, use key authentication, close unused ports and review
security/CVE results before deploying updates. Updates are checksum-gated when a
release checksum is available; review package source and release assets before
production rollout.

## 12. Monitoring, repair and logs

Monitoring provides resource checks, bandwidth and traffic analysis, domain HTTP
health checks, live/access/error/PHP-FPM/MariaDB/PostgreSQL logs, slow-query and
PHP slow-log analysis, log rotation and cleanup. Repair provides integrity
checks, service recovery, permissions repair and emergency restore helpers.

Important runtime locations:

```text
/var/shieldpress/logs/                 ShieldPress operational logs
/var/shieldpress/data/                 Runtime metadata
/var/shieldpress/update-backups/       Update rollback archives
/home/backup-all/                      Existing global backups
/var/shieldpress/backups/postgresql-wal/ Local pgBackRest WAL repository
/etc/pgbackrest/pgbackrest.conf        pgBackRest configuration (secrets)
/etc/shieldpress/                      ShieldPress runtime configuration
/home/domains/<domain>/config/         Per-domain configuration
```

## 13. Email, SFTP and tools

Email Server configures mailboxes, Postfix/Dovecot, webmail, DNS, relay,
OpenDKIM, Rspamd and mail TLS. Validate DNS records and reverse DNS before
production mail use.

SFTP Manager creates isolated domain accounts, resets passwords and controls
account state. Tools provides configuration editors, reloads, logs, Meilisearch,
service monitors and database exports. Disk Manager shows storage usage and
large files; RAM Manager controls swap/ZRAM-related operations.

In Tools → Meilisearch, use **Create Search Key** for search-only access or
**Create Key** for server-side product synchronization. Both keys are
restricted to the selected domain's product index. CRM keys can search, read and
create that index, add/delete documents, read/update settings and read tasks.
They cannot manage API keys or delete indexes.

For an existing domain, choose **Create Key**, then **Show CRM Sync Key**.
Copy `MEILI_CRM_KEY` into the CRM's Meilisearch API key field and use the displayed
endpoint and index. Test the connection and run product synchronization in the
CRM. The key is saved separately from `MEILI_KEY`; existing search keys remain
unchanged on upgrade and when creating, rotating or revoking a CRM key. Each key
type has its own show and revoke options. Keep the CRM key in server-side
configuration only. An upgrade makes these options available without
automatically granting write permissions to existing search credentials.

## 14. Updates and rollback

Use:

```bash
shieldpress update
```

The updater checks the GitHub version, creates a rollback archive outside the
runtime source tree, downloads the release package, verifies its SHA-256,
switches atomically, checks services and applies migration patches. Rollback
archives are stored in `/var/shieldpress/update-backups/`.

After every update, verify the version, service status, Nginx configuration,
application health, backup status and relevant timers. Do not delete the update
backup until the new release has been validated.

## 15. Troubleshooting checklist

```bash
systemctl --failed
systemctl status nginx mariadb postgresql valkey
nginx -t
journalctl -u postgresql -n 100 --no-pager
tail -n 100 /var/shieldpress/logs/update.log
```

For PostgreSQL WAL issues, check `pgBackRest check`, `archive_command`, the
cluster WAL repository, SELinux context, the WAL status files and the remote WAL
timer. For replication issues, check `pg_stat_replication` on Primary,
`pg_stat_wal_receiver` on Standby, slot activity, firewall rules and network
reachability. Never remove a replication slot while the Standby may need its
WAL; an inactive slot can retain WAL and fill the disk.

### SSL automatic renewal and existing certificates

New website certificates use `/var/www/shieldpress-acme` for HTTP-01 files and
the Nginx installer for HTTPS configuration. A persistent Nginx location serves
these files directly, independently of PHP or Node.js. ShieldPress restores
SELinux file contexts when SELinux is enabled and checks every requested
hostname over HTTP before requesting a certificate. The check requires HTTP
200 and the exact probe content; it removes the probe afterwards.

If preflight reports HTTP 500, inspect the domain's Nginx error log, DNS A/AAAA,
server-level rewrites/access rules and any reverse proxy. The probe runs from
the VPS through public DNS, so public-IP loopback must work too. It does not
guarantee reachability from every external network or every DNS address.
Existing custom ACME locations require manual reconciliation; the installer
restores the original vhost instead of overwriting them. Failed configuration,
reload or validation restores the previous vhost before returning failure.

Installing Let's Encrypt or ZeroSSL configures the available Certbot systemd
timer. AlmaLinux/RHEL uses `certbot-renew.timer`; Debian and snap use their
packaged timers. When none exists, ShieldPress creates
`shieldpress-certbot-renew.timer` to check twice daily with a randomized delay.
The installer verifies that the timer is both enabled and active.

If the selected domain already has a Certbot certificate and renewal file,
Install SSL preserves its provider and domain names, renews only when Certbot
considers it due, and reinstalls the certificate into Nginx. It does not delete
a valid certificate or force a new issuance. Mail SSL uses Nginx HTTP-01 and
reloads Postfix/Dovecot after successful renewals. Legacy standalone lineages
are migrated using Certbot 2.3+ reconfigure, including a staging validation.

Existing servers receive the SSL auto-renew migration through Migration
Patches on update. To retry a failed setup directly on an updated server:

```bash
bash /opt/shieldpress/modules/ssl/setup-auto-renew.sh
certbot renew --cert-name example.com --dry-run
```

Check SSL Status for the active timer and last job result. Timer activation
does not prove that domain validation succeeds; use dry-run to verify it.
Manual wildcard DNS validation needs a DNS plugin or authentication hook for
automatic renewal. Cloudflare Origin and custom certificates retain their
provider-specific replacement workflow.

Local regression checks (no VPS or ACME access):

```bash
python3 tests/ssl-renewal.py
bash tests/smoke.sh
```
