# Root PM2 migration — 2026-09-07

## Usage

Node.js Manager → **14) Migrate root PM2 to user** → select the domain → confirm
its brief restart. The migration is explicit; updating does not move live apps.

The runner preserves the original script, arguments, environment and supported
restart settings. It changes ownership of application files to the domain user,
verifies process UID and ownership of the HTTP listening socket, checks a stable
HTTP response, saves PM2 state, and starts/verifies the user systemd service.
Only then does it remove the selected app from root PM2 and save the root list.

On failure it removes the target app, restores recorded file ownership/modes,
and restarts the original root app with an HTTP recovery check. Root-only
recovery files and command logs are stored in
`/var/shieldpress/data/pm2-migrations/<user>-<unique-id>/`.

The generated systemd service uses a foreground drop-in to avoid reliance on a
PIDFile inside the user's home on SELinux systems. Other domain PM2 daemons are
not stopped by this migration.

## Preconditions / limits

- Existing non-root domain account with the correct home directory.
- One online, single-instance fork app with the domain's PM2 name and working
  directory. Cluster mode and watch mode are rejected before stopping it.
- Target user has no PM2 apps, so its daemon can be moved under systemd safely.
- HTTP on the configured unprivileged port; the current response must be below
  500. The same status must remain stable under the target user.
- Internal app symlinks are supported; external symlinks and hardlinked files
  require manual permission review and are rejected before stopping the app.
- PM2 and the configured Node/npm/interpreter must be usable by the domain user.
- SIGINT/SIGTERM trigger rollback. Power loss/SIGKILL cannot execute rollback;
  recovery files remain available. Recovery failure is reported, not hidden.

## Verification

Local unit tests: `python3 -B tests/pm2-migration.py` (5 passed).
Repository shell smoke tests and `git diff --check` passed.

Live AlmaLinux 9.8 VPS from TEST.MD, Node 26.8.1 / PM2 7.0.4:

- Direct Node app and npm-start app migrated from UID 0 to their respective
  isolated user accounts, preserving a test environment value and script args.
- Both services restarted successfully, with the apps returning HTTP under the
  target UID afterward; this is a service restart test, not a full VPS reboot.
- An app intentionally exiting when UID is nonzero triggered rollback; root
  PM2 resumed it, and HTTP returned UID 0 again. Repeated on the final runner.
- PM2 ID renumbering during root daemon restart was observed; recovery uses the
  validated app name, not a stale numerical ID.
- Migration invoked from `/root` passed after subprocess cwd was fixed to /tmp.
- Repeating migration after success reported no root app and changed nothing.
- Concurrent migration was rejected by the global lock.
- Permission checks accepted an internal node_modules/.bin symlink.

Reference: PM2 [ecosystem files](https://pm2.keymetrics.io/docs/usage/application-declaration/)
and [startup configuration](https://pm2.keymetrics.io/docs/usage/startup/).
