#!/bin/bash
# Run only in a disposable AlmaLinux 9 container with the repository at /repo.
# Example: docker run --rm -v "$PWD:/repo:ro" almalinux:9 bash /repo/tests/node-major-upgrade-dnf.sh
set -euo pipefail
if [ ! -f /.dockerenv ] || [ ! -f /etc/almalinux-release ] || [ ! -d /repo/shieldpress ]; then
    echo 'This test requires a disposable AlmaLinux container and /repo mount.' >&2
    exit 1
fi
dnf install -y rpm-build createrepo_c python3-dnf-plugin-versionlock >/tmp/tools.log 2>&1
mkdir -p /opt/shieldpress /fixtures /root/rpmbuild/SPECS /var/shieldpress/logs /var/shieldpress/data
cp -a /repo/shieldpress/. /opt/shieldpress/
cat > /root/rpmbuild/SPECS/nodejs.spec <<'SPEC'
Name: nodejs
Version: %{fixture_version}
Release: 1.fixture
Summary: ShieldPress isolated runtime transaction fixture
License: MIT
BuildArch: noarch
Requires: nodejs-libs = %{version}-%{release}
%description
Isolated package fixture; not an actual Node.js runtime.
%package libs
Summary: Matching runtime dependency fixture
%description libs
Dependency fixture.
%install
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/nodejs-fixture
printf '#!/bin/sh\necho "%{version}"\n' > %{buildroot}/usr/bin/node
printf '#!/bin/sh\necho "11.0.0"\n' > %{buildroot}/usr/bin/npm
chmod 755 %{buildroot}/usr/bin/node %{buildroot}/usr/bin/npm
printf '%{version}\n' > %{buildroot}/usr/share/nodejs-fixture/version
%files
/usr/bin/node
/usr/bin/npm
%files libs
/usr/share/nodejs-fixture/version
SPEC
for version in 22.23.4 24.22.2 26.13.0 27.1.0; do
    rpmbuild -bb --define "fixture_version $version" /root/rpmbuild/SPECS/nodejs.spec > /tmp/rpmbuild.log 2>&1
done
cp /root/rpmbuild/RPMS/noarch/*.rpm /fixtures/
createrepo_c /fixtures >/dev/null
cat > /etc/yum.repos.d/shieldpress-fixture.repo <<'REPO'
[shieldpress-fixture]
name=ShieldPress test fixtures
baseurl=file:///fixtures
enabled=1
gpgcheck=0
REPO
# Keep every transaction isolated to the test repository.
for repo in /etc/yum.repos.d/almalinux*.repo; do sed -i 's/^enabled=1/enabled=0/' "$repo"; done
dnf install -y nodejs-22.23.4-1.fixture >/tmp/install.log 2>&1
bash /opt/shieldpress/modules/upgrade/package-lock.sh lock nodejs
source /opt/shieldpress/modules/helpers/nodejs-runtime.sh
# Keep production transport hard-coded and signed; substitute only the isolated
# unsigned fixture transport for this disposable container.
shieldpress_nodejs_target_options(){
    NODE_TARGET_OPTIONS=(--repofrompath=shieldpress-nodejs-target,file:///fixtures
        --enablerepo=shieldpress-nodejs-target --setopt=shieldpress-nodejs-target.gpgcheck=0)
}
eval "$(declare -f shieldpress_nodejs_save_major_repo | sed '1s/shieldpress_nodejs_save_major_repo/fixture_save_repo/')"
shieldpress_nodejs_save_major_repo(){ fixture_save_repo "$1" "$2" /fixtures/saved-nodesource.repo; }
printf 'original config\n' > /fixtures/saved-nodesource.repo
upgrade_shieldpress_nodejs_major 24 <<< YES
[[ "$(node -p process.versions.node)" == 24.22.2 ]]
rpm -q nodejs-libs | grep -q 24.22.2
grep -q 'pub_24.x' /fixtures/saved-nodesource.repo
grep -q 'original config' /fixtures/saved-nodesource.repo.shieldpress-backup.*
nodejs_runtime_manager <<< $'4\n2\nYES'
[[ "$(node -p process.versions.node)" == 26.13.0 ]]
rpm -q nodejs-libs | grep -q 26.13.0
grep -q 'pub_26.x' /fixtures/saved-nodesource.repo
grep -q '^gpgcheck=1$' /fixtures/saved-nodesource.repo
dnf versionlock list | tee /tmp/locks
grep -q 'nodejs-0:26.13.0' /tmp/locks
grep -q 'nodejs-libs-0:26.13.0' /tmp/locks
# A generic update must remain locked despite the newer 27.x repository package.
dnf upgrade -y nodejs >/tmp/locked-update.log 2>&1
[[ "$(node -p process.versions.node)" == 26.13.0 ]]
if upgrade_shieldpress_nodejs_major 24 <<< YES; then exit 1; fi
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
if install_shieldpress_nodejs; then exit 1; fi
echo '[PASS] Real AlmaLinux DNF: 22 -> 24 -> 26, matching dependencies, repository backup, locks and downgrade guards'
