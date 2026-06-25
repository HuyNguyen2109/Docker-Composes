# PostgreSQL Database & Owner Migration Script

**Date**: 2026-06-22

## Purpose

Migrate a specific PostgreSQL database and its owner role from one Postgres instance to another, using default superuser credentials provided via CLI.

## Use Case

- **Source**: `lb.internal:5432` (existing Postgres, default creds `postgres`/`P4ssw0rd!!!`)
- **Destination**: `unraid.internal:5432` (new Postgres, same default creds)
- **Target DB**: `vault-data` with owner `vault-admin`
- The script must be reusable for any database/owner/host combination

## Requirements

1. Migrate the full database (schemas, data, extensions)
2. Migrate the owner role (attributes, password, memberships)
3. CLI-driven: `--db`, `--owner`, `--target` (source), `--dest` (destination), `--user`, `--pass`
4. Support `--dry-run` mode
5. Verify migration success after restore
6. Non-interactive (password via CLI/env, not prompt)

## Approach: pg_dumpall globals + pg_dump custom

### Why This Approach

- **Standard DBA pattern** — used by the existing `migrate_standalone_to_cluster.sh` in this repo
- **Clean separation** — roles restored before database, avoiding ownership errors
- **Custom format** (`pg_dump --format=custom`) supports parallel restore with `--jobs`
- **Single-file database dump** is easy to transfer if needed

### Pipeline

1. **Pre-flight checks**
   - Verify `pg_dump`, `psql`, `pg_restore` are available
   - Test TCP connectivity to both `$TARGET_HOST` and `$DEST_HOST`
   - Verify database `$DB` exists on source
   - Verify owner role `$OWNER` exists on source

2. **Export roles** via `pg_dumpall --globals-only`
   - Captures all roles (including `$OWNER` with password, login privileges, etc.)
   - Output: `roles.sql`

3. **Export database** via `pg_dump --format=custom -j4`
   - Includes all schemas, data, extensions, ownership
   - Output: `$DB.dump` (compressed, parallel-restore capable)

4. **Import roles** on destination via `psql -f roles.sql`
   - Creates `$OWNER` and any other roles
   - Ignores "already exists" errors for built-in roles with `ON CONFLICT DO NOTHING` equivalent

5. **Create database** on destination if it doesn't exist
   - `CREATE DATABASE $DB OWNER $OWNER;`

6. **Restore database** via `pg_restore --format=custom -j4 -d $DB`
   - Parallel restore using 4 jobs
   - Handles circular dependencies automatically

7. **Verify migration**
   - Connect as `$OWNER` to `$DB` on destination
   - Run `\dt` and row count on a known table
   - Compare table counts between source and destination

### Error Handling

- All steps logged with timestamps
- Non-fatal errors tracked, script continues where possible
- Exit on connectivity failure
- Rollback is manual (destroy destination DB) — user must verify before cutting over

### CLI Interface

```bash
./migrate-postgres.sh \
  --db vault-data \
  --owner vault-admin \
  --target lb.internal:5432 \
  --dest unraid.internal:5432 \
  --user postgres \
  --pass 'P4ssw0rd!!!' \
  [--dry-run]
```

Environment variable fallback: `PGPASSWORD` (standard Postgres env var).

### Dependencies

- `postgresql-client` (provides `pg_dump`, `psql`, `pg_restore`)
- TCP access to both Postgres hosts (port 5432)
- Superuser privileges on both instances

### Verification

After restore, the script will:
1. Connect to the destination as `$OWNER` and list tables
2. Compare table count between source and destination
3. Exit with code 0 on success, non-zero on failure
