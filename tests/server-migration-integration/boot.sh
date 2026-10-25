#!/bin/bash
set -e
# Isolated integration fixture: real services with a small service-control adapter.
printf '%s\n' '[global]' 'pid = /run/shieldpress-test-fpm.pid' 'error_log = /var/log/php-fpm-test.log' 'include = /etc/opt/remi/php85/php-fpm.d/*.conf' > /etc/shieldpress-test-fpm.conf
cat /proc/sys/kernel/random/uuid > /etc/machine-id
mkdir -p /run/mysqld /run/postgresql
chown mysql:mysql /run/mysqld
chown postgres:postgres /run/postgresql
service mariadb start
pg_ctlcluster "$(ls /etc/postgresql | head -1)" main start
/usr/sbin/sshd
nginx
touch /ready
exec sleep infinity
