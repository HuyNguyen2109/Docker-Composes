# PostgreSQL Docker Swarm Deployments

## Directory Structure

```
postgres-swarm/
├── README.md
├── standalone/
│   ├── deploy_postgres.sh
│   └── docker-compose.yml
└── cluster/
    ├── deploy_postgres_ha.sh
    └── docker-compose.yml
```

---

## Standalone (Single Instance)

Single PostgreSQL instance with PgBouncer connection pooling.

### Usage
```bash
cd standalone/
./deploy_postgres.sh --node <codename>
```

### Stack Name
`postgres-cluster`

---

## Cluster (High Availability)

PostgreSQL cluster with 1 primary + 1 standby using streaming replication.

### Architecture
```
┌─────────────────────────────────────────────────────────┐
│                    Applications                          │
└──────────┬───────────────┬───────────────┬──────────────┘
           │               │               │
           ▼               ▼               ▼
   ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
   │   pgbouncer   │ │   pgbouncer   │ │   pgbouncer   │
   │   (session)   │ │ (transaction) │ │    (read)     │
   │  :5432 write  │ │  :5432 write  │ │  :5432 read   │
   └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
           │                 │                 │
           └────────┬────────┘                 │
                    ▼                          ▼
           ┌───────────────┐          ┌───────────────┐
           │   postgres    │ ──────▶  │   postgres    │
           │   (primary)   │streaming │   (standby)   │
           │  read-write   │replicat  │   read-only   │
           └───────────────┘          └───────────────┘
```

### Connection Endpoints

| Service | Host | Port | Mode | Use Case |
|---------|------|------|------|----------|
| pgbouncer-session | pgbouncer-session | 5432 | session | Authentik, Django apps |
| pgbouncer-transaction | pgbouncer-transaction | 5432 | transaction | Stateless apps |
| pgbouncer-read | pgbouncer-read | 5432 | transaction | Read-heavy workloads |
| postgres-primary | postgres-primary | 5432 | direct | Admin, migrations |
| postgres-standby | postgres-standby | 5432 | direct | Direct read queries |

### Prerequisites

1. **Node Labels**
   ```bash
   docker node update --label-add database=primary <primary-hostname>
   docker node update --label-add database=standby <standby-hostname>
   ```

2. **Vault Secret**
   - `postgres-root-password` (used for both postgres user and replicator user)

### Usage
```bash
cd cluster/
./deploy_postgres_ha.sh --primary alpha --standby beta
```

### Stack Name
`postgres-cluster-ha`

### Resource Limits

| Node | CPU | Memory |
|------|-----|--------|
| Primary | 2 cores | 8GB |
| Standby | 1 core | 2GB |

---

## Migration from Standalone to Cluster

1. Backup existing database
2. Stop standalone stack: `docker stack rm postgres-cluster`
3. Deploy cluster: `./deploy_postgres_ha.sh --primary alpha --standby beta`
4. Restore backup to primary
5. Update application connection strings

---

## Troubleshooting

### Check replication status (on primary)
```sql
SELECT application_name, client_addr, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

### Check if standby is in recovery mode
```sql
SELECT pg_is_in_recovery();
```

### View PgBouncer stats
```bash
docker exec -it <pgbouncer-container> psql -p 5432 -U postgres pgbouncer -c "SHOW POOLS;"
```
