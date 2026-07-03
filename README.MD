# ShieldPress VPS

**Current version:** `1.0.6`

ShieldPress VPS is a terminal-based server management toolkit for Linux VPS, focused on deploying websites, managing domains, SSL, WordPress, Laravel, Node.js, databases, cache, backup, security, performance optimization, email and system monitoring.

Source code is in the `shieldpress/` directory. On the server it installs to `/opt/shieldpress`, domain data is stored at `/home/domains`.

## Requirements

| Requirement | Minimum |
|-------------|---------|
| OS | AlmaLinux 9 or AlmaLinux 10 |
| RAM | 2 GB |
| Disk | 5 GB free |
| Access | Root (SSH) |
| Network | Public IP with internet access |

> **Note:** ShieldPress VPS only supports AlmaLinux 9 and 10. Other distributions (Ubuntu, CentOS, Debian, etc.) are not supported.

## Installation

Connect to your VPS via SSH as root and run:

```bash
curl -fsSL https://install.shieldpress.net | bash
```

The installer will:

1. Verify OS compatibility (AlmaLinux 9/10 only).
2. Check minimum RAM (2 GB) and disk space (5 GB).
3. Install the full server stack (Nginx, PHP, MariaDB, Valkey, etc.).
4. Set up the `shieldpress` command for quick access.
5. Display the dashboard on completion.

After installation, type `shieldpress` to open the admin panel.

## Quick Commands

```bash
shieldpress          # Open dashboard
shieldpress menu     # Admin menu
shieldpress update   # Check for updates
shieldpress cache    # Clear all cache
shieldpress domain   # Add domain
shieldpress ssl      # Install SSL
shieldpress backup   # Backup menu
shieldpress help     # Show help
```

## Main Components

- `shieldpress/shieldpress.sh` — Dashboard, main menu, quick commands, update check, service status and resource monitoring.
- `shieldpress/install.sh` — Installer script, sets up the `shieldpress` command.
- `shieldpress/modules/` — All feature modules.
- `shieldpress/core/` — Terminal UI, helpers, validators, logger and system info.
- `shieldpress/version.txt` — Installed version. Must be synced with release version.

## Dashboard

The main dashboard provides a real-time overview of the VPS:

- Resource monitoring: Disk, RAM, Swap, CPU load, domain count, open ports and active alerts.
- Service status: Nginx, MariaDB, PostgreSQL, Valkey, Firewall, Fail2ban and PHP-FPM.
- Application count: WordPress, Laravel, Node.js sites.
- Performance: HTTP/3, FastCGI Cache, Nginx connections, request sample and Valkey memory.
- Alerts: High disk/RAM, Nginx down, Firewall down or database port public.
- Quick actions: Admin Menu, Update, Clear All Cache, Add Domain, Install SSL, Backup.

## Admin Menu Structure

```
ShieldPress VPS Admin Menu
├── Server
│   ├── [ 1] Install Stack / Dashboard
│   ├── [ 2] Core Server
│   ├── [ 3] Nginx Manager
│   └── [ 4] PHP Manager
├── Applications
│   ├── [ 5] Domain Manager
│   ├── [ 6] SSL Manager
│   ├── [ 7] WordPress Manager
│   ├── [ 8] Laravel Manager
│   ├── [ 9] Node.js Manager
│   └── [10] Database Manager
├── System
│   ├── [11] Backup & Restore
│   ├── [12] Cache Manager
│   ├── [13] Security & Firewall
│   ├── [14] Monitoring & Logs
│   ├── [15] Upgrade Manager
│   ├── [16] Self-Healing & Repair
│   ├── [17] Optimization
│   ├── [18] RAM Manager
│   ├── [19] Disk Manager
│   └── [20] SFTP Manager
├── Settings
│   ├── [21] Tools & Utilities
│   ├── [22] Telegram Notifications
│   ├── [23] ShieldPress Monitor
│   ├── [24] Email Server
│   └── [25] About Us
└── [ 0] Exit
```

## Modules

### 1. Server Setup & Core Server

