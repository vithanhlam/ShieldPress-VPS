# Server Migration

Open **Tools & Utilities → 9) Server Migration**. The menu displays the hostname and server ID of the VPS where you are working. Select `ALL`, one website number, or several numbers such as `1,3,4`.

## Choose the correct server role

- **A / SOURCE** holds the original websites. For a normal production move, this is the old/main VPS.
- **B / DESTINATION** receives the new website copies.
- **CLIENT / this VPS** is where you open the menu and control the operation.
- **SSH SERVER / remote VPS** accepts the client's SSH connection and its scoped migration key.

| Where you open the menu | Menu option | Website data | SSH connection |
| --- | --- | --- | --- |
| On original VPS A | **1) Send to VPS B (this VPS = A)** | A (this VPS) → B (remote) | Client A → SSH Server B |
| On new VPS B | **2) Pull from A (this VPS = B)** | A (remote) → B (this VPS) | Client B → SSH Server A |

In both cases website data moves **A → B**. The pairing screen identifies which remote SSH server receives the public key: B for Send, A for Pull. Before website selection and again before the final confirmation, the wizard displays the actual A/B hostnames, server IDs, the current client's role and both arrows. Offline export is performed on A; offline import is performed on B.

DNS controls which VPS serves live traffic. Change DNS after validating B; opening this menu or pairing SSH does not promote a server or change DNS.

The operation copies websites. It preserves the source application files, databases, accounts, cron jobs, SSH server configuration and DNS records. It never deletes remote export packages. It refuses to overwrite destination websites, Linux accounts/groups, databases, database accounts, PHP pools or conflicting Nginx dependencies.

## Before copying

Both VPSs must run a ShieldPress release containing Server Migration protocol 2. The destination needs a working ShieldPress stack: Nginx, the selected PHP versions (Remi PHP 8.2–8.5), the same Node.js major version for Node applications, the required database service, matching PHP extensions, and Composer/package managers used by the applications. Preflight reports missing prerequisites before importing. Install missing runtimes through their ShieldPress managers and retry.

SSH must be reachable on the remote VPS using its root account. Start a guided copy, enter the remote hostname/IP and SSH port, then pair the server once. The wizard generates an Ed25519 key automatically and installs only its public key through an existing administrator SSH login. Enter the remote root password in OpenSSH if requested; ShieldPress never stores it. If password login is disabled and no administrator SSH key is available, choose the remote-console method: run the displayed public-key authorization command in the provider console, then return to finish pairing. The console command also displays the server's SSH host fingerprints for comparison.

Each endpoint and copy direction has a separate private key under `/var/shieldpress/data/server-migration/connections/`, with private directories and mode 600 key files. Private keys stay on the initiating VPS. A root-only saved profile pins both the SSH host key and the ShieldPress machine identity. For subsequent copies, select the saved server number instead of re-entering its address, port or credentials. OpenSSH never falls back to an unrelated administrator identity if the migration key is missing.

The remote public key has an OpenSSH forced command with `restrict`: it cannot open a shell, PTY, SCP/SFTP session, SSH agent forwarding, X11 forwarding or a TCP tunnel. A **source** grant can list/export/download websites; a **destination** grant can receive/inspect/import/verify copies. Packages travel through the restricted SSH channel, with the existing SHA-256 verification, rather than a general SCP login. The destination permission includes administrator-level website configuration imports and should be granted only between trusted VPSs.

Permission expires after **7 days**, enforced by the remote gateway. Expired grants cannot perform migration operations; they can revoke themselves. Renew access through **Server connections** using an administrator login or console command. Re-pairing a lost local key replaces its previous managed grant after the pinned server identity is verified. Pairing is idempotent and preserves unrelated SSH keys.

Use **Server connections → Revoke a saved connection** after completing the migration. Revocation removes exactly that managed authorization and its local private/public key. If the peer is unreachable, the wizard provides a remote-console revocation command and offers to forget only the local key; it does not claim remote access was revoked. Revocation affects new requests, not an already running copy. Earlier administrator/shared SSH keys are not reused or removed automatically.

Compare the SSH host fingerprint against the provider console on first pairing. A changed host key or machine identity is blocked; it is never silently accepted. The wizard does not enable remote password login, alter the SSH daemon configuration or open firewall ports. If SSH is unavailable, use the provider console to configure the SSH service and firewall first. Generic offline SCP transfers require a separate administrator login; the restricted migration key intentionally cannot run SCP/SFTP.

The source must use a managed local database recorded in `domain.env`. External/dynamic database connections, databases shared by multiple selected sites, unsupported file links, port conflicts and conflicting shared server configuration require review. An existing destination site is always blocked, including an earlier completed copy; a migration is not an incremental synchronization operation.

For the final copy, pause application writes and background jobs on the source yourself before exporting, then keep writes paused through DNS cutover. Database dumps are transactional where supported, but files and database changes across a running application cannot be captured in one atomic snapshot. A preliminary copy is useful for checking compatibility; do not direct production traffic to a stale copy.

## Copy and inspect

