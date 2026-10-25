#!/bin/bash
# Disposable integration environment. No ports or host files are exposed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="spm-test-$$"
SOURCE="${PREFIX}-source"
DESTINATION="${PREFIX}-destination"
NETWORK="${PREFIX}-network"
TEMP=$(mktemp -d)
cleanup(){
    if [ "$?" -ne 0 ]; then
        docker exec "$DESTINATION" cat /var/shieldpress/data/server-migration/commands.log 2>/dev/null || true
        docker exec "$DESTINATION" python3 -c 'from pathlib import Path; import json; [(print(p.name), print(json.loads(p.read_text()).get("error")), print(json.loads(p.read_text()).get("verification"))) for p in Path("/var/shieldpress/data/server-migration/reports").glob("*.json")]' 2>/dev/null || true
    fi
    docker rm -f "$SOURCE" "$DESTINATION" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$TEMP"
}
trap cleanup EXIT
docker network create --internal "$NETWORK" >/dev/null
docker run -d --name "$SOURCE" --hostname migration-source --network "$NETWORK" --network-alias migration-source shieldpress-migration-test:local >/dev/null
docker run -d --name "$DESTINATION" --hostname migration-destination --network "$NETWORK" --network-alias migration-destination shieldpress-migration-test:local >/dev/null
for container in "$SOURCE" "$DESTINATION"; do
    for attempt in $(seq 1 30); do
        if docker exec "$container" test -f /ready; then break; fi
        sleep 1
    done
    docker exec "$container" test -f /ready
    docker cp "$ROOT/shieldpress/modules/tools/server-migration.py" "$container:/opt/shieldpress/modules/tools/server-migration.py"
    docker exec "$container" chown root:root /opt/shieldpress/modules/tools/server-migration.py
    docker exec "$container" chmod go-w /opt/shieldpress/modules/tools/server-migration.py
    docker cp "$ROOT/shieldpress/modules/tools/migration-ssh.py" "$container:/opt/shieldpress/modules/tools/migration-ssh.py"
    docker exec "$container" chown root:root /opt/shieldpress/modules/tools/migration-ssh.py
    docker exec "$container" chmod go-w /opt/shieldpress/modules/tools/migration-ssh.py
    docker exec "$container" mkdir -p /root/.ssh
    docker exec "$container" chmod 700 /root/.ssh
done
docker cp "$ROOT/tests/server-migration-integration/fixtures.py" "$SOURCE:/fixtures.py"
docker cp "$ROOT/tests/server-migration-integration/driver.py" "$SOURCE:/driver.py"
docker exec "$SOURCE" python3 /fixtures.py
docker exec "$SOURCE" ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
docker cp "$SOURCE:/root/.ssh/id_ed25519.pub" "$TEMP/source.pub"
docker cp "$TEMP/source.pub" "$DESTINATION:/root/.ssh/authorized_keys"
docker exec "$DESTINATION" chown root:root /root/.ssh/authorized_keys
docker exec "$DESTINATION" chmod 600 /root/.ssh/authorized_keys
docker exec "$DESTINATION" pkill -x sshd
docker exec "$DESTINATION" /usr/sbin/sshd -E /var/log/sshd-test.log
docker exec "$DESTINATION" mkdir -p /etc/nginx/snippets
docker exec "$DESTINATION" bash -c 'echo "# Existing destination policy" > /etc/nginx/snippets/migration-shared.conf; echo "existing-destination-dhparam" > /etc/nginx/ssl/shared-dhparam.pem'
docker exec "$DESTINATION" bash -c 'printf "server {\n    listen [::]:8080 ipv6only=on;\n    server_name existing-ipv6.test;\n    return 200;\n}\n" > /etc/nginx/conf.d/existing-ipv6.conf; nginx -t && nginx -s reload'
# Trust only the public host key obtained from this exact destination container.
docker cp "$DESTINATION:/etc/ssh/ssh_host_ed25519_key.pub" "$TEMP/host.pub"
awk '{print "migration-destination " $1 " " $2}' "$TEMP/host.pub" > "$TEMP/known_hosts"
docker cp "$TEMP/known_hosts" "$SOURCE:/root/.ssh/known_hosts"
docker exec "$SOURCE" python3 /driver.py
# Recreate only the disposable destination to test pull and offline import into a clean VPS.
docker rm -f "$DESTINATION" >/dev/null
docker run -d --name "$DESTINATION" --hostname migration-destination --network "$NETWORK" --network-alias migration-destination shieldpress-migration-test:local >/dev/null
for attempt in $(seq 1 30); do
    if docker exec "$DESTINATION" test -f /ready; then break; fi
    sleep 1
done
docker exec "$DESTINATION" test -f /ready
docker cp "$ROOT/shieldpress/modules/tools/server-migration.py" "$DESTINATION:/opt/shieldpress/modules/tools/server-migration.py"
docker exec "$DESTINATION" chown root:root /opt/shieldpress/modules/tools/server-migration.py
docker exec "$DESTINATION" chmod go-w /opt/shieldpress/modules/tools/server-migration.py
docker cp "$ROOT/shieldpress/modules/tools/migration-ssh.py" "$DESTINATION:/opt/shieldpress/modules/tools/migration-ssh.py"
docker exec "$DESTINATION" chown root:root /opt/shieldpress/modules/tools/migration-ssh.py
docker exec "$DESTINATION" chmod go-w /opt/shieldpress/modules/tools/migration-ssh.py
docker exec "$DESTINATION" mkdir -p /root/.ssh
docker exec "$DESTINATION" chmod 700 /root/.ssh
docker exec "$DESTINATION" ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
docker cp "$DESTINATION:/root/.ssh/id_ed25519.pub" "$TEMP/destination.pub"
docker cp "$TEMP/destination.pub" "$SOURCE:/root/.ssh/authorized_keys"
docker exec "$SOURCE" chown root:root /root/.ssh/authorized_keys
docker exec "$SOURCE" chmod 600 /root/.ssh/authorized_keys
docker cp "$SOURCE:/etc/ssh/ssh_host_ed25519_key.pub" "$TEMP/source-host.pub"
awk '{print "migration-source " $1 " " $2}' "$TEMP/source-host.pub" > "$TEMP/pull-known_hosts"
docker cp "$TEMP/pull-known_hosts" "$DESTINATION:/root/.ssh/known_hosts"
docker cp "$ROOT/tests/server-migration-integration/pull.py" "$DESTINATION:/pull.py"
docker exec "$DESTINATION" python3 /pull.py
