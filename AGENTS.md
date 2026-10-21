# Repository conventions

## Release requirements

Every GitHub release push must increment `shieldpress/version.txt`, update the
current version in `README.md`, add a dated entry to `CHANGELOG.md`, and publish
the release archive with SHA-256 and MD5 checksum files. Use the existing release
workflow so checksums match the exact uploaded archive.

Run the relevant tests before every push. At minimum, run the repository smoke
test, shell syntax checks, and `git diff --check`. For behavior changes, add or
run targeted regression and integration checks before publishing.

## Update and migration behavior

When fixing a bug that affects an existing installation, add an automatic,
idempotent migration or repair path so upgraded installations receive the fix.
Wire it into the update/migration flow, report success or pending failures, and
test the old-version-to-new-version handoff as well as repeat execution.

## Language

Use English exclusively for source code, user-facing menus, prompts, status
messages, errors, documentation, changelogs, comments, and tests. Do not add
Vietnamese or other non-English text, even when the request is written in
another language. Translate any touched legacy text to English.

## Supported application stacks

ShieldPress manages Laravel, WordPress, Node.js, and PHP applications. Give
these stacks priority in regression testing. For changes that can affect a
stack, test its relevant install, update/deploy, runtime, and rollback behavior
where applicable; include cross-stack checks when shared services or server
configuration are changed.
