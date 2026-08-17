# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest `main` / current release | Yes |
| Older releases | Best effort |

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Email: **support@shieldpress.net**

Include:

- Affected version (`shieldpress/version.txt` or release tag)
- AlmaLinux version and relevant stack components (Nginx, PHP, MariaDB, etc.)
- Steps to reproduce
- Impact assessment
- Patch or workaround if you have one

We aim to acknowledge reports within a few business days.

## Scope

In scope:

- Privilege escalation through ShieldPress scripts or installed services
- Remote code execution via ShieldPress-managed configs
- Exposure of credentials, tokens, or private keys by ShieldPress defaults
- Unsafe installer or update paths that can be abused remotely

Out of scope:

- Issues that require an already-compromised root shell with no ShieldPress involvement
- Misconfiguration after operators intentionally weaken hardening
- Denial of service against third-party services ShieldPress calls

## Safe disclosure expectations

- Do not access customer data beyond what is needed to demonstrate the issue.
- Do not perform destructive testing on production systems you do not own.
- Give us a reasonable window to fix and release before public disclosure.

## Hardening notes for operators

- Keep AlmaLinux, Nginx, PHP, and databases updated.
- Restrict SSH and avoid exposing database ports publicly.
- Store secrets under `/etc/shieldpress` and never commit them to git.
- Review Telegram, Cloudflare, ZeroSSL, and backup credentials regularly.
