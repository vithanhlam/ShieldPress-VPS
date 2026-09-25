# PostgreSQL Streaming Replication Guide

This guide explains how to configure PostgreSQL Primary/Standby replication with ShieldPress.

```text
Primary server  ── near-real-time WAL ──>  Standby server
    accepts writes                         read-only / failover
```

Streaming replication does not replace `.sql.gz` backups. The scheduled 23:00 backup continues to run separately with `pg_dump` on the Primary server.

## 1. Prerequisites

- Two VPSs/servers: one Primary and one Standby.
- Both servers run the same PostgreSQL major version.
- Both servers have fixed private IP addresses or a VPN connection.
- The Standby does not run applications that write to the database.
- ShieldPress is up to date and includes the Safe Setup Wizard.

Check both servers:

```bash
psql --version
sudo -u postgres psql -Atc "SHOW data_directory;"
```

Allow PostgreSQL traffic only from the Standby's IP address to the Primary. Avoid using public IP addresses when private IP addresses are available.

## 2. Recommended values

| Setting | Value |
|---|---|
| PostgreSQL port | `5432` |
| Replication role | `shieldpress_repl` |
| Replication slot | `shieldpress_standby` |
| Primary bind address | `0.0.0.0` or the Primary's private IP |
| WAL retention | `7` full backups |

Enter the two servers' IP addresses and the replication password manually. Press Enter to accept the default values for other settings.

## 3. Configure the Primary server

On the Primary server:

```text
sudo shieldpress
→ Database
→ PostgreSQL Manager
→ 10) Streaming Replication
→ 1) THIS SERVER = PRIMARY
```

The wizard displays the hostname, role and `PGDATA`. Confirm that this is the correct server, then:

1. Type `PRIMARY`.
2. Enter the Standby's private IP address.
3. Replication role: press Enter to use `shieldpress_repl`.
4. Enter a strong replication password and save it.
5. Replication slot: press Enter to use `shieldpress_standby`.
6. Bind address: use `0.0.0.0` or the Primary's private IP address.
7. Port: press Enter to use `5432`.
8. Wait for the `Primary configured` message.

Streaming replication does not require S3. To store WAL files off-site or enable point-in-time recovery (PITR), open the `Configure pgBackRest S3` menu after the Primary has been configured.

ShieldPress creates the replication role and slot, configures `pg_hba.conf` and `wal_level=replica`, and runs a health check every minute.

## 4. Configure pgBackRest S3 (optional)

On the Primary, select this item from the Streaming Replication menu:

```text
7) Configure pgBackRest S3 [optional]
```

Enter S3 details only if you need off-site WAL/backup storage and PITR. This configuration is separate from streaming replication; skipping it does not prevent the Standby from syncing.

## 5. Configure the Standby server

On the Standby server:

```text
sudo shieldpress
→ Database
→ PostgreSQL Manager
→ 10) Streaming Replication
→ 2) THIS SERVER = STANDBY
```

Enter:

1. Type `STANDBY`.
2. Primary private IP: enter the Primary's private IP address.
3. Port: press Enter to use `5432`.
4. Replication role: press Enter to use `shieldpress_repl`.
5. Enter the same password that you created on the Primary.
6. Replication slot: press Enter to use `shieldpress_standby`.
7. When asked to replace `PGDATA`, type `REPLACE` only if this is the correct Standby server.

ShieldPress uses `pg_basebackup -R -X stream` to create the initial copy from the Primary.

## 6. Data protection

On the Standby, ShieldPress renames the existing data directory to:

```text
<PGDATA>.shieldpress-before-standby-YYYYMMDD_HHMMSS
```

If the connection or `pg_basebackup` fails, the existing data is restored. The old backup is kept after a successful sync for manual inspection.

Do not run `Initialize Standby` on the Primary. Do not type `REPLACE` before checking the hostname and role shown on screen.

## 7. Verify the configuration

### On the Primary

```bash
sudo -u postgres psql -x -c \
"SELECT client_addr, state, sync_state,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS lag
 FROM pg_stat_replication;"
```

The normal state is:

```text
state = streaming
```

Check the replication slot:

```bash
sudo -u postgres psql -x -c \
"SELECT slot_name, active FROM pg_replication_slots;"
```

### On the Standby

```bash
sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"
```

The result should be `t`.

Check the health timer:

```bash
sudo systemctl status shieldpress-postgresql-replication-health.timer
sudo tail -50 /var/log/shieldpress/postgresql-replication-health.log
```

## 8. Items in menu [10]

| Menu item | Function |
|---|---|
| Check replication status | Check the replication state |
| Promote Standby to Primary | Promote the Standby during failover |
| Run pgBackRest full backup | Create a full physical backup |
| Test isolated restore | Test restoring a backup in isolation |

Do not promote during normal operation. Before promoting, isolate or stop the old Primary to prevent split-brain.

## 9. If the Primary fails

1. Confirm that the Primary is stopped or isolated from the network.
2. On the Standby, confirm that `pg_is_in_recovery()` returns `t`.
3. Open menu [10] and select **Promote Standby to Primary**.
4. Point DNS or the application configuration to the Standby.
5. Check the application and data before allowing writes.

Do not reconnect the old Primary until its role has been handled. This prevents both servers from accepting writes at the same time.

## 10. Backup and maintenance

- Keep the scheduled 23:00 database backup enabled.
- Do not rely on the Standby as the only backup.
- Monitor replication lag and disk space.
- Do not delete a replication slot while the Standby is using it.
- If the Standby is offline for a long time, WAL files can accumulate on the Primary.
- Run pgBackRest full backups and isolated restore tests regularly.
