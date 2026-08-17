# Contributing to ShieldPress VPS

Thank you for helping improve ShieldPress VPS. Bug reports and feature
suggestions are welcome. This is a proprietary project maintained and
authored solely by **vithanhlam**; unsolicited code contributions are not
accepted.

## Before you start

1. Open an [issue](https://github.com/vithanhlam/ShieldPress-VPS/issues) with a clear bug report or feature proposal.
2. Do not fork, modify, or submit source code unless vithanhlam has given you prior written permission.
3. If code collaboration is approved, follow the written licensing and authorship terms provided for that work.

## Development layout

```
ShieldPress-VPS/
├── install.sh          # Repo-root installer (copies into /opt/shieldpress)
├── shieldpress/        # Runtime source installed to /opt/shieldpress
│   ├── shieldpress.sh
│   ├── install.sh
│   ├── core/
│   ├── modules/
│   └── ...
└── tests/              # Smoke and structure checks
```

Runtime paths stay `/opt/shieldpress` on the server. Domain data stays under `/home/domains`.

## Local checks

```bash
# Structure + syntax smoke tests
bash tests/smoke.sh

# Manual install from a clone (AlmaLinux 9/10, root)
sudo bash install.sh
shieldpress help
```

## Coding guidelines

- Prefer Bash with clear, readable scripts. Avoid obfuscation.
- Reuse helpers from `shieldpress/core/` and module helpers when possible.
- Do not commit secrets, credentials, private keys, dumps, backups, or live config.
- Keep logs and runtime data outside the source tree (`/var/shieldpress`, `/etc/shieldpress`).
- Update `README.md` and `CHANGELOG.md` when user-facing behavior changes.
- Keep `shieldpress/version.txt` in sync with release notes when cutting a release.

## Approved collaboration checklist

- [ ] `bash tests/smoke.sh` passes
- [ ] Related menus or scripts were tested on AlmaLinux 9 or 10 when possible
- [ ] Docs / changelog updated if needed
- [ ] No secrets or machine-specific files included
- [ ] Written permission from vithanhlam was obtained before editing
- [ ] No AI co-author / contributor trailers (see below)

## Commit authorship (required)

The official repository’s sole project author is **[vithanhlam](https://github.com/vithanhlam)**. See [LICENSE](LICENSE) and [TRADEMARK.md](TRADEMARK.md).

- Do **not** add `Co-authored-by` (or similar) for Claude, ChatGPT, Cursor Agent, Copilot, or any other AI tool.
- AI assistants may help edit code; they must **not** appear as authors or contributors on this repository.
- Do not submit third-party code or code whose copyright you cannot legally license or assign.

Unauthorized pull requests and commits that attribute work to AI accounts
will be rejected.

## Commit messages

Use short, descriptive messages:

- `fix: renew mail SSL without full email reinstall`
- `feat: add Node.js health check to dashboard`
- `docs: clarify AlmaLinux-only requirement`

## Code of conduct

Be respectful in issues and pull requests. Harassment or abusive behavior is not accepted.

## License, ownership & trademark

ShieldPress VPS is proprietary software:
**Copyright © 2026 vithanhlam. All Rights Reserved.**

Viewing this repository does not grant permission to modify, fork,
redistribute, or publish its source code. Any approved code collaboration
requires a separate written agreement with vithanhlam. You must also respect
[TRADEMARK.md](TRADEMARK.md).
