# ShieldPress VPS Menu Guide

This guide explains how to use every menu in ShieldPress VPS. It complements the
[full user guide](GUIDE.md), which covers concepts, procedures and troubleshooting.
Menu numbers below match version 1.3.147; the menu on your server is always the
authoritative list.

## Contents

1. [Basics](#1-basics)
2. [Main (Admin) menu](#2-main-admin-menu)
3. [Server](#3-server): Core Server, Nginx, PHP
4. [Applications](#4-applications): Domains, SSL, WordPress, Laravel, Node.js, Databases
5. [System](#5-system): Backup, Cache, Security, Monitoring, Upgrade, Repair, Optimization, RAM, Disk, SFTP
6. [Settings](#6-settings): Tools, Telegram, Monitor, Email, Patches, Update, GitHub

## 1. Basics

Open the dashboard with `shieldpress`, or go straight to the Admin Menu with
`shieldpress menu`. Run `shieldpress help` to list shortcuts such as
`shieldpress domain`, `shieldpress ssl`, `shieldpress backup`, `shieldpress cache`,
`shieldpress update` and `shieldpress github`.

Conventions used by every menu:

- Type the option number and press Enter. `0` goes back (or exits from the main menu).
- A prompt such as `[Y/n]` or `[y/N]` shows the default in capitals; press Enter to accept it.
- Destructive or shared-runtime actions ask for confirmation. Some require typing `YES`.
- Long tasks show the active stage, a loading indicator and an estimated duration.
  If the estimate is exceeded the task keeps running; do not interrupt it.
- Menus that act on one site ask you to select a domain first.
- ShieldPress never restarts your applications silently after a runtime change.
  Review and restart each application yourself.

## 2. Main (Admin) menu

| # | Menu | Purpose |
|---|------|---------|
| 1 | Install Stack / Back to Dashboard | First-time stack installation; afterwards returns to the dashboard |
| 2 | Core Server | Service status, restarts, versions, system information |
| 3 | Nginx Manager | Web server tuning, caching, headers, rate limits |
| 4 | PHP Manager | PHP-FPM, OPcache, versions and extensions |
| 5 | Domain Manager | Create, list, delete and configure domains |
| 6 | SSL Manager | Certificates (Let's Encrypt, ZeroSSL, custom, Cloudflare) |
| 7 | WordPress Manager | Install, update, harden and recover WordPress sites |
| 8 | Laravel Manager | Laravel runtime, domains, queues, Redis, Artisan |
| 9 | Node.js Manager | Node.js runtime, domains, PM2 apps, deployments |
| 10 | Database Manager | MariaDB and PostgreSQL |
| 11 | Backup & Restore | Local and remote backups, schedules, encryption |
| 12 | Cache Manager | Valkey/Redis, page cache purge and warmup |
| 13 | Security & Firewall | Firewall, Fail2ban, SSH, malware and CVE scans |
| 14 | Monitoring & Logs | Bandwidth, logs, health checks, slow queries |
| 15 | Upgrade Manager | Controlled upgrades of Nginx, PHP, databases, Node.js |
| 16 | Self-Healing & Repair | Integrity checks, auto-repair, snapshots, emergency restore |
| 17 | Optimization | Permissions, Valkey and full automatic tuning |
| 18 | RAM Manager | RAM status, ZRAM, swap |
| 19 | Disk Manager | Disk usage and largest files |
| 20 | SFTP Manager | Per-site SFTP accounts |
| 21 | Tools & Utilities | Config editing, logs, Meilisearch, migration |
| 22 | Telegram Notifications | Alerts and thresholds |
| 23 | ShieldPress Monitor | Remote monitoring service |
| 24 | Email Server | Mail server, accounts, relay |
| 25 | About Us | Product information |
| 26 | Migration Patches | Show and apply pending migrations |
| 27 | Update ShieldPress VPS | Check for and install a new ShieldPress release |
| 28 | GitHub | Deploy applications from GitHub with read-only deploy keys |
| 0 | Exit | Leave the menu |

## 3. Server

### 2) Core Server

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Service Status | See whether Nginx, PHP-FPM, databases and cache are running |
| 2 | Restart Stack | Restart the web stack services |
| 3 | Show Versions | Display installed component versions |
| 4 | Update ShieldPress VPS | Install a new ShieldPress release |
| 5 | Update OS/Core Packages | Apply operating-system package updates |
| 6 | Optimize Databases | Optimize database tables |
| 7 | System Information | Show CPU, memory, disk and OS details |
| 8 | View Core Logs | Read ShieldPress core logs |

### 3) Nginx Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Optimize Nginx | Apply tuned worker and connection settings |
| 2 / 3 | Enable / Disable HTTP/3 | Turn HTTP/3 (QUIC) on or off |
| 4 | Tune Laravel/Node Nginx | Apply proxy and FastCGI tuning for Laravel and Node.js sites |
| 5 / 6 | Enable / Disable FastCGI Cache | Turn page caching on or off |
| 7 | Upload Limit Manager | Change maximum upload size |
| 8 | Security Headers | Add standard security headers |
| 9 | Brotli Compression | Enable Brotli |
| 10 | Rate Limiting | Limit request rates |
| 11 | Password Protection | Overview, enable, disable, toggle or change HTTP basic-auth credentials per domain |
| 12 | Nginx Status & Info | Show status and build information |
| 13 | Edit Nginx Config | Edit configuration safely |
| 14 | View Nginx Logs | Read access and error logs |
| 15 | Reload Nginx | Reload after a configuration test |
| 16 | Version & Security Updates | Check versions and apply same-branch updates |

### 4) PHP Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Optimize PHP-FPM | Tune pool settings for available RAM |
| 2 | Enable PHP JIT | Turn on the JIT compiler |
| 3 | OPcache Manager | Inspect and manage OPcache |
| 4 | Change PHP Version | Switch a site to another installed PHP version |
| 5 | Install/Remove PHP Version | Add or remove PHP versions |
| 6 | PHP Extension Manager | Install or remove extensions |
| 7 / 8 | Install / Remove ionCube | Manage the ionCube loader |
| 9 | Show PHP Modules | List loaded modules |
| 10 | PHP Info Viewer | View PHP configuration |
| 11 | Edit PHP Pool Config | Edit a site's PHP-FPM pool |
| 12 | Auto-Reload PHP-FPM | Configure automatic reloads |
| 13 | Reload PHP-FPM | Reload PHP-FPM now |
| 14 | Version & Security Updates | Check versions and apply same-branch updates |

## 4. Applications

### 5) Domain Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Add Domain | Create a site: WordPress, PHP, Laravel or Node.js |
| 2 | List Domains | Show all managed domains |
| 3 | Delete Domain | Remove a domain and its data (asks for confirmation) |
| 4 | Change PHP Version | Select a PHP version for one domain |
| 5 | Domain Configuration | View or edit per-domain settings |
| 6 | Set Domain URL | Change the site URL |
| 7 | Lock / Unlock Domain | Make files read-only or writable |
| 8 | Fix Domain Permissions | Repair ownership and modes |
| 9 | Domain Isolation | Per-site isolation tools (see "Isolation" below) |

Add Domain notes for **Node.js**: ShieldPress allocates a free port in 3000-3999,
creates the Linux user, Nginx proxy and PM2 home, but does **not** create a
placeholder `app.js` or start PM2. Upload your application and run
Node.js Manager > Deploy / Build; PM2 starts the app from its own `npm start`
script (or the configured entry file).

Isolation menu: 1) Fix All Permissions, 2) Apply open_basedir, 3) Audit Isolation
Status, 4) Repair All.

### 6) SSL Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Install Free SSL (Let's Encrypt) | Issue a free certificate |
| 2 | Install Free SSL (ZeroSSL) | Issue a ZeroSSL certificate |
| 3 | Install Custom SSL (Paid) | Install your own certificate and key |
| 4 | Install Cloudflare Origin SSL | Install a Cloudflare origin certificate |
| 5 | Renew SSL | Renew a certificate now |
| 6 | Remove SSL | Remove a certificate |
| 7 | Check SSL Status | Show validity and expiry |
| 8 | Auto SSL (Wildcard) | Set up wildcard automation |

### 7) WordPress Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Install WordPress | Install a fresh site on a domain |
| 2 | Update Core / Plugins / Themes | Update with safety checks |
| 3 | Security Hardening | Apply hardening settings |
| 4 | Performance Optimize | Apply performance settings |
| 5 | Security + Optimize | Run both |
| 6 | Staging Tools | Create or manage staging copies |
| 7 | WP-Cron to System Cron | Replace page-triggered cron with system cron |
| 8 | Malware Scan | Scan the site |
| 9 | Reset Admin Password | Reset a WordPress admin password |
| 10 | Auto-Recovery (500 Fix) | Scan sites and manage the auto-recovery daemon (scan, install, status, stop, remove, logs) |
| 11 | Change DB Password / Salt Keys | Rotate database password and salts |

### 8) Laravel Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Install Laravel Runtime | Install PHP/Composer prerequisites |
| 2 | Add / Install Laravel Domain | Create a domain and optionally install fresh Laravel |
| 3 | List Laravel Domains | Show Laravel sites |
| 4 | Backup Manager | PostgreSQL backups: backup now, import SQL, auto backup, list |
| 5 | Redis Cache Manager | Install Valkey, configure per domain, status, flush, restart |
| 6 | Supervisor Manager | Install/check Supervisor and manage queue workers |
| 7 | Install Components | Install optional components |
| 8 | npm run build | Build front-end assets |
| 9 | Deploy / Build Prod | Production deployment steps |
| 10 | Edit Laravel .env | Edit environment settings |
| 11-15 | storage:link, optimize:clear, optimize cache, Queue restart, Scheduler run | Common Artisan tasks |
| 16 | View Laravel Log | Read the application log |
| 17 | Runtime / Status | Show runtime and service status |
| 18 | Fix Permissions | Repair ownership and modes |
| 19 | Advanced Artisan | migrate, rollback, seed, key:generate, about, route:list, or a custom command |

### 9) Node.js Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Check / Update Runtime | Manage the shared Node.js runtime (see below) |
| 2 | Add Node.js Domain | Create a Node.js site (no placeholder app, PM2 not started yet) |
| 3 | List Node.js Domains | Show domains, ports and PM2 state |
| 4 | Running Apps (PM2) | Show all PM2 apps |
| 5 | Backup Node.js App | Back up the selected app |
| 6 | Deploy / Build | Install dependencies, build, then reload or start the app |
| 7 | Start / Ensure App (PM2) | Start the app, or restart it if it already exists |
| 8 | Stop App (PM2) | Take the app offline |
| 9 | Restart App (PM2) | Restart with the current environment and port |
| 10 | View App Logs | Read PM2 logs |
| 11 | Runtime / Status | Show Node.js, npm and PM2 status |
| 12 | Fix Permissions | Repair ownership and modes |
| 13 | Advanced Tools | Change App Port, Change Entry File, Health Check / 502, Migrate systemd to PM2 |
| 14 | Migrate root PM2 to user | Move legacy root-owned PM2 apps to the domain user |

**Typical flow for a new app:** 2) Add Node.js Domain, upload your files, 6) Deploy / Build,
then use the SSL Manager (main menu 6) if you need HTTPS. Start mode 1 (`npm start`) is recommended.

**1) Check / Update Runtime** shows the installed version and the repository
candidate, then offers:

