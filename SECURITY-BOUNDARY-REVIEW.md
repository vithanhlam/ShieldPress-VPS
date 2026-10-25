# Application-to-root boundary review

Date: 2026-10-25. Scope: local ShieldPress VPS source, installation/update,
domain ownership, scheduled backups, restore, cache purge and bundled YARA rules.
The desktop/MCP AI Access server implementation is not present in this repository;
its resource authorization and remote shell scope were not audited here.
This review identifies exploitable code paths; it does not establish which path
was used in a historical intrusion. No live VPS deployment is part of this change.

## Findings and changes

| Severity | Finding | Remediation |
| --- | --- | --- |
| Critical | Domain creation and some repair paths assigned the domain parent to the application user. That user could rename a root-owned `config` directory and replace scripts invoked by root cron. | Keep the domain parent root-owned, protect `config` and `backup` recursively, and use descriptor-relative operations that refuse symlinks, hardlinks and special files in control trees. Apply the same boundary to creation, isolation, Node deployment and emergency repair. |
| Critical | Root modules evaluated `domain.env` with `source`. Replaced configuration could execute commands when an administrator opened a menu. | Parse a fixed set of literal settings without shell evaluation. Validate application identities, document roots, database identifiers and stack values; reject UID-zero aliases. Stop callers when configuration validation fails. |
| Critical | The release archive preserved build-machine ownership, and the updater preserved that ownership with `rsync -a`. A matching application UID on the VPS could own root-executed code. | Package numeric UID/GID zero with group/other write bits removed, extract without preserving archive owners, and normalize staged source ownership and write permissions before loading or activating it. Include the first upgrade from older updaters in the migration. |
| High | Generated domain cron scripts embedded settings in executable shell and lived below domain paths. | Replace duplicated generated implementations with a packaged `bin/domain-backup` runner and private wrappers in `/etc/shieldpress/jobs`. Read settings at runtime as data. |
| High | Backup exclusions reached `eval`, custom targets accepted parent traversal and external symlinks, and newline-delimited file/retention lists confused filenames with arguments. | Use argument arrays, validate target containment, pass `--` to tar, use null-delimited verbatim file lists and null-delimited retention. Keep root-written backup output below root-owned directories. |
| High | A nested website restore archive could contain both `public_html` and control files, then extract into the domain parent as root. | Validate all members before destructive restore steps; restrict WordPress/PHP archives to `public_html`; reject traversal, external links, writes through links, devices and privileged executable modes. Preserve rollback on failure. |
| Medium | The PHP handler preceded sensitive-file denial, and executable uploads were not denied by the shared vhost template. | Place source and upload/cache PHP denials before the PHP handler. Migrate existing vhosts, validate with `nginx -t`, and restore previous configurations on validation/reload failure. |
| Medium | Cache signals could request another site's cache and `cat` followed unbounded application-controlled links. | Read at most 129 bytes from a regular non-symlink file using a directory descriptor. Bind the request to its originating domain and restrict sudo callers to their configured domain user. |
| Detection gap | Starter YARA rules required direct decoder-to-eval or request-to-exec expressions. Indirect, session-based and appended-payload loaders escaped those patterns. | Add review-only rules for the observed structural patterns and test them with the real YARA engine and benign data-handling examples. Findings still require human review. |

## Upgrade behavior

`SP_20261025_DOMAIN_PRIVILEGE_BOUNDARY` runs before older domain migrations:

1. Secure installed ShieldPress source and domain control ancestors.
2. Protect `config` and the managed backup tree. Backups are intentionally private
   to root; application users and their SFTP sessions must not modify root input
   or output files.
3. Rebuild recognized per-domain database/files/full schedules from literal
   schedule, mode and retention data. Existing script bodies are never sourced
   or copied into executable wrappers.
4. Save the previous crontab in
   `/etc/shieldpress/crontab-before-domain-boundary.txt`.
5. Disable unrecognized legacy domain backup entries and report unresolved
   work in `/etc/shieldpress/domain-boundary-pending.txt`. The migration remains
   pending until the schedule is reconfigured. Symlink/hardlink control trees
   also remain pending for operator inspection.
6. Add web source guards to existing PHP vhosts, validate, and reload Nginx.

Repeated migration runs preserve already rebuilt schedules. Failure stops older
migrations from processing untrusted domain control data. New schedules use the
packaged runner; schedule listing and domain deletion support its wrapper paths.

Restore archives with absolute framework links are rejected. Recreate those links
through the application's normal deployment tools after restoring a safe archive.
Successful fixture restores preserve the existing nested files/database format.
Full website packages always contain complete application source (excluding normal
dependencies/build caches); a legacy incremental full-job request is normalized
to full source so a destructive restore cannot silently discard unchanged files.
Files-only incremental schedules remain supported.

## Local validation

- `python3 tests/security-boundaries.py`: control-tree checks, literal parsing,
  path containment, old-version schedule migration and repeat execution,
  pending failures, four-stack backup shapes, backup failure cleanup, safe
  retention, restore package validation, cache signal limits, release ownership,
  updater staging permissions, Nginx syntax, actual loopback HTTP denial/allow behavior and configuration rollback.
- `python3 tests/yara-scan.py`: real YARA compilation and matching, indirect
  payload fixtures, benign fixtures, bounded scanning and report-only behavior.
- Existing backup, restore, WordPress update/reset, Node permission/runtime,
  domain cleanup and repository smoke checks.

All payload samples are text fixtures and are never executed. Database/network
dependencies in the new backup runner test are mocked. Nginx syntax validation
is local. Passing these checks is not a declaration that an already compromised
server or its preserved global configuration/scripts are malware-free.
