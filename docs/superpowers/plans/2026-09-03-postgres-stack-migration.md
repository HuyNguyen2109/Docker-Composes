# PostgreSQL Stack Migration (tower.local → talos-cloud-00) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the entire `postgresql` Docker Compose stack (PostgreSQL 18, PgBouncer, pgAdmin4, Databasus) from `tower.local` to `talos-cloud-00` with no data loss and minimal client disruption, then repoint the 4 live clients to the new PgBouncer over the WireGuard overlay.

**Architecture:** Physical `pg_basebackup` clone with a rehearsal restore + a frozen cutover re-sync. New PgBouncer binds only to the WireGuard IP `10.99.0.1:5432` (no mTLS, no public exposure). Old stack stays running until every client is verified on the new stack.

**Tech Stack:** Docker / Docker Compose, PostgreSQL 18 (`pgvector/pgvector:pg18-trixie`), PgBouncer (`edoburu/pgbouncer:v1.25.2-p0`), WireGuard overlay, Bash/SSH.

> **Execution deviations (captured during run, 2026-09-03):**
> 1. **Local-container hairpin**: containers on `talos-cloud-00` cannot reach the host's own `10.99.0.1` (SYN blackholed). Zitadel/Kanbn were therefore attached to the `db-intranet` network and point at `pgbouncer:5432`, while only the tower clients (Vault/Immich) use `10.99.0.1:5432`.
> 2. **Replication slot SQL**: `pg_create_physical_replication_slot` requires the slot name in single quotes (string literal), not double quotes.
> 3. **Basebackup size**: source was ~179 MB gzipped (not ~1.5 GB) — data is highly compressible; verified complete via `backup_label`, `backup_manifest`, and byte-identical restore.
> 4. **Post-cutover fix (immich)**: `immichdb-admin` was not in PgBouncer's `userlist.txt`, and PgBouncer's `auth_query` path fails for users absent from the file (SCRAM verifier can't be used to connect as `auth_user`). Added `immichdb-admin` to `userlist.txt` + `SIGHUP` reload — immich recovered. Any future app role routed through PgBouncer must be added to `userlist.txt`.

## Global Constraints

- **Source host** `tower.local` = `unraid.internal` = `192.168.1.40`; SSH from the controller: `ssh -i /root/ssh-keys/homelab-linux root@unraid.internal`.
- **Target host** `talos-cloud-00` = `14.225.220.145`, WireGuard IP `10.99.0.1`; SSH from the controller: `ssh -i /root/ssh-keys/oracle root@talos-cloud-00`.
- **Source compose project**: `/mnt/user/appdata/arcane/projects/PostgreSQL/` (`compose.yaml`, `.env`).
- **Source data root** `MASTER_DIR`: `/mnt/user/appdata/docker-stack-data/postgres` with subdirs `postgres-data`, `pgbouncer`, `pgadmin4`, `databasus`.
- **Target compose project**: `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/`.
- **Target data root**: `/var/lib/docker-stack-data/postgres` (local disk — NOT NFS).
- **Postgres image**: `pgvector/pgvector:pg18-trixie` (PGDATA inside container = `/var/lib/postgresql/18/docker`, data owner uid/gid `999`).
- **Superuser / password**: `postgres` / `P4ssw0rd!!!` (also `PGPASSWORD` for non-trust paths).
- **pg_hba**: `local` and `127.0.0.1` (incl. replication) are `trust`; remote is `scram-sha-256`. Basebackup from localhost needs no password.
- **Do NOT** destroy/remove the old tower stack until the entire migration is verified (rollback = revert client DSNs).
- **Do NOT** open port 5432 on the public IP; PgBouncer binds `10.99.0.1` only.

---

### Task 1: Snapshot source and capture baseline

**Files:** none (operational)

**Interfaces:**
- Produces: `baseline.txt` (DB list, roles, per-DB row counts), `postgres-basebackup.tar.gz`, `postgres-dumpall.sql` on the controller/tower — consumed by Task 3 and Task 7 verification.

- [ ] **Step 1: Record baseline on source (DBs, roles, per-DB sizes/row counts)**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec postgres18 psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;" \
   && echo "---ROLES---" \
   && docker exec postgres18 psql -U postgres -tAc "SELECT rolname,rolcanlogin,rolsuper FROM pg_roles WHERE rolcanlogin ORDER BY 1;" \
   && echo "---SIZES---" \
   && docker exec postgres18 psql -U postgres -tAc "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false ORDER BY 1;"' \
  > baseline.txt
```
Expected: 7 databases (`benchmarkdb, immichdb, kanbn, pocketid-db, postgres, vault-data, zitadel`) and 11 login roles recorded.

- [ ] **Step 2: Take physical basebackup (rehearsal) and a logical dump (safety net)**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec postgres18 pg_basebackup -h 127.0.0.1 -U postgres -D - -Ft -z -X fetch' \
  > postgres-basebackup.tar.gz

ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec postgres18 pg_dumpall -h 127.0.0.1 -U postgres' \
  > postgres-dumpall.sql
```
Expected: both files non-empty; `gzip -t postgres-basebackup.tar.gz` reports OK; `postgres-dumpall.sql` starts with role `CREATE ROLE`/`ALTER ROLE` statements.

- [ ] **Step 3: Verify artifact sizes and integrity**

```bash
ls -lh postgres-basebackup.tar.gz postgres-dumpall.sql baseline.txt
gzip -t postgres-basebackup.tar.gz && echo "gzip OK"
grep -c "CREATE ROLE\|ALTER ROLE" postgres-dumpall.sql
```
Expected: basebackup ≈ 1.5 GB (or less, gzip-compressed), dumpall contains ~11 role statements.

- [ ] **Step 4: Commit the baseline for audit**

```bash
git add baseline.txt
git commit -m "chore(migration): capture PostgreSQL source baseline (dbs/roles/sizes)"
```
(Commit `postgres-dumpall.sql` to a private/ignored location, NOT git — it contains passwords.)

---

### Task 2: Provision target prerequisites on talos-cloud-00

**Files:**
- Create: `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/` (empty project dir)

**Interfaces:**
- Produces: `db-intranet` bridge network, project dir + local data dir — consumed by Tasks 3–5.

- [ ] **Step 1: Create the internal `db-intranet` network**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker network create --driver bridge db-intranet 2>&1 || echo "already exists"; docker network ls | grep db-intranet'
```
Expected: `db-intranet` listed.

- [ ] **Step 2: Create project dir (NFS) and local data dir**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'mkdir -p /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL \
          /var/lib/docker-stack-data/postgres/{postgres-data,pgbouncer,pgadmin4,databasus} \
   && ls -ld /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL /var/lib/docker-stack-data/postgres'
```
Expected: all dirs created.

- [ ] **Step 3: Verify free space is sufficient (≥ 10 GB)**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 'df -h /var/lib/docker-stack-data | tail -1'
```
Expected: Avail ≥ 10 GB (source is ~1.5 GB + WAL growth headroom).

---

### Task 3: Deploy Postgres on target and restore the basebackup

**Files:**
- Create: `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/compose.yaml`
- Create: `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/.env`

**Interfaces:**
- Consumes: `db-intranet` network (Task 2), `postgres-basebackup.tar.gz` (Task 1).
- Produces: running `postgres18` container with restored cluster — consumed by Tasks 4–6.

- [ ] **Step 1: Write the target `.env`**

```bash
cat > /tmp/pg.env <<'EOF'
MASTER_DIR=/var/lib/docker-stack-data/postgres
PGBOUNCER_IMAGE_TAG=v1.25.2-p0
PGADMIN_IMAGE_TAG=9.16
POSTGRES18_IMAGE_TAG=pg18-trixie
PGADMIN_DEFAULT_PASSWORD=M@$$ter21091996
PGADMIN_DEFAULT_EMAIL=JohnasHuy21091996@gmail.com
POSTGRES_PASSWORD=P4ssw0rd!!!
EOF
scp -i /root/ssh-keys/oracle /tmp/pg.env root@talos-cloud-00:/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/.env
```

- [ ] **Step 2: Write the target `compose.yaml` (postgres service only, for now)**

```bash
cat > /tmp/compose.yaml <<'EOF'
services:
  postgres:
    image: pgvector/pgvector:${POSTGRES18_IMAGE_TAG}
    container_name: postgres18
    user: 0:0
    hostname: postgres
    restart: always
    shm_size: 1gb
    env_file:
      - .env
    networks:
      db-intranet: {}
    mem_limit: 1G
    mem_reservation: 1G
    cpus: 2
    volumes:
      - ${MASTER_DIR}/postgres-data:/var/lib/postgresql
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
networks:
  db-intranet:
    external: true
EOF
scp -i /root/ssh-keys/oracle /tmp/compose.yaml root@talos-cloud-00:/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/compose.yaml
```

- [ ] **Step 3: Restore the basebackup into the empty PGDATA**

```bash
# Transfer the basebackup to the target
scp -i /root/ssh-keys/oracle postgres-basebackup.tar.gz root@talos-cloud-00:/tmp/

ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'mkdir -p /var/lib/docker-stack-data/postgres/postgres-data/18/docker \
   && tar -xzf /tmp/postgres-basebackup.tar.gz -C /var/lib/docker-stack-data/postgres/postgres-data/18/docker \
   && chown -R 999:999 /var/lib/docker-stack-data/postgres/postgres-data/18/docker \
   && ls /var/lib/docker-stack-data/postgres/postgres-data/18/docker | head'
```
Expected: the PGDATA dir now contains `base`, `global`, `pg_wal`, `PG_VERSION`, `postgresql.conf`, `pg_hba.conf`, `postgresql.auto.conf`.

- [ ] **Step 4: Start postgres and confirm it comes up on the restored cluster**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'cd /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL && docker compose up -d postgres && sleep 8 && docker exec postgres18 pg_isready -U postgres'
```
Expected: `accepting connections`.

- [ ] **Step 5: Verify databases, roles, and sizes match the baseline**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;" \
   && echo "---ROLES---" \
   && docker exec postgres18 psql -U postgres -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY 1;" \
   && echo "---SIZES---" \
   && docker exec postgres18 psql -U postgres -tAc "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false ORDER BY 1;"' \
  > target-baseline.txt
# DB names and roles must match EXACTLY (sizes are informational for the rehearsal)
grep -v -E '^---' baseline.txt | sed '/pg_size_pretty/d' > /tmp/b1.txt
grep -v -E '^---' target-baseline.txt | sed '/pg_size_pretty/d' > /tmp/b2.txt
diff /tmp/b1.txt /tmp/b2.txt && echo "DBS+ROLES MATCH"
```
Expected: `DBS+ROLES MATCH` (sizes may differ slightly — this is a rehearsal; the authoritative consistency gate is Task 7 Step 5).

---

### Task 4: Deploy PgBouncer (bind 10.99.0.1) + firewall hardening

**Files:**
- Modify: `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/compose.yaml` (add pgbouncer)
- Create: target `pgbouncer/pgbouncer.ini`, `pgbouncer/userlist.txt`

**Interfaces:**
- Consumes: running `postgres18` (Task 3), `db-intranet`.
- Produces: `pgbouncer` listening on `10.99.0.1:5432` — consumed by Tasks 6–9.

- [ ] **Step 1: Copy PgBouncer config + userlist from source**

```bash
scp -i /root/ssh-keys/homelab-linux root@unraid.internal:/mnt/user/appdata/docker-stack-data/postgres/pgbouncer/pgbouncer.ini /tmp/pgbouncer.ini
scp -i /root/ssh-keys/homelab-linux root@unraid.internal:/mnt/user/appdata/docker-stack-data/postgres/pgbouncer/userlist.txt /tmp/userlist.txt
scp -i /root/ssh-keys/oracle /tmp/pgbouncer.ini /tmp/userlist.txt root@talos-cloud-00:/var/lib/docker-stack-data/postgres/pgbouncer/
```
Verify `pgbouncer.ini` still contains `[databases]\n* = host=postgres port=5432 pool_mode=session` (hostname `postgres` resolves to the new postgres on `db-intranet`).

- [ ] **Step 2: Add pgbouncer service to compose (bind to 10.99.0.1)**

Append to `compose.yaml`:

```yaml
  pgbouncer:
    depends_on:
      - postgres
    image: edoburu/pgbouncer:${PGBOUNCER_IMAGE_TAG:-latest}
    container_name: pgbouncer
    hostname: pgbouncer
    env_file:
      - .env
    ports:
      - "10.99.0.1:5432:5432"
    volumes:
      - ${MASTER_DIR}/pgbouncer:/etc/pgbouncer
    restart: unless-stopped
    networks:
      db-intranet: {}
    mem_limit: 256M
    mem_reservation: 256m
    cpus: 2
```

- [ ] **Step 3: Start pgbouncer and verify it pools to postgres**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'cd /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL && docker compose up -d pgbouncer && sleep 6 \
   && docker exec pgbouncer psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc "SELECT 1"'
```
Expected: `1` (PgBouncer authenticates `postgres` via `userlist.txt`/auth and pools to postgres).

- [ ] **Step 4: Confirm 5432 is bound ONLY to 10.99.0.1**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 'ss -tlnp | grep ":5432 "'
```
Expected: `LISTEN 0 ... 10.99.0.1:5432 ...` — NOT `0.0.0.0:5432` and NOT `14.225.220.145:5432`.

- [ ] **Step 5: Add DOCKER-USER drop rule (defense-in-depth) and persist**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'iptables -I DOCKER-USER 1 -p tcp --dport 5432 -s 10.99.0.0/24 -j ACCEPT \
   && iptables -I DOCKER-USER 2 -p tcp --dport 5432 -s 127.0.0.1/32 -j ACCEPT \
   && iptables -I DOCKER-USER 3 -p tcp --dport 5432 -j DROP \
   && iptables -L DOCKER-USER -n --line-numbers | head'
```
Expected: the three rules present in order (ACCEPT 10.99.0.0/24, ACCEPT 127.0.0.1, DROP rest). Persist with `netfilter-persistent save` (or the host's existing iptables persistence mechanism).

- [ ] **Step 6: Save a copy of the target stack files to the repo for documentation**

```bash
# The compose.yaml/.env live on the remote server (not git-tracked there).
# Keep an audit copy in this repo (redact secrets before committing).
mkdir -p /root/workspace/My-DevOps/docs/superpowers/migration-artifacts/postgresql
scp -i /root/ssh-keys/oracle \
  root@talos-cloud-00:/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/compose.yaml \
  /root/workspace/My-DevOps/docs/superpowers/migration-artifacts/postgresql/compose.yaml
git add docs/superpowers/migration-artifacts/postgresql/compose.yaml
git commit -m "docs(migration): add target PostgreSQL compose stack (talos-cloud-00)"
```
(Do NOT commit `.env` — it contains passwords.)

---

### Task 5: Deploy pgAdmin4 and Databasus (migrate their data)

**Files:**
- Modify: target `compose.yaml` (add pgadmin4, databasus)
- Create: target data dirs populated from source

**Interfaces:**
- Consumes: `db-intranet`, running postgres/pgbouncer.
- Produces: `pgadmin4` (:3000) and `databasus` (:4005) running, Databasus re-pointed to the new postgres — verified in Task 9.

- [ ] **Step 1: Copy pgAdmin4 and Databasus data dirs from source**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'tar -C /mnt/user/appdata/docker-stack-data/postgres -czf - pgadmin4 databasus' \
  | ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
    'tar -C /var/lib/docker-stack-data/postgres -xzf -'
```
Expected: transfer completes; `databasus/` retains `pgdata/`, `secret.key`, `instance.json`, `backups/`.

- [ ] **Step 2: Add pgadmin4 + databasus services to compose**

Append to `compose.yaml`:

```yaml
  pgadmin4:
    image: dpage/pgadmin4:${PGADMIN_IMAGE_TAG:-9.16}
    container_name: pgadmin4
    hostname: pgadmin
    env_file:
      - .env
    ports:
      - "10.99.0.1:3000:80"
    volumes:
      - ${MASTER_DIR}/pgadmin4:/var/lib/pgadmin
    networks:
      db-intranet: {}
    restart: unless-stopped
    environment:
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_DEFAULT_PASSWORD}
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_DEFAULT_EMAIL}
      PGADMIN_CONFIG_LOG_FILE: "'/dev/null'"
    mem_limit: 1G
    mem_reservation: 256m
    cpus: 1

  databasus:
    container_name: databasus
    image: databasus/databasus:latest
    ports:
      - "10.99.0.1:4005:4005"
    volumes:
      - ${MASTER_DIR}/databasus:/databasus-data
    restart: unless-stopped
    networks:
      db-intranet: {}
    mem_limit: 512M
    mem_reservation: 256m
    cpus: 1