| # | Option | What happens |
|---|--------|--------------|
| 1 | Update Node.js | Updates to the newest version **within the installed major** (for example 24.x stays on 24.x). If Node.js is not installed it installs the latest Node.js 26 LTS. |
| 2 | Upgrade major version (24 / 26 LTS) | Moves to a newer major branch. Shows the installed and target versions and requires typing `YES`. Downgrades are blocked. |
| 3 | Check for updates again | Re-queries the repository |
| 0 | Back | Return |

Notes:

- All Node.js apps share one runtime. After any runtime change, deploy each app so
  native dependencies are rebuilt, then restart it. ShieldPress does not restart
  PM2 or your apps automatically.
- Cancelling, or a failed repository query, leaves the runtime and repository
  settings unchanged. Package locks are restored after every transaction.
- If a project's `engines.node` is not satisfied, Deploy / Build stops before
  changing anything.

### 10) Database Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1 | MariaDB Manager | Create/list/delete databases and users, change passwords, import/export SQL, optimize tables, open Adminer, set the DB for a website, network/port settings, test connection, version updates |
| 2 | PostgreSQL Manager | Install PostgreSQL, create/list/inspect/delete databases and users, import SQL, backups and schedules, streaming replication, version updates |
| 3 | Optimize MariaDB | Tune MariaDB for available RAM |
| 4 | DB Configuration | Edit database configuration |
| 5 | Export MariaDB | Export a database |

