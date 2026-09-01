# ShieldPress VPS User Guide

This guide covers the normal installation, operation, backup, security and
failover workflows for ShieldPress VPS on AlmaLinux 9 or 10.

## 1. Requirements and installation

Use a fresh AlmaLinux 9/10 server with at least 2 GB RAM, 5 GB free disk and
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

Before major updates, create a full backup. Keep plugins/themes updated and
review malware findings before deleting files.

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

## 7. MariaDB and PostgreSQL

`Database Manager` supports database/user creation, listing, information,
password rotation, SQL import, deletion, tuning and Adminer where applicable.
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
