#!/bin/bash
# Disposable AlmaLinux 9 only. Run with the repository mounted at /repo.
set -euo pipefail
if [ ! -f /.dockerenv ] || [ ! -f /etc/almalinux-release ] || [ ! -d /repo/shieldpress ]; then
    echo 'Requires a disposable AlmaLinux container and a /repo mount.' >&2
    exit 1
fi
dnf install -y rpm-build createrepo_c python3-dnf-plugin-versionlock >/tmp/service-tools.log 2>&1
mkdir -p /fixtures /root/rpmbuild/SPECS /opt/shieldpress /var/shieldpress/data
cp -a /repo/shieldpress/. /opt/shieldpress/
cat > /root/rpmbuild/SPECS/fixture.spec <<'SPEC'
Name: %{fixture_name}
Version: %{fixture_version}
Release: %{fixture_release}.fixture
Summary: Isolated ShieldPress service update test fixture
License: MIT
BuildArch: noarch
%description
Not a real service binary. Used only to test RPM transaction behavior.
%install
mkdir -p %{buildroot}/usr/share/shieldpress-service-fixtures
printf '%{version}-%{release}\n' > %{buildroot}/usr/share/shieldpress-service-fixtures/%{name}
%files
/usr/share/shieldpress-service-fixtures/%{name}
SPEC
for entry in shieldpress-test-library:1.0:1 shieldpress-test-library:1.0:2 nginx:1.26.2:1 nginx:1.26.2:2 nginx:1.28.1:1 php84-php-fpm:8.4.1:1 php84-php-fpm:8.4.1:2 php84-php-fpm:8.5.1:1 mariadb-server:10.11.1:1 mariadb-server:10.11.1:2 mariadb-server:11.4.1:1 postgresql-server:15.1:1 postgresql-server:15.1:2 postgresql-server:16.1:1; do
    IFS=: read -r name version release <<< "$entry"
    rpmbuild -bb --define "fixture_name $name" --define "fixture_version $version" --define "fixture_release $release" /root/rpmbuild/SPECS/fixture.spec >/tmp/service-rpmbuild.log 2>&1
done
cp /root/rpmbuild/RPMS/noarch/*.rpm /fixtures/
createrepo_c /fixtures >/dev/null
# Fictional advisory tests metadata handling and RPM release backports.
cat > /tmp/updateinfo.xml <<'XML'
<updates><update from="fixture" status="stable" type="security" version="1"><id>FIXTURE-2099:0001</id><title>Fictional nginx security backport</title><issued date="2099-01-01 00:00:00"/><updated date="2099-01-01 00:00:00"/><severity>Important</severity><references><reference href="https://example.invalid/CVE-2099-0001" id="CVE-2099-0001" type="cve" title="Fictional test CVE"/></references><description>Test fixture only.</description><pkglist><collection short="fixture"><name>fixture</name><package name="nginx" epoch="0" version="1.26.2" release="2.fixture" arch="noarch"><filename>nginx-1.26.2-2.fixture.noarch.rpm</filename></package></collection></pkglist></update></updates>
XML
modifyrepo_c --mdtype=updateinfo /tmp/updateinfo.xml /fixtures/repodata
cat > /etc/yum.repos.d/shieldpress-fixture.repo <<'REPO'
[shieldpress-fixture]
name=ShieldPress test fixtures
baseurl=file:///fixtures
enabled=1
gpgcheck=0
REPO
for repo in /etc/yum.repos.d/almalinux*.repo; do sed -i 's/^enabled=1/enabled=0/' "$repo"; done
dnf install -y shieldpress-test-library-1.0-1.fixture nginx-1.26.2-1.fixture php84-php-fpm-8.4.1-1.fixture mariadb-server-10.11.1-1.fixture postgresql-server-15.1-1.fixture >/tmp/service-install.log 2>&1
dnf versionlock add nginx php84-php-fpm mariadb-server postgresql-server shieldpress-test-library
printf '!nginx-0:1.26.99-*.noarch\n' >> /etc/dnf/plugins/versionlock.list
/usr/bin/python3 /repo/tests/service-updates.py --dnf
