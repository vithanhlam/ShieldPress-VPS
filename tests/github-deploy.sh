#!/bin/bash
# Exercise real Git histories without contacting GitHub or requiring root.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/shieldpress/modules/github/github-lib.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
[[ $(gh_remote https://github.com/owner/repo.git) == git@github.com:owner/repo.git ]]
[[ $(gh_remote git@github.com:owner/repo) == git@github.com:owner/repo.git ]]
for url in 'https://token@github.com/a/b' 'https://github.com/a/b?x=1' 'git@evil.test:a/b' 'https://github.com/a/..'; do
    if gh_remote "$url"; then echo 'Unsafe URL accepted'; exit 1; fi
done
git init -q -b main "$test_root/source"
printf 'initial\n' > "$test_root/source/app.php"
printf 'runtime/\n' > "$test_root/source/.gitignore"
git -C "$test_root/source" add .
git -C "$test_root/source" commit -qm initial
git clone -q "$test_root/source" "$test_root/web"
web="$test_root/web" remote=git@github.com:owner/repo.git DOMAIN=example.com base="$test_root" hash=test
git -C "$web" remote set-url origin "$remote"
# Substitute only transport and interactive UI; all deployment checks are real.
gh_git() {
    if [[ $1 == fetch ]]; then
        shift
        git -C "$web" -c core.hooksPath=/dev/null fetch --no-tags "$test_root/source" main
    else
        git -C "$web" -c core.hooksPath=/dev/null "$@"
    fi
}
gh_confirm() { :; }
run_with_loading() { shift 3; "$@"; }
printf 'updated\n' > "$test_root/source/app.php"
git -C "$test_root/source" commit -qam update
( gh_pull )
[[ $(cat "$web/app.php") == updated ]]
( gh_pull ) # repeat execution is harmless
previous=$(git -C "$web" rev-parse HEAD)
printf 'local\n' >> "$web/app.php"
if ( gh_pull ); then echo 'Dirty worktree accepted'; exit 1; fi
git -C "$web" restore app.php
mkdir "$test_root/source/runtime" "$web/runtime"
printf 'remote\n' > "$test_root/source/runtime/data"
git -C "$test_root/source" add -f runtime/data
git -C "$test_root/source" commit -qm collision
printf 'secret\n' > "$web/runtime/data"
if ( gh_pull ); then echo 'Ignored collision accepted'; exit 1; fi
[[ $(cat "$web/runtime/data") == secret && $(git -C "$web" rev-parse HEAD) == "$previous" ]]
git -C "$test_root/source" rm -q app.php
git -C "$test_root/source" commit -qm deletion
if ( gh_pull ); then echo 'Deletion accepted'; exit 1; fi
[[ -f $web/app.php && $(git -C "$web" rev-parse HEAD) == "$previous" ]]
git -C "$web" remote set-url origin git@github.com:other/repository.git
if ( gh_pull ); then echo 'Wrong repository accepted'; exit 1; fi
git -C "$web" remote set-url origin "$remote"
git -C "$test_root/source" restore --source="$previous" --staged --worktree .
git -C "$test_root/source" commit -qm restore
git -C "$test_root/source" rm -q app.php
ln -s /etc/passwd "$test_root/source/app.php"
git -C "$test_root/source" add app.php
git -C "$test_root/source" commit -qm type-change
if ( gh_pull ); then echo 'File type change accepted'; exit 1; fi
[[ ! -L $web/app.php ]]
printf 'local commit\n' > "$web/local.php"
git -C "$web" add local.php
git -C "$web" commit -qm local
if ( gh_pull ); then echo 'Diverged history accepted'; exit 1; fi
# Persisted settings support direct pull and disable ordinary push.
ssh_cmd='ssh -F /dev/null'
gh_persist
[[ $(git -C "$web" config pull.ff) == only ]]
[[ $(git -C "$web" remote get-url --push origin) == /dev/null ]]
if git -C "$web" push; then echo 'Push unexpectedly succeeded'; exit 1; fi
echo '[PASS] GitHub deployment regression checks'
