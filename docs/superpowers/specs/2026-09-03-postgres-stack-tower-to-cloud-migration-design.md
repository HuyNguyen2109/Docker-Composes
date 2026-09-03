# PostgreSQL Stack Migration: tower.local → talos-cloud-00

**Date**: 2026-09-03

## Purpose

Move the entire standalone PostgreSQL stack (PostgreSQL, PgBouncer, pgAdmin4, Databasus)
from the unRAID host `tower.local` to the cloud VM `talos-cloud-00`, without breaking
data consistency or the live connections from dependent applications.

## Current State (Source: tower.local)

- **Host**: `tower.local` (a.k.a. `unraid.internal`, `192.168.1.40`), unRAID 7.x
- **Compose project**: `postgresql`, config at
  `/mnt/user/appdata/arcane/projects/PostgreSQL/compose.yaml`
  (this is the compose.manager `PROJECTS_FOLDER` "Arcane project directory")
- **Networks** (external bridges): `db-intranet`, `traefik-intranet`

### Services in the stack

| Service | Container | Image | Ports | Data volume (`MASTER_DIR=/mnt/user/appdata/docker-stack-data/postgres`) |
|---|---|---|---|---|
| postgres | `postgres18` | `pgvector/pgvector:pg18-trixie` | internal `5432` only | `postgres-data` (1.5 GB) → `/var/lib/postgresql` |
| pgbouncer | `pgbouncer` | `edoburu/pgbouncer:v1.25.2-p0` | host `5432:5432` | `pgbouncer/` (pgbouncer.ini + userlist.txt) |
| pgadmin4 | `pgadmin4` | `dpage/pgadmin4:9.16` | host `3000:80` | `pgadmin4/` |
| databasus | `databasus` | `databasus/databasus:latest` | host `4005:4005` | `databasus/` (own embedded PG + WAL queue + `secret.key`) |

### Database contents

- **Databases (7)**: `benchmarkdb`, `immichdb`, `kanbn`, `pocketid-db`, `postgres`,
  `vault-data`, `zitadel`
- **Login roles (11)**: `postgres` (superuser), `immichdb-admin` (superuser),
  `vault-admin`, `zitadel-admin`, `kanbn-admin`, `immich-db-admin`,
  `pocketid-db-admin`, `authentik-db-admin`, `harbor-db-admin`, `replicator`,
  `databasus-2629d39f`
- **Extensions**: `pgvector` (image is pgvector-enabled)
- **PgBouncer**: session pooling; `auth_type = scram-sha-256`; dynamic auth via
  `auth_query` against `pg_shadow` (any existing PG role can log in); 4 static
  users in `userlist.txt` (`postgres`, `vault-admin`, `zitadel-admin`, `kanbn-admin`)
- **Databasus backup**: continuous physical WAL streaming of `postgres18` via the
  `replicator` role + replication slot `databasus_slot_*`; WAL queue under
  `databasus/backups/wal-queue/`; **S3 offsite backup to `s3.mcb-homelab.com`**

### Live clients (must be repointed)

| Client | Host | Database | Role | Current DSN / target |
|---|---|---|---|---|
| Zitadel | talos-cloud-00 | `zitadel` | `zitadel-admin` | `postgresql://zitadel-admin:***@unraid.internal:5432/zitadel?sslmode=disable` |
| Kanbn | talos-cloud-00 | `kanbn` | `kanbn-admin` | `POSTGRES_URL=postgres://kanbn-admin:***@unraid.internal:5432/kanbn` |
| Vault | tower | `vault-data` | `vault-admin` | `postgres://vault-admin:***@pgbouncer:5432/vault-data` (via pgbouncer) |
| Immich | tower | `immichdb` | `immichdb-admin` (superuser) | `DB_HOSTNAME=postgres` (direct to postgres18, not pgbouncer) |

> Immich connects **directly** to postgres18 (hostname `postgres` on `db-intranet`),
> using the superuser `immichdb-admin`. It must be repointed to the new PgBouncer
> (or a direct new endpoint) over the overlay. The role `immich-db-admin` also
> exists but is not used by the running container.

> Authentik / Harbor / PocketID roles exist but have **no databases** on this
> instance — those apps run on in-k8s CloudNativePG and are out of scope.

## Target State (Destination: talos-cloud-00)

- **Host**: `talos-cloud-00` (`14.225.220.145`), Ubuntu, Docker 29.7.2, no swarm
- **Resources**: 58 GB root (48 GB free), 5.8 GB RAM (≈3.9 GB available)
- **Compose projects dir**: `/mnt/nfs-server.d/docker-share/arcane/projects/`
  (same "Arcane projects" convention, on the NFS share)