## 5. System

### 11) Backup & Restore

| # | Option | Use it to |
|---|--------|-----------|
| 1 | Backup Database | Back up a database |
| 2 | Backup Files | Back up site files |
| 3 | Backup Full (DB+Files) | Back up both |
| 4 | Auto Backup Setup | Schedule jobs: all databases, one database, website + database + files, files only; view or remove schedules |
| 5 | Backup Status | Show recent backups |
| 6 | Remote Storage | Configure remote destinations |
| 7 | Upload to Remote | Upload a backup |
| 8 | Telegram Backup | Send backups to Telegram |
| 9 | Restore Website | Restore a site from a backup |
| 10 | Delete Backups | Remove old backups |
| 11 | Encryption | Enable/disable, generate/show/import keys, encrypt and decrypt backups |
| 12 | PostgreSQL WAL Policy | Manage WAL retention |

Keep a copy of the encryption key somewhere safe: encrypted backups cannot be
restored without it.

### 12) Cache Manager

Valkey Server Manager, Optimize Valkey/Redis, WP Object Cache, Cache Hit Ratio,
Purge Domain Cache, Warmup Domain Cache, Clear All Cache, Smart Cache Status,
Auto Purge (mu-plugin) and Remove Valkey (options 1-10). Use *Purge Domain Cache*
after changing a site; *Clear All Cache* affects every site.

