#!/bin/bash
set -e

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
step() { printf '\033[1;36m[STEP]\033[0m  %s\n' "$*"; }

usage() {
  cat <<EOF
Migrate a PostgreSQL database and its owner role from one host to another.

Usage: $(basename "$0") [OPTIONS]

Required:
  --db NAME         Database name (e.g. vault-data)
  --owner NAME      Owner role name (e.g. vault-admin)
  --target HOST     Source Postgres host:port (e.g. lb.internal:5432)
  --dest HOST       Destination Postgres host:port (e.g. unraid.internal:5432)
  --user NAME       Default superuser (e.g. postgres)
  --pass PASSWORD   Default superuser password

Options:
  --dry-run         Print commands without executing
  -h, --help        Show this help

Environment variable fallback: PGPASSWORD
EOF
  exit 0
}

DB=""
OWNER=""
TARGET=""
DEST=""
PGUSER=""
PGPASSWORD=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)    DB="$2";    shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --dest)  DEST="$2";  shift 2 ;;
    --user)  PGUSER="$2"; shift 2 ;;
    --pass)  PGPASSWORD="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

MISSING=""
[[ -z "$DB" ]]      && MISSING="$MISSING --db"
[[ -z "$OWNER" ]]   && MISSING="$MISSING --owner"
[[ -z "$TARGET" ]]  && MISSING="$MISSING --target"
[[ -z "$DEST" ]]    && MISSING="$MISSING --dest"
[[ -z "$PGUSER" ]]  && MISSING="$MISSING --user"
if [[ -n "$MISSING" ]]; then
  err "Missing required arguments:$MISSING"
  usage
fi

[[ -z "$PGPASSWORD" && -z "${PGPASSWORD:-}" ]] && {
  err "Password required via --pass or PGPASSWORD env var"
  usage
}

export PGPASSWORD

split_hostport() {
  local val="$1" _h _p
  if [[ "$val" == *":"* ]]; then
    _h="${val%%:*}"
    _p="${val##*:}"
  else
    _h="$val"
    _p="5432"
  fi
  echo "$_h"
  echo "$_p"
}

TARGET_HOST=$(split_hostport "$TARGET" | sed -n '1p')
TARGET_PORT=$(split_hostport "$TARGET" | sed -n '2p')
DEST_HOST=$(split_hostport "$DEST" | sed -n '1p')
DEST_PORT=$(split_hostport "$DEST" | sed -n '2p')

log "Target:   ${TARGET_HOST}:${TARGET_PORT}"
log "Dest:     ${DEST_HOST}:${DEST_PORT}"

TODAY=$(date +%Y%m%d_%H%M%S)
WORKDIR="/tmp/pg-migrate-${TODAY}"
ROLES_FILE="${WORKDIR}/roles.sql"
DUMP_FILE="${WORKDIR}/${DB}.dump"

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    DRY-RUN: $*"
  else
    "$@"
  fi
}

