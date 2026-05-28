# Patroni, PostgreSQL 18 & PgBouncer — Operations Reference

*Date: 2026-05-28 | Applies to: tower.local (Postgres Docker), talos-00/01/02 (Patroni cluster)*

---

## Architecture

```
PostgreSQL 18 (Docker, tower.local:5432)
  └─ PgBouncer (Docker, tower.local:6432) ← connection pooling
       └─ clients (Kubernetes apps)

Patroni HA cluster (Kubernetes nodes):
  talos-02 (192.168.1.13) — Leader, TL 71
  talos-01 (192.168.1.12) — Replica, streaming
  talos-00 (192.168.1.11) — Replica (may have start issues — see below)
       └─ pgBackRest (backup to tower.local NFS)
```

---

## PostgreSQL 18 (tower.local Docker)

### Config Location
```
/mnt/user/appdata/postgresql18/18/docker/postgresql.conf
/mnt/user/appdata/postgresql18/18/docker/pg_hba.conf
/mnt/user/appdata/postgresql18/certs/   # TLS certs (ca.crt, server.crt, server.key)
```

### Access Rules (`pg_hba.conf`)

| Connection Type | Auth | SSL |
|----------------|------|-----|
| Local (unix socket) | `trust` | N/A |
| 127.0.0.1/32 (loopback) | `trust` | No |
| 192.168.1.0/24 (LAN) | `scram-sha-256` | No |
| Other | Blocked | — |

> External connections are fully blocked. Only local and LAN clients are permitted.

### TLS Certificates
- Self-signed, 10-year validity
- SANs: `tower.local`, `192.168.1.40`
- All files owned uid=999 (postgres); `server.key` chmod 600
- Location: `/mnt/user/appdata/postgresql18/certs/`

### Performance Tuning
- `max_connections = 100`
- `shared_buffers = 1GB`

---

## PgBouncer (tower.local Docker)

**Container:** `pgbouncer-transaction` (pool_mode is actually `session`, despite the name)

### Config Location
```
/mnt/user/appdata/pgbouncer/transaction-mode/pgbouncer.ini
/mnt/user/appdata/pgbouncer/transaction-mode/userlist.txt
```

### Key Config
```ini
[databases]
* = host=192.168.1.40 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
pool_mode = session
max_db_connections = 89    # leaves 11 headroom below Postgres max_connections=100
auth_type = scram-sha-256
auth_user = postgres       # must be superuser to read pg_shadow
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1
```

### userlist.txt
Contains SCRAM verifiers (NOT plain passwords). If Postgres is rebuilt/restored, refresh verifiers:
```sql
-- On Postgres: get current SCRAM verifier for postgres user
SELECT passwd FROM pg_shadow WHERE usename = 'postgres';
```
Then update `/mnt/user/appdata/pgbouncer/transaction-mode/userlist.txt`:
```
"postgres" "SCRAM-SHA-256$..."
```
Reload: `docker exec pgbouncer-transaction pgbouncer -R /etc/pgbouncer/pgbouncer.ini`

### Troubleshooting PgBouncer
```bash
# Check if config directory exists (ephemeral if missing):
docker exec pgbouncer-transaction ls /etc/pgbouncer/
# If missing, the container generated ephemeral config from ENV vars
# → ensure the mount path /mnt/user/appdata/pgbouncer/transaction-mode/ exists on host

# Reload config without restart:
docker exec pgbouncer-transaction kill -HUP 1

# Admin console:
psql -h 192.168.1.40 -p 6432 -U pgbouncer pgbouncer
SHOW POOLS;
SHOW CLIENTS;
```

---

## Patroni HA Cluster

### Cluster Status
```bash
# From any cluster node:
ssh ubuntu@192.168.1.12  # talos-01
sudo patronictl -c /etc/patroni/config.yml list
```

### pgBackRest Backup

The Patroni cluster uses pgBackRest for backups. Stanza: `production-db`.

**Trigger a full backup manually (from Leader talos-02):**
```bash
ssh ubuntu@192.168.1.13
sudo -u postgres pgbackrest --stanza=production-db --type=full backup
```

**Check archive status:**
```bash
sudo -u postgres pgbackrest --stanza=production-db info
```

> The pgBackRest archive WAL endpoint uses `unraid.netbird.cloud` (DNS alias for tower.local). Verify DNS resolution if backups fail: `dig unraid.netbird.cloud`

**Reduce pgBackRest log verbosity:**
In `/etc/pgbackrest/pgbackrest.conf`:
```ini
[global]
log-level-console = warn   # was: info
log-level-file = warn
```

---

## Patroni Timeline Mismatch (talos-00)

### Symptoms
- `sudo patronictl -c /etc/patroni/config.yml list` shows talos-00 with status `start failed`
- `journalctl -u patroni` shows repeated "failed to start postgres" every ~3 seconds
- talos-00 data directory at lower timeline than cluster leader

### Root Cause
- talos-00's data dir WAL history files don't include the timelines the leader promoted through
- Postgres refuses to start replica: `server shut down because of recovery target settings`
- Diagnostic: `ls /var/lib/postgresql/18/data/pg_wal/*.history` — missing TL entries

### Fix: Patroni `reinitialize`
```bash
# From talos-02 (leader):
ssh ubuntu@192.168.1.13
sudo patronictl -c /etc/patroni/config.yml reinitialize homelab-postgres --member talos-00 --force
```

This triggers a fresh `pg_basebackup` from the leader. Monitor:
```bash
ssh ubuntu@192.168.1.11
sudo journalctl -u patroni -f
# Should see: "base backup done" then "replica streaming"
```

> ⚠️ reinitialize copies ~17GB from the leader. Ensure talos-00 has sufficient disk space first (`df -h /`).

### Preventing Log Spam During Start Failure
If Patroni is stuck in start-failed loop and filling disk:
```bash
# Temporarily stop patroni to stop log spam:
sudo systemctl stop patroni
# Check root cause first, then fix, then restart:
sudo systemctl start patroni
```

---

## vault-agent VM (192.168.1.7)

The vault-agent VM provides secrets to tower.local NFS (`/mnt/user/appdata/`) via Vault templates.

### Key Services
```bash
# Check all vault-related services:
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.7 \
  "systemctl status vault mnt-docker-datastore.mount"
```

### NFS Mount (replaces autofs — autofs fails in LXC)
```
Unit: /etc/systemd/system/mnt-docker-datastore.mount
Mount: 192.168.1.40:/mnt/user/appdata/swarm → /mnt/docker-datastore
```

### Vault depends on NFS
```
/etc/systemd/system/vault.service.d/nfs-mount.conf
→ After=mnt-docker-datastore.mount
→ Requires=mnt-docker-datastore.mount
```

### TLS Cert Delivery
Vault templates render certs to `/mnt/docker-datastore/` (NFS) → tower.local reads from `/mnt/user/appdata/swarm/` → Postgres container mounts from `/mnt/user/appdata/postgresql18/certs/`

If cert delivery fails:
```bash
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.7
journalctl -u vault -f
# Check template render errors
vault agent -config /etc/vault.d/vault-agent.hcl   # manual test
```