Source: `modules/install/`, `modules/core/`, `modules/helpers/`

- Install the ShieldPress VPS stack.
- Check core service status: Nginx, MariaDB, PostgreSQL, Valkey, Firewall, Fail2ban and PHP-FPM versions.
- Restart all services.
- View versions: ShieldPress, Nginx, MariaDB, PostgreSQL, Valkey, Node.js, npm, Composer.
- Update ShieldPress VPS.
- Update OS/core packages.
- Auto-tune database settings based on server RAM for MariaDB and PostgreSQL.
- View system info and core logs.

### 2. Domain & SSL Manager

Source: `modules/domain/`, `modules/ssl/`

Domain features:

- Add WordPress/PHP, Laravel or Node.js domains.
- List managed domains.
- Delete domains.
- Change PHP version per domain.
- Configure domain settings: PHP limits, upload/post size, execution time and pool settings.
- Set domain URL.
- Lock/unlock domains.
- Fix domain permissions.

SSL features:

- Install free SSL (Let's Encrypt).
- Install custom SSL (paid certificates).
- Install Cloudflare Origin SSL.
- Renew SSL.
- Remove SSL.
- Check SSL status.
- Auto SSL (wildcard).

### 3. WordPress Manager

Source: `modules/wordpress/`

- Install WordPress.
- Update WordPress core/plugins/themes.
- Security hardening.
- Performance optimization.
- Run Security + Optimize bundle.
- Create, sync and delete staging environments.
- Switch WP-Cron to system cron.
- Malware scan.
- Reset WordPress admin password.

### 4. Laravel Manager

Source: `modules/laravel/`

- Install Laravel runtime.
- Install PostgreSQL stack.
- Add Laravel domains.
- List Laravel domains.
- Manage PostgreSQL for Laravel.
- Backup Laravel/PostgreSQL.
- Manage Redis/Valkey cache for Laravel.
- Install Laravel components.
- Run `npm run build`.
- Deploy/build production.
- Edit `.env` file.
- Common Artisan commands: `storage:link`, `optimize:clear`, optimize cache, queue restart, scheduler run.
- View Laravel logs.
- Check runtime/status.
- Fix permissions.
- Advanced Artisan for custom commands.

### 5. Node.js Manager

Source: `modules/nodejs/`

- Install or update Node.js runtime.
- Add Node.js domains.
- List Node.js domains.
- View running Node.js apps.
- Backup Node.js apps.
- Deploy/build production or install dependencies.
- Start/restart apps.
- PM2 management: start, stop, status, logs.
- View app logs.
- Check runtime/status.
- Fix permissions.
- Advanced tools: stop app, change port, edit service, change entry file, health check.

### 6. Database Manager

Source: `modules/database/`

MariaDB features:

- Create database and user.
- List databases.
- Delete database and user.
- Change database password.
- Import SQL.
- Import SQL to domain database.
- Optimize database.
- Enable/disable/remove Adminer.
- Configure database settings.
- Assign database to website.

PostgreSQL features:

- Create database and user.
- List databases.
- View database info.
- Delete database and user.
- Change database password.
- Import SQL.
- Backup database.
- Configure auto backup.
- List backups.

### 7. Backup & Restore

Source: `modules/backup/`

- Backup database.
- Backup source files.
- Full backup (database + files).
- Auto backup scheduling: database, files or full.
- Configure remote backup.
- Upload existing backup to remote.
- Restore website.
- Delete backup files.
- View backup status/list per domain.
- Backup via Telegram.

### 8. Cache Manager

Source: `modules/cache/`

- Manage OPcache.
- Manage Valkey server.
- Configure WordPress Object Cache.
- Enable/disable FastCGI Cache.
- View cache hit ratio.
- Purge cache per domain.
- Warmup cache per domain.
- Clear all cache.
- View Smart Cache Status.
- Remove Valkey/cache engine.

### 9. Security Center

Source: `modules/security/`

- Security dashboard: Firewall, Fail2ban, blocked IPs, whitelist, open ports, recent requests and attack indicators.
- View firewall status.
- Open/close ports.
- Block IP.
- Whitelist IP.
- Remove IP rules.
- List blocked IPs.
- View IP block history.
- Enable Fail2ban SSH.
- Manage Fail2ban SSH.
- WordPress brute force protection.
- Block/unblock bot countries.
- Security audit.

### 10. Monitoring & Logs

Source: `modules/monitor/`

- Bandwidth statistics per domain.
- Spike/attack detection.
- Check server resources.
- Log analysis.
- View top access IPs.
- Live log tail.
- Enable log rotation.
- Clean old logs.

### 11. Tools & Utilities

Source: `modules/tools/`

- Edit Nginx configuration.
- Edit PHP configuration.
- Edit database configuration.
- View PHP modules.
- Install/remove ionCube.
- View logs.
- Install Meilisearch.
- Auto-reload MariaDB via service monitor.
- Auto-reload PHP-FPM via cron.
- Reload PHP/Nginx.

### 12. SFTP Manager

Source: `modules/sftp/`

- Create SFTP accounts per domain.
- View account info.
- List SFTP accounts.
- Enable/disable accounts.
- Reset password.
- Delete SFTP accounts.
- Chroot isolation to restrict users to their domain directory.

### 13. Optimization Center

Source: `modules/optimize/`

- Optimize PHP-FPM.
- Optimize MariaDB.
- Optimize Nginx.
- Optimize Valkey/Redis.
- Enable PHP JIT.
- RAM tools.
- Fix domain permissions.
- Manage upload limits.
- Full Auto Optimize.
- RAM Auto Optimizer.
- Enable/disable HTTP/3.
- Tune Nginx for Laravel/Node.js apps.

### 14. Email Server

Source: `modules/email/`

1-click mail server installer with Postfix, Dovecot, Rspamd, OpenDKIM, Fail2Ban and Let's Encrypt SSL.

Features:

- Install/uninstall mail server (1-click).
- Create email accounts per domain (e.g. support@domain.com).
- Delete email accounts.
- List email accounts with mailbox size.
- Change email password.
- Configure SMTP relay: Brevo (free 300 emails/day) or Amazon SES.
- Test outbound email (send via relay).
- Test inbound email (local delivery).
- Test SMTP/IMAP authentication.
- Full diagnostics: services, ports, config, SSL, DNS, firewall, Fail2Ban.
- DNS records guide (MX, A, SPF, DKIM, DMARC, PTR).
- Export DNS records to `/home/dns-records-{domain}.txt` for Cloudflare.

Architecture:

```
Inbound:  Internet → MX → Postfix → Rspamd → Dovecot (LMTP) → Maildir
Outbound: Client → Postfix → OpenDKIM → SMTP Relay (Brevo/SES) → Internet
Read:     IMAP port 993 (SSL) via Thunderbird, Outlook or mobile app
Send:     SMTP port 587 (STARTTLS) via mail client
Spam:     Rspamd with auto-learn, spam moved to Junk via Sieve
Security: Fail2Ban jails for Postfix, Dovecot and Postfix-SASL
```

Email Server sub-menu:

```
Email Server
├── [ 1] Install Email Server
├── [ 2] Add Email Account
├── [ 3] Delete Email Account
├── [ 4] List Email Accounts
├── [ 5] Change Password
├── [ 6] SMTP Relay (Brevo/SES)
├── [ 7] Test Send & Receive
├── [ 8] Email Server Status
├── [ 9] DNS Records Guide
├── [10] Uninstall Email Server
└── [ 0] Back
```

### 15. Domain Isolation

Source: `modules/isolation/`

- Fix permissions for all domains.
- Apply `open_basedir` to restrict PHP access scope.
- Audit isolation status.
- Repair all isolation.

### 16. Telegram Notifications

Source: `modules/notification/`

- Configure Telegram bot token, chat ID and API base.
- Toggle event groups: backup success, backup fail, server alerts, security alerts, info messages.
- Configure alert thresholds for disk, RAM and load.
- Schedule server monitor via cron: 5 min, 15 min, 30 min or hourly.
- Send test message.

### 17. Upgrade Manager

Source: `modules/upgrade/`

- Check for new version from `https://install.shieldpress.net/version.txt`.
- Update ShieldPress VPS via `updater.sh`.
- Log updates to `/opt/shieldpress/logs/update.log`.
- Update OS/core packages and restart related services.

### 18. Disk Manager

Source: `modules/disk/`

- View disk usage overview.
- Find large files in a domain.
- Find large files across all domains.
- View backup storage usage.

### 19. RAM Manager

Source: `modules/ram/`

- Monitor RAM usage and processes.
- Memory optimization tools.

### 20. ShieldPress Monitor

Source: `modules/shieldpress/`

- Connect server to remote monitoring system.
- Change data send interval.
- Start/stop monitor service.
- View monitor status.
- Send data immediately.
- View file changes.
- View login activity.
- View logs.
- Remove monitor service.

### 21. Clone Manager

Source: `modules/clone/`

- Clone website from source domain to target domain.
- File and database operations for internal cloning.

### 22. License Manager

Source: `modules/license/`

- Check local license status.
- Activate license.
- Remove/deactivate license.

## Runtime Directory Structure

```
/opt/shieldpress/           ShieldPress installation directory
├── shieldpress.sh          Main entry point
├── install.sh              Installer
├── version.txt             Current version
├── modules/                Feature modules
├── core/                   UI, helpers, logger, validator
├── config/                 Configuration files
├── templates/              Config templates
├── logs/                   ShieldPress logs
└── data/                   Auxiliary data (e.g. Valkey info)

/etc/shieldpress/           System configuration
/home/domains/              Website/domain data root
/var/mail/vhosts/           Email mailboxes (when email module installed)
/var/log/nginx/domains/     Nginx logs per domain
```

## Version Upgrade Notes

When upgrading ShieldPress VPS, check the following:

1. Update version in `shieldpress/version.txt` and this README to the same version.
2. Verify `shieldpress/shieldpress.sh` displays the correct version and update status.
3. If adding a new module, add it to the main menu in `shieldpress/shieldpress.sh`.
4. If adding new scripts in `shieldpress/modules/`, update the "Modules" section in this README.
5. If a module requires new services or cron jobs, document the service/cron file, log file and enable/disable instructions.
6. If changing the `/home/domains` structure, verify domain, backup, SSL, cache, SFTP and isolation modules.
7. If changing database/cache, verify MariaDB, PostgreSQL, Valkey, Adminer, backup and restore.
8. If changing the update flow, verify `modules/update/update-menu.sh`, `modules/update/updater.sh` and `/opt/shieldpress/logs/update.log`.
9. After release, test key menus: domain, SSL, WordPress, backup, cache, security, email and update.

## Pre-release Checklist

```bash
# Syntax check all scripts
bash -n shieldpress/shieldpress.sh
bash -n shieldpress/install.sh
bash -n shieldpress/modules/*/*.sh

# Manual tests
shieldpress                    # Dashboard loads without errors
shieldpress help               # Help displays correctly
# Test update check with internet
# Test domain, SSL, backup, restore if related changes were made
# Test email install, send, receive if email module changed
```

## Changelog

### v1.0.6

- Added Email Server module (`modules/email/`) with 1-click installer.
- Components: Postfix, Dovecot, Rspamd, OpenDKIM, Fail2Ban mail jails, Let's Encrypt SSL.
- SMTP relay support: Brevo (free 300/day) and Amazon SES.
- Email account management: add, delete, list, change password.
- Test suite: outbound send, inbound receive, SMTP/IMAP auth, full diagnostics.
- DNS records guide with export to file for Cloudflare.
- Menu option [24] Email Server added to admin menu.
- About Us moved to [25].

## Links

- Website: [https://shieldpress.net](https://shieldpress.net)
- Email: support@shieldpress.net

## Documentation

- Version: `1.0.6`
- This README serves as feature documentation and reference for future upgrades.
