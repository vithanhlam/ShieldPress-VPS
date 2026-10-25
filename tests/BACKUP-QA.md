# Backup regression verification — 2026-09-07

Tested on the AlmaLinux 9.8 VPS identified in the workspace TEST.MD.
The runtime initially reported version 1.3.31. Fixes were copied directly;
a published release upgrade was not performed.

## Observations before changes

- The config directory was nested through multiple `config/config` levels.
- `/opt/shieldpress/bin/laravel-pg-backup` was absent.
- Root crontab contained only the WAL status poll, not a 23:00 database job.
- No remote backup config or rclone installation was present. No remote config
  was found in the updater archives inspected on this test machine.
- Therefore the reported production 20 KB backup failure could not be identified
  directly from this machine. Compressed file size alone does not prove failure.

## Verified

- Created an isolated PostgreSQL database with 100,000 rows and a primary key.
- Manual runner produced a 4,034,582-byte gzip backup with mode 600.
- Actual crond execution with an empty environment and minimal PATH produced
  a 4,034,594-byte gzip backup with mode 600. The temporary job ran at 07:19;
  this was not a wait-until-23:00 test.
- Restored the cron backup into a separate database using ON_ERROR_STOP.
  Both source and restore returned 100,000 rows and the ordered-data checksum
  `393e58c1faa8c52ba1d586f8aac20f64`.
- A real pg_dump failure for a nonexistent database returned failure, logged
  diagnostics, and left no completed backup or partial file.
- Holding the database backup lock blocked a concurrent invocation without
  deleting existing backups.
- Retention of one kept exactly one completed backup after a successful dump.
- PostgreSQL Manager functions created the correct daily 23:00 cron command
  with per-job retention, ran a manual backup without rewriting the runner,
  and disabled the schedule successfully.
- Python regression suite passed locally and on AlmaLinux: partial dump failure,
  gzip integrity, retention, nested config recovery, preserving active settings,
  three successive staging updates, legacy retention migration, and the migration
  used after an upgrade launched by the old updater.
- Repository smoke tests and bash syntax checks passed.

## Cleanup and limits

Temporary databases and test schedules were removed; the original root crontab
was restored and compared. PostgreSQL and crond remained active. The patched
runtime remains installed on the test VPS. Evidence and original runtime files
are in `/tmp/sp-backup-qa` on that VPS.

Live S3/Drive/OneDrive upload was not tested because this VPS has no configured
remote. Update configuration preservation was tested in isolated staging trees;
a complete download/switch/rollback release upgrade was not performed.

## Restore database reconnection — 2026-10-25

- WordPress restores verify the managed local database login before proceeding,
  then replace literal DB settings from the archive with the verified VPS
  settings. Configuration changes are atomic, PHP syntax checked, and preserve
  ownership and mode. The original config is retained under the private domain
  config directory with mode 0600.
- Existing installations receive a retryable migration for previously restored
  WordPress sites recorded in backup.log. Working database connections, external
  hosts, and other application stacks are skipped. Dynamic DB definitions require
  manual review. The updater's existing migration hook runs this patch, including
  the first upgrade launched by the old updater.
- Restore operations now use a per-domain lock, require successful rollback
  snapshots, detect corrupt SQL before replacing files, and restore old files
  after DB import/configuration failures. Failed imports also attempt DB rollback;
  the recovery snapshot remains available even if database recovery fails.
- Successful restores ask `Delete this restore's rollback snapshot? [y/N]:`.
  Empty input and EOF retain the snapshot; failed restores never offer deletion.
- Validation: smoke/shell syntax, diff whitespace checks, backup regression,
  progress, upload confirmation, and isolated restore regression all passed.
  Restore fixtures cover WordPress, PHP, Laravel, and Node.js, migration failure
  retry and repeat execution, special characters in passwords, dynamic config
  rejection, snapshot/import/config/archive failures, and retention/deletion.
- Applied the four source files directly through the authorized VPS MCP connection
  as a hotfix to 1.3.104. Remote hashes match local files. The pre-change scripts
  are retained in `/var/shieldpress/data/restore-script-fix-20261025-085203`.
  No release was pushed and no full restore was run against production.
- Repaired only the restored DB configuration for laodongtienluong.vn. Managed
  database authentication and PHP syntax passed; local-origin and public HTTPS
  changed from HTTP 500 to HTTP 200. Repeat repair skipped the working site.
  The original `rollback_2026-10-25_08-45-45` snapshot was retained.

### Production full-restore verification

- Ran the installed restore menu through a PTY for laodongtienluong.vn using
  `full_2026-10-25_08-38-50.tar.gz`; all five prompts were answered and the
  process exited successfully. Full restore duration: 38 seconds.
- Both files and the MySQL payload were restored. WordPress DB synchronization
  completed automatically, PHP syntax passed, and a repeat repair skipped the
  now-working DB connection. Origin and public HTTPS both returned HTTP 200.
- The success-only rollback deletion prompt was observed and answered No.
  `rollback_2026-10-25_08-54-26` contains both file and database snapshots.
- Release 1.3.105 includes the tested hotfix and upgrade migration.