cleanup() {
  [[ -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---- Pre-flight ----
step "Pre-flight checks"
for cmd in pg_dump pg_dumpall psql pg_restore; do
  command -v "$cmd" &>/dev/null || { err "$cmd not found"; exit 1; }
done

mkdir -p "$WORKDIR"

# Test connectivity to target (source)
log "Testing connectivity to target (source): $TARGET"
if ! run psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" -d postgres -c "SELECT 1 AS ok" &>/dev/null; then
  err "Cannot connect to target (source) at ${TARGET_HOST}:${TARGET_PORT}"
  exit 1
fi

# Test connectivity to destination
log "Testing connectivity to destination: $DEST_HOST:$DEST_PORT"
if ! run psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d postgres -c "SELECT 1 AS ok" &>/dev/null; then
  err "Cannot connect to destination at ${DEST_HOST}:${DEST_PORT}"
  exit 1
fi

# Verify database exists on source
log "Verifying database '$DB' exists on source"
DB_EXISTS=$(psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" -d postgres -Atc \
  "SELECT 1 FROM pg_database WHERE datname = '${DB}'" 2>/dev/null || true)
if [[ "$DB_EXISTS" != "1" ]]; then
  err "Database '$DB' does not exist on target (source)"
  exit 1
fi

# Verify owner exists on source
log "Verifying owner role '$OWNER' exists on source"
OWNER_EXISTS=$(psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" -d postgres -Atc \
  "SELECT 1 FROM pg_roles WHERE rolname = '${OWNER}'" 2>/dev/null || true)
if [[ "$OWNER_EXISTS" != "1" ]]; then
  err "Owner role '$OWNER' does not exist on target (source)"
  exit 1
fi

# ---- Export globals (roles) ----
step "Exporting roles from target (source)"
log "Dumping all roles to: $ROLES_FILE"
run pg_dumpall --globals-only \
  -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" \
  -f "$ROLES_FILE"
log "Roles exported ($(wc -l < "$ROLES_FILE") lines)"

# ---- Export database ----
step "Exporting database '$DB' from target (source)"
log "Dumping database '$DB' to: $DUMP_FILE"
run pg_dump --format=custom \
  -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" \
  -d "$DB" \
  -f "$DUMP_FILE"
log "Database exported ($(du -h "$DUMP_FILE" | cut -f1))"

# ---- Import roles on destination ----
step "Importing roles to destination"
log "Restoring roles to: $DEST"
# Strip postgres role to avoid password desync with connection poolers
FILTERED_ROLES="${WORKDIR}/roles-filtered.sql"
sed '/^ALTER ROLE postgres\b/d; /^CREATE ROLE postgres\b/d' "$ROLES_FILE" > "$FILTERED_ROLES"
run psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d postgres -f "$FILTERED_ROLES" 2>&1 | \
  grep -v "already exists" | grep -v "NOTICE" || true
log "Roles restored"

# ---- Create database if needed ----
step "Ensuring database '$DB' exists on destination"
DB_ON_DEST=$(psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d postgres -Atc \
  "SELECT 1 FROM pg_database WHERE datname = '${DB}'" 2>/dev/null || true)
if [[ "$DB_ON_DEST" != "1" ]]; then
  log "Creating database '$DB' with owner '$OWNER'"
  run psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d postgres \
    -c "CREATE DATABASE \"${DB}\" OWNER \"${OWNER}\";"
else
  log "Database '$DB' already exists on destination, skipping creation"
fi

# ---- Restore database data ----
step "Restoring database '$DB' to destination"
log "Running pg_restore on: $DEST"
run pg_restore --format=custom --jobs=4 \
  -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" \
  -d "$DB" \
  "$DUMP_FILE"
log "Database restored"

# ---- Verification ----
step "Verifying migration"

log "Listing tables in '$DB' on destination:"
run psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d "$DB" -c "\dt" 2>/dev/null || \
  warn "Could not list tables (owner $OWNER may have different permissions)"

SOURCE_TABLE_COUNT=$(psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$PGUSER" -d "$DB" -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')" 2>/dev/null || echo "0")
DEST_TABLE_COUNT=$(psql -h "$DEST_HOST" -p "$DEST_PORT" -U "$PGUSER" -d "$DB" -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')" 2>/dev/null || echo "0")

log "Source tables: $SOURCE_TABLE_COUNT"
log "Destination tables: $DEST_TABLE_COUNT"

if [[ "$SOURCE_TABLE_COUNT" != "$DEST_TABLE_COUNT" ]]; then
  warn "Table count mismatch! Source=$SOURCE_TABLE_COUNT, Dest=$DEST_TABLE_COUNT"
else
  log "Table count matches ($SOURCE_TABLE_COUNT tables)"
fi

# ---- Summary ----
echo ""
echo "============================================"
log "Migration Summary"
echo "  Database:     $DB"
echo "  Owner:        $OWNER"
echo "  Source:       $TARGET"
echo "  Destination:  $DEST"
echo "  Status:       Completed"
if [[ "$SOURCE_TABLE_COUNT" == "$DEST_TABLE_COUNT" && "$SOURCE_TABLE_COUNT" != "0" ]]; then
  echo "  Result:       SUCCESS"
elif [[ "$SOURCE_TABLE_COUNT" == "0" ]]; then
  echo "  Result:       SUCCESS (empty database)"
else
  echo "  Result:       WARNING - table count mismatch"
fi
echo "============================================"

cleanup