```

- [ ] **Step 3: Start both services**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'cd /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL && docker compose up -d pgadmin4 databasus && sleep 10 && docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "pgadmin4|databasus"'
```
Expected: both `Up` (databasus `healthy`).

- [ ] **Step 4: Recreate the physical replication slot on the new primary**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -tAc "SELECT slot_name FROM pg_replication_slots;" \
   && docker exec postgres18 psql -U postgres -c "SELECT pg_create_physical_replication_slot(\"databasus_slot_2cbac9339c6c4249aecd615688593104\");"'
```
Expected: the slot `databasus_slot_...` is recreated (basebackup does not copy slots).

- [ ] **Step 5: Verify Databasus reconnects and WAL streaming resumes**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -tAc "SELECT application_name, state FROM pg_stat_replication;"'
```
Expected: a `databasus_wal_receiver_...` row in state `streaming`. (If Databasus must be re-pointed via its web UI at `10.99.0.1:4005`, do so: edit the managed instance's host to `postgres` and re-save; then re-check.)

---

### Task 6: Connectivity verification (pre-cutover, read-only)

**Files:** none

**Interfaces:**
- Consumes: pgbouncer on `10.99.0.1:5432`.
- Produces: confirmation that both tower and local clients can reach the new pgbouncer — gate before Task 7.

- [ ] **Step 1: Verify from a tower container (over the WireGuard tunnel)**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec postgres18 sh -c "PGPASSWORD=P4ssw0rd!!! psql -h 10.99.0.1 -p 5432 -U postgres -d postgres -tAc \"SELECT current_database();\""'
```
Expected: `postgres` (tower's container reaches the new pgbouncer over `wg0`).

- [ ] **Step 2: Verify from a local talos-cloud-00 container**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec zitadel-api sh -c "true" 2>/dev/null; docker run --rm --network db-intranet postgres:18-trixie sh -c "PGPASSWORD=P4ssw0rd!!! psql -h 10.99.0.1 -p 5432 -U postgres -d postgres -tAc \"SELECT 1\""'
```
Expected: `1`.

- [ ] **Step 3: Verify PgBouncer is tracking pools**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec pgbouncer psql -h 127.0.0.1 -p 5432 -U postgres -d pgbouncer -tAc "SHOW POOLS;"'
```
Expected: a non-empty pool table (the admin console `pgbouncer` DB responds).

- [ ] **Step 4: Verify no listener on public IP**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 'ss -tlnp | grep ":5432 " | grep -v 10.99.0.1 || echo "only on wg0 (correct)"'
```
Expected: only the `10.99.0.1:5432` listener.

---

### Task 7: Cutover — freeze writes and final sync

**Files:** none

**Interfaces:**
- Consumes: verified new stack (Tasks 3–6).
- Produces: new postgres at the frozen point-in-time; old stack paused — consumed by Tasks 8–9.

- [ ] **Step 1: Freeze all writes on the old stack**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker stop pgbouncer \
   && docker stop immich-server'
```
(PgBouncer clients = Vault/Zitadel/Kanbn; Immich is the only direct-to-postgres writer. Stopping both freezes all writes.)

- [ ] **Step 2: Take the FINAL consistent basebackup**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec postgres18 pg_basebackup -h 127.0.0.1 -U postgres -D - -Ft -z -X fetch' \
  > postgres-final-backup.tar.gz
gzip -t postgres-final-backup.tar.gz && echo "final gzip OK"
```

- [ ] **Step 3: Restore the final backup over the rehearsal data**

```bash
scp -i /root/ssh-keys/oracle postgres-final-backup.tar.gz root@talos-cloud-00:/tmp/
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker compose -f /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/compose.yaml down \
   && rm -rf /var/lib/docker-stack-data/postgres/postgres-data/18/docker/* \
   && tar -xzf /tmp/postgres-final-backup.tar.gz -C /var/lib/docker-stack-data/postgres/postgres-data/18/docker \
   && chown -R 999:999 /var/lib/docker-stack-data/postgres/postgres-data/18/docker \
   && cd /mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL && docker compose up -d postgres pgbouncer pgadmin4 databasus \
   && sleep 10 && docker exec postgres18 pg_isready -U postgres'
```
Expected: `accepting connections`.

- [ ] **Step 4: Recreate the replication slot again (final restore wiped it)**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -c "SELECT pg_create_physical_replication_slot(\"databasus_slot_2cbac9339c6c4249aecd615688593104\");" 2>&1'
```
Expected: slot recreated (ignore "already exists" if Databasus beat us to it).

- [ ] **Step 5: Verify final data matches baseline (consistency gate)**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;"' \
  > final-dbs.txt
diff <(grep -vE '^---' baseline.txt) <(cat final-dbs.txt) && echo "DBS MATCH"
```
Expected: `DBS MATCH`.

---

### Task 8: Repoint clients one at a time and verify

**Files:**
- Modify: `/mnt/nfs-server.d/docker-share/arcane/projects/Zitadel/.env`
- Modify: `/mnt/nfs-server.d/docker-share/arcane/projects/kanbn/.env`
- Modify: `/mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env`
- Modify: `/mnt/user/appdata/arcane/projects/Immich/.env`

**Interfaces:**
- Consumes: new pgbouncer `10.99.0.1:5432`.
- Produces: all 4 clients writing to the new stack — verified in Task 9.

For each client: change ONLY the host part of the connection string to `10.99.0.1`, keep username/password/db/escaping exactly as-is, then recreate the service and verify.

- [ ] **Step 1: Repoint Zitadel (talos-cloud-00)**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'sed -i "s|@unraid.internal:5432|@10.99.0.1:5432|" /mnt/nfs-server.d/docker-share/arcane/projects/Zitadel/.env \
   && grep ZITADEL_DATABASE_POSTGRES_DSN /mnt/nfs-server.d/docker-share/arcane/projects/Zitadel/.env'
```
Expected: DSN now `...@10.99.0.1:5432/zitadel?sslmode=disable`.

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'cd /mnt/nfs-server.d/docker-share/arcane/projects/Zitadel && docker compose up -d --force-recreate && sleep 12 && docker ps --format "{{.Names}}\t{{.Status}}" | grep zitadel'
```
Expected: `zitadel-api` / `zitadel-login` healthy. Verify: `docker logs zitadel-api --tail 30` shows no `connection refused` / `password authentication failed`.

- [ ] **Step 2: Repoint Kanbn (talos-cloud-00)**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'sed -i "s|@unraid.internal:5432|@10.99.0.1:5432|" /mnt/nfs-server.d/docker-share/arcane/projects/kanbn/.env \
   && grep POSTGRES_URL /mnt/nfs-server.d/docker-share/arcane/projects/kanbn/.env \
   && cd /mnt/nfs-server.d/docker-share/arcane/projects/kanbn && docker compose up -d --force-recreate && sleep 12 && docker ps --format "{{.Names}}\t{{.Status}}" | grep kan'
```
Expected: `kan-web` up; `docker logs kan-web --tail 30` shows successful DB migration/connect.

- [ ] **Step 3: Repoint Vault (tower)**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'sed -i "s|@pgbouncer:5432|@10.99.0.1:5432|" /mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env \
   && grep PG_CONNECTION_STRING /mnt/user/appdata/arcane/projects/Hashicorp-Vault/.env'
```
Expected: connection string now `...@10.99.0.1:5432/vault-data`.

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'cd /mnt/user/appdata/arcane/projects/Hashicorp-Vault && docker compose up -d --force-recreate && sleep 15 && docker ps --format "{{.Names}}\t{{.Status}}" | grep hashicorp-vault'
```
Expected: `hashicorp-vault` up; `docker logs hashicorp-vault --tail 40` shows storage connected (no Postgres errors).

- [ ] **Step 4: Repoint Immich (tower)**

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'sed -i "s|^DB_HOSTNAME=postgres|DB_HOSTNAME=10.99.0.1|" /mnt/user/appdata/arcane/projects/Immich/.env \
   && grep DB_HOSTNAME /mnt/user/appdata/arcane/projects/Immich/.env'
```
Expected: `DB_HOSTNAME=10.99.0.1`.

```bash
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'cd /mnt/user/appdata/arcane/projects/Immich && docker compose up -d --force-recreate && sleep 15 && docker ps --format "{{.Names}}\t{{.Status}}" | grep immich-server'
```
Expected: `immich-server` healthy; `docker logs immich-server --tail 30` shows DB connection OK (it now pools through the new pgbouncer).

---

### Task 9: Final verification and rollback posture

**Files:** none

**Interfaces:**
- Consumes: all 4 clients repointed.
- Produces: signed-off migration; old stack retained as rollback.

- [ ] **Step 1: Verify all 4 clients active on the new pgbouncer**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec pgbouncer psql -h 127.0.0.1 -p 5432 -U postgres -d pgbouncer -c "SHOW POOLS;" \
   && docker exec pgbouncer psql -h 127.0.0.1 -p 5432 -U postgres -d pgbouncer -c "SHOW STATS;"'
```
Expected: pool entries for `vault-data`, `zitadel`, `kanbn`, `immichdb` databases with non-zero `active`/`cl_wait` counters reflecting live connections.

- [ ] **Step 2: Verify app-level health**

```bash
# Vault status (tower)
ssh -i /root/ssh-keys/homelab-linux root@unraid.internal \
  'docker exec hashicorp-vault sh -c "vault status 2>/dev/null | head -3"'
# Zitadel health (cloud)
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/healthz 2>/dev/null || docker exec zitadel-api wget -qO- http://127.0.0.1:8080/healthz 2>/dev/null | head -c 100'
```
Expected: Vault `Sealed: false` (or initialised), Zitadel returns `200`.

- [ ] **Step 3: Verify Databasus S3 backup job is intact**

```bash
ssh -i /root/ssh-keys/oracle root@talos-cloud-00 \
  'docker exec postgres18 psql -U postgres -tAc "SELECT application_name,state FROM pg_stat_replication;" \
   && ls -la /var/lib/docker-stack-data/postgres/databasus/backups/wal-queue/ 2>/dev/null'
```
Expected: a `databasus_wal_receiver_...` in `streaming`; the WAL-queue dir still present (Databasus backup continuity). If the Databasus UI shows the S3 target configured, confirm the destination is unchanged (`s3.mcb-homelab.com`).

- [ ] **Step 4: Record the rollback posture (do NOT destroy old stack)**

Document (do not execute):
- **Rollback**: on each client, revert the `10.99.0.1` host back to `unraid.internal`/`pgbouncer`/`postgres`, then `docker start pgbouncer immich-server` on tower.
- **Old stack**: keep `postgres18`, `pgbouncer`, `pgadmin4`, `databasus` on tower stopped but intact until the migration is confirmed stable over the agreed observation window.

- [ ] **Step 5: Commit the migration notes**

```bash
git add docs/superpowers/plans/2026-09-03-postgres-stack-migration.md docs/superpowers/migration-artifacts 2>/dev/null
git commit -m "docs(migration): postgres stack migration to talos-cloud-00 (complete)"
```

---

## Rollback (if any verification in Task 9 fails)

1. Revert each client DSN host back to its original value (reverse the `sed` from Task 8).
2. `ssh -i /root/ssh-keys/homelab-linux root@unraid.internal 'docker start pgbouncer immich-server'`.
3. Re-run Task 8's verification commands against the old host (`unraid.internal:5432` / `pgbouncer:5432` / `postgres`).
4. Leave the new talos-cloud-00 stack stopped until the issue is diagnosed.