### 13) Security & Firewall

| # | Options | Use them to |
|---|---------|-------------|
| 1-8 | Firewall Status, Open/Close Port, Block IP, Whitelist IP, Remove IP Rule, List Blocked IPs, IP Block History | Manage firewall rules |
| 9-12 | Enable Fail2ban SSH, SSH Manager, Nginx Protection, Nginx Manager | Ban abusive clients |
| 13 | WP Bruteforce Protection | Protect WordPress login |
| 14 / 15 | Block / Unblock Bot Countries | Country-level blocking |
| 16 | SSH Hardening | Apply SSH security settings (keep a second session open when changing SSH) |
| 17 / 18 | Auto-block Attackers, Auto-Guard (Scheduled) | Automatic protection |
| 19 | Security Audit | Run an audit |
| 20 | CVE / Dependency Audit | Check dependencies for known vulnerabilities |
| 21 | YARA Malware Scan | Scan with YARA rules |
| 22 | Intrusion Guard | Monitor for intrusion signs |

### 14) Monitoring & Logs

Bandwidth per Domain, Attack Spike Detection, Server Resources, Log Analyzer,
Top IP Access, Live Log Tail, Log Viewer, Service Status, Domain Health Check,
MySQL Slow Query Log, PHP Slow Log Analyzer, Enable Log Rotation and Cleanup Old
Logs (options 1-13).

### 15) Upgrade Manager

| # | Option | Use it to |
|---|--------|-----------|
| 1-5 | Upgrade Nginx, PHP, MariaDB, PostgreSQL, Node.js | Controlled upgrades of each component |
| 6 | Package Lock Manager | Review or repair package version locks |
| 7 | View Upgrade Policy | Read the upgrade rules |
| 8 | View Upgrade Log | Review past upgrades |

### 16) Self-Healing & Repair

1) System Integrity Check, 2) Auto-Repair Daemon, 3) Config Snapshots,
4) Emergency Restore.

### 17) Optimization

1) Fix Domain Permissions, 2) Optimize Valkey/Redis, 3) Full Auto Optimize.

### 18) RAM Manager

1) Show RAM Status, 2) Clear RAM Cache, 3) Install / Configure ZRAM, 4) Add Swap
File, 5) Remove Swap File, 6) Tune Swappiness, 7) RAM Auto Optimizer.

### 19) Disk Manager

1) Disk Usage Overview, 2) Top Files (Single Domain), 3) Top Files (All Domains),
4) Backup Storage Size.

### 20) SFTP Manager

1) Create SFTP Account, 2) View Account Info, 3) List All Accounts,
4) Enable / Disable, 5) Reset Password, 6) Delete SFTP Account.

## 6. Settings

### 21) Tools & Utilities

1) Edit Database Config, 2) View Logs, 3) Meilisearch Setup (install, search and
sync keys), 4) Auto-Reload MariaDB, 5) Service Status, 6) Version Info,
7) Repair Services, 8) Restart Full Stack, 9) Server Migration.

### 22) Telegram Notifications

1) Configure Telegram Bot, 2) Toggle Events, 3) Alert Thresholds,
4) Schedule Monitor, 5) Send Test. Use *Send Test* after configuring the bot.

### 23) ShieldPress Monitor

1) Connect / Setup, 2) Change Interval, 3) Start Service, 4) Stop Service,
5) Monitor Status, 6) Send Now, 7) View File Changes, 8) View Login Activity,
9) View Logs, 10) Remove Service.

### 24) Email Server

1) Install Email Server, 2) Add Email Account, 3) Delete Email Account,
4) List Email Accounts, 5) Change Password, 6) SMTP Relay (Brevo/SES),
7) Test Send & Receive, 8) Email Server Status, 9) DNS Records Guide,
10) Client Setup Guide, 12) Install SSL (mail), 13) Uninstall Email Server.
Publish the DNS records from option 9 before relying on delivery.

### 26) Migration Patches

1) Show Patch Status, 2) Apply All Pending Patches. Patches normally apply
automatically during an update; use this menu to see or retry pending ones.

### 27) Update ShieldPress VPS

Checks for a new release, verifies its signature and checksum, and installs it.
Releases that are not signed are refused. The Auto-Update menu (`shieldpress autoupdate`)
controls on/off, frequency, time of day, delay after a release, an immediate
check-and-update, and the update log.

### 28) GitHub

Connect an application directory to a GitHub repository with a read-only deploy
key, then pull updates later. ShieldPress never resets, cleans, builds,
migrates or restarts applications for you; run Deploy / Build afterwards.

## Getting help

- `shieldpress help` lists CLI shortcuts.
- See [GUIDE.md](GUIDE.md) for procedures and the troubleshooting checklist.
- See [SECURITY.md](SECURITY.md) to report a vulnerability.
