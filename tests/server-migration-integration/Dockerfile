FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends python3 nginx mariadb-server mariadb-client postgresql postgresql-client openssh-server openssh-client curl ca-certificates openssl iproute2 nodejs npm php-fpm php-mysql php-pgsql php-cli php-mbstring php-xml php-curl php-zip composer cron procps && npm install -g pm2 && rm -rf /var/lib/apt/lists/*
RUN useradd -r nginx && mkdir -p /run/sshd /home/domains /var/shieldpress/logs /var/shieldpress/data /etc/nginx/ssl /etc/opt/remi/php85/php-fpm.d /var/opt/remi/php85/run/php-fpm /opt/remi/php85/root/usr/sbin /opt/remi/php85/root/usr/bin && ln -s /usr/bin/php /opt/remi/php85/root/usr/bin/php && sed -i 's/user www-data;/user nginx;/' /etc/nginx/nginx.conf && rm -f /etc/nginx/sites-enabled/default && printf 'root:migration-test-only\n' | chpasswd && printf '\nPermitRootLogin yes\nPasswordAuthentication yes\n' >> /etc/ssh/sshd_config
COPY tests/server-migration-integration/systemctl /usr/local/bin/systemctl
COPY tests/server-migration-integration/php-fpm /opt/remi/php85/root/usr/sbin/php-fpm
COPY tests/server-migration-integration/boot.sh /boot.sh
RUN chmod 755 /usr/local/bin/systemctl /opt/remi/php85/root/usr/sbin/php-fpm /boot.sh
COPY shieldpress /opt/shieldpress
CMD ["/boot.sh"]
