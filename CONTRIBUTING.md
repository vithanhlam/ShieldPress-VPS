# Contributing to ShieldPress VPS

Thank you for helping improve ShieldPress VPS. Pull requests are welcome.

## Before you start

1. Open an [issue](https://github.com/vithanhlam/ShieldPress-VPS/issues) for larger changes so we can align on scope.
2. Fork the repository and create a branch from `main`.
3. Keep changes focused. Prefer one feature or fix per pull request.

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

## Pull request checklist

- [ ] `bash tests/smoke.sh` passes
- [ ] Related menus or scripts were tested on AlmaLinux 9 or 10 when possible
- [ ] Docs / changelog updated if needed
- [ ] No secrets or machine-specific files included
- [ ] Commit author is your GitHub identity (no unrelated co-author trailers)

## Commit messages

Use short, descriptive messages:

- `fix: renew mail SSL without full email reinstall`
- `feat: add Node.js health check to dashboard`
- `docs: clarify AlmaLinux-only requirement`

## Code of conduct

Be respectful in issues and pull requests. Harassment or abusive behavior is not accepted.

## License

By contributing, you agree that your contributions are licensed under the GNU General Public License v3.0.
