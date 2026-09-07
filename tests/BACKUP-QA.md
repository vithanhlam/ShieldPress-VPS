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