1. Select a saved connection, or enter the remote hostname/IP and SSH port for first-time pairing. The wizard verifies key authentication, migration support and the machine identity; copying to the same VPS is blocked.
2. Select websites and review the source/destination names. Confirm creation of packages. Full application files, dotfiles, uploads, database dumps, the domain's Nginx configuration and its file dependencies, PHP-FPM pool, referenced TLS certificates, and HTTP password-protection files/metadata are packaged. TLS snippets and helper files are scoped to the copied website so existing destination TLS policies are preserved. Internal absolute application links are converted to portable relative links. Links outside the application directory are blocked.
3. Source scratch space is checked before exporting. Each transferred package must match its SHA-256 checksum. The wizard completes one website at a time: export, transfer, destination preflight, then import and verification. Each site is checked against the current destination resources and disk space before it is imported; later websites have not been exported yet.
4. For each website, review the source, destination, domain and database, then answer the highlighted Y/N confirmation. Enter or N skips that import. Answering Y creates new resources on destination B.
5. The destination creates isolated accounts and domain directories, imports each database into new resources, reconnects conventional application settings, prepares dependencies/builds, installs the PHP pool or per-user PM2 service, and installs the copied Nginx configuration. The tool does not explicitly run application schema migrations. Existing package installation/build/start hooks still run as the domain account.
6. Nginx validation/reload, runtime service status, database login, filesystem permissions and HTTP/HTTPS are checked. A unique loopback-only probe verifies that the copied virtual host has actually loaded; a default website returning HTTP 200 during an asynchronous reload cannot count as success. The tool waits up to 90 seconds for readiness. HTTP probes resolve the domain directly to the destination loopback address and never follow redirects back to the source. HTTPS probes validate the copied certificate; no insecure TLS bypass is used.

Success is reported as `COPIED_PENDING_CUTOVER`, not as a completed production cutover. A homepage response proves basic runtime readiness, not every business workflow. A configured HTTP password challenge is accepted as an access-control response; protected pages still need a check with credentials. Cloudflare Origin CA checks use the explicitly configured provider CA while retaining hostname and certificate verification. Origins requiring mutual TLS need a reviewed authenticated probe before cutover. Check login, uploads, checkout, application integrations, cache, mail and any custom endpoints against the destination before routing traffic there.

Certbot-style `ipv6only=on` options on standalone wildcard IPv6 listen directives are omitted from the new imported main configuration because this is already Nginx's default and repeating the option for a shared socket prevents reload. Existing destination configurations and source files are preserved. Non-default IPv6 dual-stack policies require review before import.

## DNS, certificates and background jobs

The wizard leaves DNS changes to the operator. Configure fresh SFTP credentials through SFTP Manager if needed; source SFTP passwords are not duplicated. After validating the destination copy, update DNS and check public HTTP/HTTPS after propagation. Keep the source available until the destination is confirmed healthy and new writes are routed consistently.

TLS certificates are copied to a private directory under `/etc/nginx/ssl/migration-<folder>/`, with Nginx references updated. The original Certbot account and renewal ownership are not duplicated. After DNS points to the destination, configure certificate issuance/renewal through **SSL Manager**, then inspect the renewal configuration. If a certificate has already expired or is untrusted, HTTPS verification fails and the copy is not reported ready.

Domain-related cron entries and custom Supervisor/systemd definitions are preserved in the private migration report. They remain disabled on the destination to prevent duplicate queues, scheduled commands, billing or backups while the source is active. Review the saved definitions, configure the corresponding managers and enable the required jobs after cutover. Global database replication, email accounts, server-wide firewall rules and unrelated VPS services are outside website migration; inspect any application dependencies on those services separately.

## Failure and recovery

After a failed website the wizard asks whether to continue with the next one. Enter or N stops the run. Previously verified copies remain available; remaining websites are listed as not started. A private batch report is saved after every result, including failures and skipped imports. DNS cutover guidance is shown only when at least one copy passes verification. Failed website/database copies and their packages are retained for recovery, and newly installed Nginx files are removed if they still match the files written by the attempt. Existing destination configuration is not replaced. A bad PHP pool is removed before restoring the shared PHP service. Do not change DNS for a failed copy.

Use **Verify a destination copy / view reports** to rerun checks after repairs. Keep the generated local probe in the copied Nginx configuration and its private `config/migration.json` receipt so later checks can identify the virtual host reliably. The private report identifies completed steps, pending cutover work and retained resources. A failed copy reserves its domain and database identities; inspect or repair it before using the normal managers to remove that destination copy and retry. There is no automatic deletion of failed databases or websites.

Packages and reports live under `/var/shieldpress/data/server-migration/`, outside the updated source tree. They contain secrets and are restricted to root. Retain them while needed for recovery, then remove the specific artifacts deliberately. No package is automatically deleted from the source.

During updates an idempotent migration preserves legacy packages from `/opt/shieldpress/migrate` and `/opt/shieldpress_old/migrate` in `packages/legacy`. Preservation failures remain pending for retry. Legacy-format packages are recovery artifacts; re-export websites using the current tool for validated imports.

Failed imports also remove unchanged log links and empty configuration directories created by that attempt. Updates and retry preparation repair old empty SSL directories and dangling log links only when a trusted failed-import report identifies this destination, the domain and application account are absent, and active Nginx configuration does not reference the site. These old artifacts are moved into private `orphan-recovery-*` directories with an audit record. Nonempty certificate directories, unrelated links, existing websites, databases and application files are preserved. A retained failed website still needs operator review; this repair does not authorize overwriting it.

## Validation

Run `python3 tests/migration-ssh.py` and `python3 tests/server-migration.py` for isolated regressions and `bash tests/smoke.sh` for repository checks.

For integration checks, build `docker build -f tests/server-migration-integration/Dockerfile -t shieldpress-migration-test:local .`, then run `bash tests/server-migration-integration/run.sh`. This creates two disposable containers with real restricted SSH package transfers, Nginx, MariaDB, PostgreSQL, PHP-FPM and PM2. The tests cover automatic pairing, direction restrictions, shell/tunnel denial, expiry, key rotation, revocation that preserves administrator access, and the four application layouts, database-backed homepage responses, TLS with an explicit provider CA, HTTP password protection, preservation of existing destination SSL policies, uploads, dotfiles and internal links. The containers use a service-control adapter because they do not boot systemd; verify native systemd and SELinux behavior on the target VPS as part of staging. Framework fixtures do not replace acceptance tests of the user's actual WordPress/Laravel application.
