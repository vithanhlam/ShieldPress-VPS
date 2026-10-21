# PHP security patch VPS verification

Test date: 2026-10-21. Target: the AlmaLinux 9.8 VM documented in TEST.MD.

- Source backup: `/root/php-security-test-backup/source-before.tar.gz` on the VM.
- Installed runtime: Remi PHP 8.4.25; PHP-FPM and Nginx active.
- Deployed the security patch, CVE audit, upgrade scripts, and updater directly for testing. This was not a complete release download / atomic switch test.
- Updater syntax and normalization/loading of the preserved legacy upgrade policy passed.
- Audit identified PHP 8.4.25 as below the upstream fixed baseline.
- Two apply attempts stalled while refreshing unrelated PostgreSQL repository metadata. They were deliberately interrupted before any PHP package transaction. Both returned patch exit code 1, reported the security patch as unverified/pending, and restarted the previously active PHP-FPM successfully. Nginx remained active.
- Added per-request DNF timeout and retry limits after the first attempt. These do not impose an overall metadata refresh deadline; slow repositories can still delay completion.
- Local repository smoke checks passed after the change.

The VM remains unverified for CVE-2026-109618 and CVE-2026-109619. Successful package installation and the complete updater flow still require verification before release.

A subsequent read-only refresh of only `remi-safe` completed: latest available `php84-php-fpm` was `8.4.26-1.el9.remi`, below upstream 8.4.27. No DNF process remained; both PHP-FPM and Nginx were active. No verified fixed package was available from that repository at test time.

## Official source build follow-up

- Downloaded PHP 8.4.27 from php.net, checked its SHA-256 against the official releases JSON API, and compiled into `/opt/shieldpress-php/8.4.27` on the test VM.
- Installed build prerequisites using a transaction excluding slow unrelated `pgdg*` repositories. This also upgraded dependent OS libraries; the transaction is recorded in the VM's DNF history.
- Kept Remi packages/binaries and original FPM pool/socket configuration intact. Copied PHP settings into the build prefix, omitting dynamic extension load directives for statically compiled modules and loading the new OPcache binary.
- All explicitly checked existing runtime extensions were present. PHP-FPM configuration validation passed. Upstream `Zend/tests/new_oom.phpt` and `Zend/tests/oom_after_main_script.phpt` both passed.
- First HTTP verification read a cached 8.4.25 response and triggered automatic rollback. The second used distinct query strings and `Cache-Control: no-store`; HTTP returned PHP 8.4.27, `fpm-fcgi`, working SQLite, OpenSSL and OPcache.
- PHP-FPM now runs the source-built 8.4.27 binary through `/etc/systemd/system/php84-php-fpm.service.d/shieldpress-source-security.conf`. Verified `/proc/<MainPID>/exe` points to the new binary. Nginx config validation and service health checks passed.
- The temporary HTTP probe was removed. The default CLI and vendor package binaries were not replaced and remain 8.4.25. The package-only auto patch is not a source-build installer and still audits those vendor binaries; this test does not validate that auto patch can install 8.4.27 from Remi.
- Build and verification logs/results remain under `/root/php-security-build-8.4.27` and scripts under `/root/php-security-test-backup` on the VM. Full application regression and reboot testing were not performed.

## Full PHP 8.4 entrypoint migration

- Added `modules/security/build-php84-security.sh` and `php84-source-patch.sh`. The updater's existing security hook now invokes the migration for an existing build and falls back to building PHP 8.4.27 when the package update cannot meet the security baseline.
- Tested source migration twice on the VM. Both executions returned success. The migration takes per-run entrypoint snapshots and retains the first recovery archive under `/var/shieldpress/data/php-source-84`.
- `/usr/bin/php`, `/opt/remi/php84/root/usr/bin/php`, `php-cgi`, `phpdbg`, `php-config` and the FPM entrypoint now execute the 8.4.27 source build; `phpize --version` reports the matching PHP 8.4 API. The previous CLI limitation above has been resolved.
- Audit returned exit code 0. Uncached HTTP returned `version=8.4.27`, `sapi=fpm-fcgi`, PDO and OPcache enabled. WordPress and Laravel test roots returned HTTP 200; Nginx and FPM were active; SELinux remained Enforcing. The probe was removed.
- Local smoke checks passed. This is a managed source overlay: RPM database versions still describe the preserved vendor packages. Re-running the update migration reapplies managed entrypoints after package transactions. Only the PHP 8.4 source fallback has been implemented; other branches retain package-based patching. Future return to vendor packages must account for the source FPM override.
