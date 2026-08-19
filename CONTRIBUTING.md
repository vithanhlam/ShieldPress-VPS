# Contributing to ShieldPress VPS

Thank you for helping improve ShieldPress VPS. Bug reports, security
reviews, research, and code contributions are welcome.

ShieldPress is source-available software. You may clone this repository,
study the code, build it, and modify it for personal or internal use.
Public redistribution of forks or competing products is not permitted.
See [LICENSE](LICENSE).

## Before you start

1. Open an [issue](https://github.com/vithanhlam/ShieldPress-VPS/issues) with a clear bug report or feature proposal when practical.
2. Fork or copy the Official Repository only as needed to prepare a Pull Request.
3. Keep your changes focused. Do not rebrand ShieldPress or publish a public modified distribution.

By opening a Pull Request, you grant the copyright holder the contribution
license described in [LICENSE](LICENSE). You retain copyright in the
original portions of your contribution unless otherwise agreed in writing.

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

## Pull Request checklist

- [ ] `bash tests/smoke.sh` passes
- [ ] Related menus or scripts were tested on AlmaLinux 9 or 10 when possible
- [ ] Docs / changelog updated if needed
- [ ] No secrets or machine-specific files included
- [ ] No AI co-author / contributor trailers (see below)
- [ ] You have the right to submit the contribution under [LICENSE](LICENSE)

## Commit authorship (required)

The copyright holder and official maintainer of this repository is
**[vithanhlam](https://github.com/vithanhlam)**. See [LICENSE](LICENSE)
and [TRADEMARK.md](TRADEMARK.md).

- Do **not** add `Co-authored-by` (or similar) for Claude, ChatGPT, Cursor Agent, Copilot, or any other AI tool.
- AI assistants may help edit code; they must **not** appear as authors or contributors on this repository.
- Do not submit third-party code or code whose copyright you cannot legally license.

Pull requests that attribute work to AI accounts will be rejected.

## Commit messages

Use short, descriptive messages:

- `fix: renew mail SSL without full email reinstall`
- `feat: add Node.js health check to dashboard`
- `docs: clarify AlmaLinux-only requirement`

## Code of conduct

Be respectful in issues and pull requests. Harassment or abusive behavior is not accepted.

## License, ownership & trademark

ShieldPress VPS is licensed under the **ShieldPress Source-Available
Software License**:
**Copyright © 2026 vithanhlam. All Rights Reserved.**

Publication of this source code does not make ShieldPress Open Source
software and does not transfer ownership. You may use, study, clone, build,
and modify the Software for personal or internal use, and you may
contribute changes back through Pull Requests. You may not redistribute,
publicly fork as a product, rebrand, sell, or offer ShieldPress as a
competing or hosted commercial service without a separate written license.

You must also respect [TRADEMARK.md](TRADEMARK.md).
