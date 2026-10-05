# WordPress recovery VPS verification — 2026-10-05

Environment: TEST.MD test VPS, AlmaLinux, SELinux Enforcing. Installed base
was 1.3.39; tested the current recovery module against the existing UI and
real systemd service. Two WordPress sites were scanned.

Results:

- Reproduced 1.3.78: opening the script while the recovery lock was held
  exited with status 0 and displayed no menu.
- Installed the corrected daemon using recovery menu option 2: active/running,
  journald output, no 209/STDOUT failure.
- Entered WordPress menu 10 while the daemon scanned: recovery menu displayed.
- Requested a manual scan with the lock busy: reported contention and kept
  the menu available; status and log options remained accessible.
- Selected status, stop, then install again: stopped and restarted successfully.
- A real daemon scan completed: checked=2, errors=0, recovered=0.
- Service reported ActiveState=active, SubState=running, NRestarts=0.

Remote evidence: /tmp/recovery-install-test.log, /tmp/recovery-menu-test.log,
/tmp/recovery-contention-test.log, /tmp/recovery-lifecycle-test.log,
/tmp/recovery-old-repro.log, and /var/shieldpress/logs/wp-auto-recovery.log.

This verifies menu/locking/service behavior. It does not simulate a failing
WordPress site or prove every automatic repair branch.
