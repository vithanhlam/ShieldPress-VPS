# YARA report-only scanner verification

Date: 2026-10-25.

- Tested against the real YARA/yarac 4.5.5 binaries extracted from Ubuntu packages into `/tmp`; no system package installation or VPS change was performed.
- Nine isolated regression tests cover the bundled rules, normal files, the harmless EICAR marker, WordPress/PHP/Laravel/Node.js domain selection, unchanged target content, symlinks, FIFOs, size skips, changed files, invalid rules, engine timeout, missing engine, overlapping scans, invalid configuration, report retention and permissions, repeated timer configuration, schedule disable, and opt-in notification dispatch with a mocked notifier.
- Generated systemd service and timer passed `systemd-analyze verify`. Timer/systemd operations are mocked in regression tests. Actual scheduled execution, OS repository installation, resource usage on large production trees and Telegram delivery still need deployment verification.
- Reports distinguish findings from incomplete scans. No website files are deleted, quarantined, executed, or uploaded.
- Starter detection rules target selected PHP webshell patterns and the EICAR marker. They are not a complete malware signature feed, and a successful scan does not establish that a site is free of malware.
- Configuration is stored under `/etc/shieldpress`; reports are under `/var/shieldpress/logs`; timer units are under `/etc/systemd/system`. Source-directory upgrades preserve these paths. This new optional feature has no legacy job/config migration and does not enable itself during updates.

## Test VM integration follow-up

Target: `192.168.122.12`, the VM specified in `../TEST.MD`; AlmaLinux 9.8, 2 vCPUs, approximately 3.6 GiB usable RAM. Tested on 2026-10-25. The connected customer VPS was not used for deployment or scanning.

- Saved the original Security module to `/root/shieldpress-yara-test/security-before.tar.gz` before deploying the new menu/scanner/rules.
- Installed only `yara-4.5.2-1.el9` and `time-1.9-18.el9`; before/after RPM inventories confirmed that no existing runtime package was upgraded.
- All nine regression tests passed against the real AlmaLinux YARA engine. The deployed menu's install/check and domain-selection scan paths also passed.
- Scanned an isolated four-stack fixture containing 401 files and one harmless EICAR marker. Exactly the EICAR marker matched; scan exit was 1, elapsed time was 1.79 seconds, and maximum process resident memory reported by `/usr/bin/time -v` was 16,512 KiB.
- Scanned all 15 registered domain trees: 27,626 files scanned, 24 skipped, zero engine errors, zero rule matches. The skipped examples recorded 14 symlink/non-regular files and 10 files exceeding the configured size limit. These exclusions and the limited starter rules mean this is not proof that every file is free of malware.
- Full registered-domain scan elapsed time was 126.90 seconds (internal report: 126.87 seconds). User CPU time was 29.88 seconds; system CPU time was 50.36 seconds; `/usr/bin/time` reported 63% CPU (relative to one CPU) and maximum process RSS of 17,932 KiB. This RSS measurement is not a cgroup-wide memory peak; the VM did not expose a usable systemd `MemoryPeak` value.
- Generated and verified the actual systemd units, enabled the daily timer twice, and used a temporary two-second timer override to verify timer-triggered execution on the isolated fixture. The scan service succeeded with exit 1 for the EICAR finding. Runtime properties confirmed `CPUQuotaPerSecUSec=250ms` and `MemoryMax=402653184` bytes.
- Injected invalid YARA rule text on the test VM: the service failed with exit 2 and saved an `INCOMPLETE` report. Restored the original rules, verified their SHA-256 against source, and reran the service successfully. No website files were changed by this failure/recovery drill.
- Configured the weekly timer and verified its next run, then disabled the timer. Removed both temporary timer and service test overrides. Final timer state: `disabled` / `inactive`; Telegram summaries are disabled in the test configuration.
- Verified notification dispatch using a local capture notifier on the VM. No Telegram message or file content was transmitted externally. Live Telegram delivery remains untested.
- Nginx, PHP-FPM, MariaDB and PostgreSQL remained active; the local HTTP baseline stayed at 200. `systemd-analyze verify` also reported pre-existing `StartLimitIntervalSec` placement warnings in unrelated database/PHP resilience drop-ins; the YARA units passed.
- Test artifacts and logs remain in `/root/shieldpress-yara-test/`. The full registered-domain report is `/var/shieldpress/logs/yara/scan-20261025T013101.729671Z.json`. Test installation and deployed source remain on this VM; automatic scanning is off. No GitHub release was created for this feature during this test.
