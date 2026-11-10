# WordPress cache purge and recovery verification — 2026-11-10

Environment: disposable local VPS from TEST.MD, AlmaLinux 9, Nginx and PHP 8.4
FPM, domain `ramfixtest.local`. Production was not accessed.

Reproduced configuration: PHP `exec` is disabled, `open_basedir` is enabled,
and `/etc/cron.d/shieldpress-cache-purge` was missing. The old plugin reported
`ok` as soon as it wrote a signal, without waiting for cache deletion. Its
post hook also tried to unlink Nginx cache outside PHP's permitted paths.

Changes:

- PHP only writes a domain signal and reports `queued`; it has no exec/sudo
  path. The repair removes ShieldPress's legacy broad sudoers entry.
- Post changes (including unpublishing/trashing) use the privileged consumer.
- Domain identity comes from the managed directory rather than URL aliases.
- Failed deletions return failure and leave valid signals available for retry.
- Updates refresh installed MU plugins and restore/enable the cron worker.
  Repeating the migration does not duplicate registry entries.

Validation:

- `tests/wp-purge-regression.py`: PHP with disabled exec and open_basedir;
  manual/post/trash signals, repeated queued result, missing tmp failure,
  failed consumer retry and successful signal removal.
- `tests/security-boundaries.py`: 26 tests passed, including bounded signal
  parsing, rejection of cross-domain payloads and symlinks, and protected
  managed control directories.
- `tests/wp-cache-recovery.sh` on the VPS: stale cached WordPress error body
  removed, healthy cache retained, HTTP 500 from stale application cache
  recovered, HTTP 502 reproduced by stopping FPM, FPM restarted and cache
  removed. Previous recovery migration passed twice; disabled auto-reload
  stayed disabled.
- `tests/wp-purge-migration.sh` on the VPS: legacy installed plugin refreshed,
  worker present, crond active, legacy sudoers entry absent, repeated repair
  passed.
- `tests/wp-purge-vps.sh`: invokes the plugin through a PHP-FPM test harness
  with WordPress functions stubbed, exercises the real cron consumer and
  verifies Nginx HIT becomes MISS after manual and post invalidation.
- Repository smoke tests, shell syntax checks, PHP lint and diff whitespace
  checks passed.

Scope: the PHP harness tests the purge implementation, not an authenticated
WordPress dashboard browser session. Recovery cannot repair arbitrary broken
plugin code or database failures; the HTTP 500 test covers an application-cache
failure. Signal processing normally takes up to one minute. These checks cover
the cache/root privilege boundary, not a complete malware audit of the server.
