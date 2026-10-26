#!/bin/bash
# Run only in a disposable AlmaLinux 9 container with the repository at /repo.
# Example: docker run --rm -v "$PWD:/repo:ro" almalinux:9 bash /repo/tests/node-same-branch-dnf.sh
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
for version in 26.5.0 26.12.1 27.1.0; do
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
dnf install -y nodejs-26.5.0-1.fixture >/tmp/install.log 2>&1
bash /opt/shieldpress/modules/upgrade/package-lock.sh lock nodejs
source /opt/shieldpress/modules/helpers/nodejs-runtime.sh
nodejs_runtime_manager <<< $'3\ny'
[[ "$(node -p process.versions.node)" == 26.12.1 ]]
rpm -q nodejs-libs | grep -q 26.12.1
dnf versionlock list | tee /tmp/locks
grep -q 'nodejs-0:26.12.1' /tmp/locks
grep -q 'nodejs-libs-0:26.12.1' /tmp/locks
# A generic update must remain locked despite the newer 27.x repository package.
dnf upgrade -y nodejs >/tmp/locked-update.log 2>&1
[[ "$(node -p process.versions.node)" == 26.12.1 ]]
update_shieldpress_nodejs_current_branch <<< y
[[ "$(node -p process.versions.node)" == 26.12.1 ]]
if install_shieldpress_nodejs; then exit 1; fi
echo '[PASS] Real AlmaLinux DNF: pinned same-major transaction, matching dependency, locks, repeat and downgrade guard'