- **Networks to create**: `db-intranet` (bridge) for postgres↔pgbouncer↔databasus;
  databasus' `traefik-intranet` attachment is dropped (host-port exposed, and
  talos-cloud-00 routes via its `proxy`/caddy network instead of traefik)

### Overlay connectivity (already present)

| Interface | tower.local | talos-cloud-00 |
|---|---|---|
| WireGuard `wg0` | `10.99.0.2` | `10.99.0.1` |
| Netbird `wt0` | `100.88.194.85` | `100.88.0.70` |

- `talos-cloud-00 → 192.168.1.40:5432` works today (route `192.168.1.0/24 dev wg0`).
- `tower → talos-cloud-00` works over SSH (22) and via `10.99.0.1` / `100.88.0.70`.
- After cutover, tower clients reach the new PgBouncer at `10.99.0.1:5432`
  (WireGuard) or `100.88.0.70:5432` (Netbird) — **no public port opened**.

## Approach

Physical clone via `pg_basebackup`, with logical + offsite safety nets, then full
stack move and client repoint. Data consistency and live connections are the top
priority, so the old stack stays running and untouched until every verification
passes.

### 1. Data migration (physical, consistent)

1. `pg_basebackup -F t -z -X fetch` from `postgres18` (via existing `replicator`
   role; fallback `postgres` superuser) → compressed tar of the whole cluster.
2. Transfer to talos-cloud-00 over SSH (both hosts mutually reachable on 22).
3. Restore into the new `postgres18` container (same `pgvector/pgvector:pg18-trixie`
   image, empty PGDATA) → it becomes the new primary.

### 2. Safety nets (data-consistency first)

- **S3**: existing Databasus offsite backup at `s3.mcb-homelab.com` (unchanged).
- **Logical export**: a `pg_dumpall` (roles + globals) + per-DB `pg_dump` taken at
  cutover as an independent second copy (kept on tower and copied to talos-cloud-00).
- **Rollback**: old tower stack remains running; cutover is a repoint, so rollback
  = revert connection strings.

### 3. Full stack move (all 4 services)

- Reproduce `compose.yaml` + `.env` under
  `/mnt/nfs-server.d/docker-share/arcane/projects/PostgreSQL/` on talos-cloud-00.
- Migrate `pgbouncer/`, `pgadmin4/`, and `databasus/` data dirs.
- Databasus: copy its full data dir (embedded `pgdata`, `secret.key`, `instance.json`,
  WAL queue) so its S3 backup jobs survive; re-point its managed instance to the new
  postgres and recreate the replication slot on the new primary.

### 4. mTLS on new PgBouncer (self-signed CA)

- Generate a CA, a server cert for PgBouncer (SANs: `localhost`, `pgbouncer`,
  `127.0.0.1`, `10.99.0.1`, `100.88.0.70`), and one client cert per app.
- PgBouncer (`edoburu/pgbouncer`) TLS: `client_tls_sslmode = verify-full`,
  `client_tls_ca_file`, `server_tls_cert_file`, `server_tls_key_file`.
- Clients connect with `sslmode=verify-full` + `sslrootcert` + `sslcert` + `sslkey`.

### 5. Cutover & verification

1. Repoint the 4 clients to the new PgBouncer (with their client certs).
2. Verify each app can connect (per-app health/read query) and PgBouncer
   `SHOW POOLS` / `SHOW STATS` shows active sessions.
3. Keep old stack running as instant rollback until all green (user step 8).

## Non-Goals

- Not migrating Authentik / Harbor / PocketID (no DBs on this instance).
- Not touching the existing S3 backup endpoint or its storage.
- Not enabling public (internet) access to Postgres — private overlay only.
- Not changing Postgres version or image tag.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Data loss during clone | Physical basebackup is transactionally consistent; verify with row counts + `pg_dumpall` diff before cutover |
| Broken app connections at cutover | Repoint one client at a time; keep old PgBouncer up for instant rollback |
| mTLS config mismatch | Validate TLS handshake with `psql sslmode=verify-full` before switching app DSNs |
| Databasus loses backup config | Copy full `databasus/` dir including embedded PG + `secret.key`; re-verify S3 job after move |
| RAM pressure on target (5.8 GB) | Reduce `mem_limit` for pgadmin4/databasus on the new host if needed; monitor |
