#!/bin/bash
set -euo pipefail
work=/root/php-security-build-8.4.27
mkdir -p "$work"
exec > >(tee -a "$work/build.log") 2>&1
cd "$work"
curl -fSL --connect-timeout 10 --max-time 90 'https://www.php.net/releases/index.php?json&version=8.4.27' -o release.json
python3 - <<'PY'
import json
from pathlib import Path
r=json.loads(Path('release.json').read_text())
a=next(x for x in r['source'] if x['filename']=='php-8.4.27.tar.xz')
assert len(a['sha256'])==64
Path('source.sha256').write_text(a['sha256']+'  php-8.4.27.tar.xz\n')
PY
curl -fSL --connect-timeout 10 --max-time 180 https://www.php.net/distributions/php-8.4.27.tar.xz -o php-8.4.27.tar.xz
sha256sum -c source.sha256
# Exclude unrelated PostgreSQL repositories only for this build transaction.
dnf --disablerepo='pgdg*' --setopt=timeout=15 --setopt=retries=1 install -y gcc gcc-c++ make autoconf bison re2c pkgconf-pkg-config libxml2-devel openssl-devel sqlite-devel libcurl-devel oniguruma-devel libzip-devel libpng-devel libjpeg-turbo-devel freetype-devel libicu-devel libxslt-devel libsodium-devel readline-devel libpq-devel bzip2-devel zlib-devel systemd-devel
tar -xf php-8.4.27.tar.xz
cd php-8.4.27
./configure --prefix=/opt/shieldpress-php/8.4.27 --with-config-file-path=/opt/shieldpress-php/8.4.27/etc --with-config-file-scan-dir=/opt/shieldpress-php/8.4.27/etc/php.d --enable-fpm --with-fpm-systemd --with-fpm-user=nginx --with-fpm-group=nginx --enable-bcmath --with-bz2 --enable-calendar --with-curl --enable-exif --enable-ftp --enable-gd --with-freetype --with-jpeg --with-gettext --enable-intl --enable-mbstring --with-mysqli=mysqlnd --with-openssl --enable-pcntl --with-pdo-mysql=mysqlnd --with-pdo-pgsql --with-pgsql --with-readline --enable-soap --enable-sockets --with-sodium --with-xsl --with-zip --with-zlib
make -j2
make install
/opt/shieldpress-php/8.4.27/bin/php -n -v
printf '\nBUILD_COMPLETED\n'
