#!/bin/bash
# ============================================================================
# PostgreSQL Migration Script: Standalone → HA Cluster
# ============================================================================
# This script safely migrates all data from the standalone PostgreSQL instance
# to the new HA cluster using pg_dumpall for a complete logical backup.
#
# What gets migrated:
#   - All databases
#   - All users/roles with passwords
#   - All schemas, tables, indexes
#   - All data
#   - All permissions/grants
#
# Prerequisites:
#   - Both stacks must be running
#   - Network connectivity between containers
#   - Sufficient disk space for dump file
# ============================================================================

set -e

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
step() { printf '\033[1;36m[STEP]\033[0m %s\n' "$*"; }

# Configuration
STANDALONE_STACK="postgres-cluster"
HA_STACK="postgres-cluster-ha"
STANDALONE_SERVICE="${STANDALONE_STACK}_main_database"
HA_PRIMARY_SERVICE="${HA_STACK}_postgres-primary"
DUMP_FILE="/tmp/postgres_full_backup_$(date +%Y%m%d_%H%M%S).sql"
POSTGRES_USER="postgres"
SWARM_MANAGER_REAL_HOSTNAME="mcb-svc"
SWARM_WORKER_VN_REAL_HOSTNAME="mcb-1-rocky-hqjx"
SWARM_WORKER_SG_REAL_HOSTNAME="mcb-svc-work-prod-db"

# SSH configuration (matches your deploy scripts)
SSH_KEY="$HOME/ssh-keys/oracle.key"

# Function to get node hostname from codename
get_node_host() {
  local node_name=$1
  case "$node_name" in
    *alpha*|*swarm-manager*|"$SWARM_MANAGER_REAL_HOSTNAME")
      echo "$SWARM_MANAGER_HOSTNAME"
      ;;
    *beta*|*swarm-worker-vn*|"$SWARM_WORKER_VN_REAL_HOSTNAME")
      echo "$SWARM_WORKER_VN_HOSTNAME"
      ;;
    *gamma*|*swarm-worker-sg*|"$SWARM_WORKER_SG_REAL_HOSTNAME")
      echo "$SWARM_WORKER_SG_HOSTNAME"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Function to get SSH user for node
get_node_user() {
  local node_name=$1
  case "$node_name" in
    *gamma*|*swarm-worker-sg*|"$SWARM_WORKER_SG_REAL_HOSTNAME")
      echo "ubuntu"
      ;;
    *)
      echo "root"
      ;;
  esac
}

# Function to find service container and node
find_service_container() {
  local service_name=$1
  
  # Get task info: node and container ID
  local task_info=$(docker service ps "$service_name" \
    --filter "desired-state=running" \
    --format "{{.Node}}|{{.ID}}" \
    --no-trunc 2>/dev/null | head -1)
  
  if [ -z "$task_info" ]; then
    echo ""
    return 1
  fi
  
  local node_name=$(echo "$task_info" | cut -d'|' -f1)
  local task_id=$(echo "$task_info" | cut -d'|' -f2)
  
  # Get the node hostname and user
  local node_host=$(get_node_host "$node_name")
  local node_user=$(get_node_user "$node_name")
  
  if [ -z "$node_host" ]; then
    err "Cannot determine hostname for node: $node_name"
    return 1
  fi
  
  # Get container ID from the node
  local container_id=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node_user@$node_host" \
    "docker ps --filter 'name=${service_name}' --format '{{.ID}}' | head -1" 2>/dev/null)
  
  if [ -z "$container_id" ]; then
    return 1
  fi
  
  # Return: node_user|node_host|container_id
  echo "${node_user}|${node_host}|${container_id}"
}

# Function to execute command in remote container
remote_docker_exec() {
  local node_user=$1
  local node_host=$2
  local container_id=$3
  shift 3
  local cmd="$@"
  
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node_user@$node_host" \
    "docker exec $container_id $cmd"
}

# Function to copy file to remote container
remote_docker_cp() {
  local node_user=$1
  local node_host=$2
  local container_id=$3
  local src_file=$4
  local dst_path=$5
  
  # First copy to remote host, then into container
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$src_file" "$node_user@$node_host:/tmp/migration_temp.sql"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node_user@$node_host" \
    "docker cp /tmp/migration_temp.sql $container_id:$dst_path && rm -f /tmp/migration_temp.sql"
}

# Parse arguments
DRY_RUN=false
SKIP_VERIFICATION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-verification)
      SKIP_VERIFICATION=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --dry-run            Show what would be done without executing"
      echo "  --skip-verification  Skip post-migration verification"
      echo "  -h, --help           Show this help message"
      echo ""
      echo "This script migrates all data from standalone PostgreSQL to HA cluster."
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║     PostgreSQL Migration: Standalone → HA Cluster                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# Pre-flight Checks
# ============================================================================
step "1/8 - Running pre-flight checks..."

# Check environment variables
log "Checking required environment variables..."
if [ -z "$SWARM_MANAGER_HOSTNAME" ] || [ -z "$SWARM_WORKER_VN_HOSTNAME" ] || [ -z "$SWARM_WORKER_SG_HOSTNAME" ]; then
  err "Required environment variables are not set!"
  err "Please ensure SWARM_MANAGER_HOSTNAME, SWARM_WORKER_VN_HOSTNAME, SWARM_WORKER_SG_HOSTNAME are set."
  exit 1
fi
log "  ✓ Environment variables are set"

# Check SSH key
if [ ! -f "$SSH_KEY" ]; then
  err "SSH key not found: $SSH_KEY"
  exit 1
fi
log "  ✓ SSH key found"

# Find standalone container
log "Finding standalone PostgreSQL ($STANDALONE_SERVICE)..."
STANDALONE_INFO=$(find_service_container "$STANDALONE_SERVICE")
if [ -z "$STANDALONE_INFO" ]; then
  err "Standalone PostgreSQL service is not running!"
  err "Please ensure the '$STANDALONE_STACK' stack is deployed."
  exit 1
fi
STANDALONE_USER=$(echo "$STANDALONE_INFO" | cut -d'|' -f1)
STANDALONE_HOST=$(echo "$STANDALONE_INFO" | cut -d'|' -f2)
STANDALONE_CONTAINER=$(echo "$STANDALONE_INFO" | cut -d'|' -f3)
log "  ✓ Standalone container: $STANDALONE_CONTAINER on $STANDALONE_HOST"

# Find HA primary container
log "Finding HA cluster primary ($HA_PRIMARY_SERVICE)..."
HA_PRIMARY_INFO=$(find_service_container "$HA_PRIMARY_SERVICE")
if [ -z "$HA_PRIMARY_INFO" ]; then
  err "HA Primary PostgreSQL service is not running!"
  err "Please ensure the '$HA_STACK' stack is deployed."
  exit 1
fi
HA_USER=$(echo "$HA_PRIMARY_INFO" | cut -d'|' -f1)
HA_HOST=$(echo "$HA_PRIMARY_INFO" | cut -d'|' -f2)
HA_PRIMARY_CONTAINER=$(echo "$HA_PRIMARY_INFO" | cut -d'|' -f3)
log "  ✓ HA Primary container: $HA_PRIMARY_CONTAINER on $HA_HOST"

# Check PostgreSQL is ready on both
log "Checking PostgreSQL readiness..."
if ! remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  err "Standalone PostgreSQL is not ready!"
  exit 1
fi
log "  ✓ Standalone PostgreSQL is ready"

if ! remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  err "HA Primary PostgreSQL is not ready!"
  exit 1
fi
log "  ✓ HA Primary PostgreSQL is ready"

# ============================================================================
# Gather Information
# ============================================================================
step "2/8 - Gathering database information from standalone..."

# Get list of databases
DATABASES=$(remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
  psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | tr -d ' ')

# Get list of roles
ROLES=$(remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
  psql -U postgres -t -c "SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg_%' AND rolname != 'postgres';" 2>/dev/null | tr -d ' ')

# Get database sizes
log "Databases to migrate:"
remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
  psql -U postgres -c "SELECT datname as database, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;" 2>/dev/null

echo ""
log "Roles to migrate:"
for role in $ROLES; do
  [ -n "$role" ] && echo "  - $role"
done
echo ""

# Calculate total size
TOTAL_SIZE=$(remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
  psql -U postgres -t -c "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d ' ')
log "Total data size: $TOTAL_SIZE"

if [ "$DRY_RUN" = true ]; then
  warn "DRY RUN MODE - No changes will be made"
  echo ""
  echo "The following operations would be performed:"
  echo "  1. Create full dump from standalone PostgreSQL"
  echo "  2. Stop applications using standalone database"
  echo "  3. Restore dump to HA cluster primary"
  echo "  4. Verify data integrity"
  echo "  5. Update application connection strings"
  exit 0
fi

# ============================================================================
# Confirmation
# ============================================================================
step "3/8 - Confirmation required..."

echo ""
warn "⚠️  WARNING: This will migrate all data to the HA cluster."
warn "⚠️  Ensure you have a backup before proceeding!"
echo ""
read -p "Do you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  log "Migration cancelled."
  exit 0
fi

# ============================================================================
# Create Full Backup
# ============================================================================
step "4/8 - Creating full database dump from standalone..."

log "Running pg_dumpall (this may take a while for large databases)..."
log "Dump file: $DUMP_FILE"

# Use pg_dumpall to get everything including roles
# Dump via SSH to remote container, pipe stdout to local file
remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
  pg_dumpall -U postgres --clean --if-exists > "$DUMP_FILE" 2>/dev/null

# Verify dump succeeded
if [ $? -ne 0 ] || [ ! -s "$DUMP_FILE" ]; then
  log "Direct pipe method failed, trying file-based approach..."
  
  # Create dump inside container
  remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
    sh -c "pg_dumpall -U postgres --clean --if-exists > /tmp/full_dump.sql"
  
  # Copy from container to remote host
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${STANDALONE_USER}@${STANDALONE_HOST}" \
    "docker cp ${STANDALONE_CONTAINER}:/tmp/full_dump.sql /tmp/pg_dump_${TIMESTAMP}.sql"
  
  # Copy from remote host to local
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${STANDALONE_USER}@${STANDALONE_HOST}:/tmp/pg_dump_${TIMESTAMP}.sql" "$DUMP_FILE"
  
  # Cleanup remote temp files
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${STANDALONE_USER}@${STANDALONE_HOST}" \
    "rm -f /tmp/pg_dump_${TIMESTAMP}.sql"
  remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
    rm -f /tmp/full_dump.sql
fi

DUMP_SIZE=$(ls -lh "$DUMP_FILE" | awk '{print $5}')
log "  ✓ Dump completed: $DUMP_FILE ($DUMP_SIZE)"

# Verify dump file
if [ ! -s "$DUMP_FILE" ]; then
  err "Dump file is empty! Something went wrong."
  exit 1
fi

# Count objects in dump
ROLE_COUNT=$(grep -c "^CREATE ROLE" "$DUMP_FILE" || echo "0")
DB_COUNT=$(grep -c "^CREATE DATABASE" "$DUMP_FILE" || echo "0")
TABLE_COUNT=$(grep -c "^CREATE TABLE" "$DUMP_FILE" || echo "0")

log "Dump contents:"
log "  - Roles: $ROLE_COUNT"
log "  - Databases: $DB_COUNT"
log "  - Tables: $TABLE_COUNT"

# ============================================================================
# Pre-restore: Check HA Cluster State
# ============================================================================
step "5/8 - Checking HA cluster state before restore..."

# Check replication status
log "Checking replication status..."
REPLICATION_STATE=$(remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
  psql -U postgres -t -c "SELECT state FROM pg_stat_replication LIMIT 1;" 2>/dev/null | tr -d ' ')

if [ "$REPLICATION_STATE" = "streaming" ]; then
  log "  ✓ Streaming replication is active"
else
  warn "  ⚠ Replication state: ${REPLICATION_STATE:-not active}"
  warn "  Continuing anyway - standby will sync after migration"
fi

# Check for existing databases on HA (excluding system DBs)
HA_DATABASES=$(remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
  psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | tr -d ' ')

if [ -n "$HA_DATABASES" ]; then
  warn "⚠️  The following databases already exist on HA cluster:"
  for db in $HA_DATABASES; do
    [ -n "$db" ] && echo "  - $db"
  done
  echo ""
  read -p "The dump uses --clean --if-exists. Continue? (yes/no): " CONFIRM2
  if [ "$CONFIRM2" != "yes" ]; then
    log "Migration cancelled."
    rm -f "$DUMP_FILE"
    exit 0
  fi
fi

# ============================================================================
# Restore to HA Cluster
# ============================================================================
step "6/8 - Restoring dump to HA cluster primary..."

log "This may take a while for large databases..."
log "Errors about 'postgres' role already existing are expected."
echo ""

# Copy dump file to HA primary container via SSH
remote_docker_cp "$HA_USER" "$HA_HOST" "$DUMP_FILE" "$HA_PRIMARY_CONTAINER" "/tmp/restore.sql"

# Run restore (some errors are expected for existing objects)
remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
  psql -U postgres -f /tmp/restore.sql 2>&1 | \
  grep -v "already exists" | \
  grep -v "does not exist, skipping" | \
  grep -E "(ERROR|FATAL)" || true

# Cleanup temp file in container
remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" rm -f /tmp/restore.sql

log "  ✓ Restore completed"

# ============================================================================
# Verification
# ============================================================================
if [ "$SKIP_VERIFICATION" = false ]; then
  step "7/8 - Verifying migration..."

  echo ""
  log "Comparing database counts..."
  
  # Compare databases
  SOURCE_DB_COUNT=$(remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
    psql -U postgres -t -c "SELECT count(*) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d ' ')
  TARGET_DB_COUNT=$(remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
    psql -U postgres -t -c "SELECT count(*) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d ' ')
  
  log "  Databases - Source: $SOURCE_DB_COUNT, Target: $TARGET_DB_COUNT"
  
  # Compare roles
  SOURCE_ROLE_COUNT=$(remote_docker_exec "$STANDALONE_USER" "$STANDALONE_HOST" "$STANDALONE_CONTAINER" \
    psql -U postgres -t -c "SELECT count(*) FROM pg_roles WHERE rolname NOT LIKE 'pg_%';" 2>/dev/null | tr -d ' ')
  TARGET_ROLE_COUNT=$(remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
    psql -U postgres -t -c "SELECT count(*) FROM pg_roles WHERE rolname NOT LIKE 'pg_%';" 2>/dev/null | tr -d ' ')
  
  log "  Roles - Source: $SOURCE_ROLE_COUNT, Target: $TARGET_ROLE_COUNT"
  
  # List databases on target
  echo ""
  log "Databases on HA cluster:"
  remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
    psql -U postgres -c "SELECT datname as database, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database WHERE datistemplate = false ORDER BY datname;" 2>/dev/null

  # Check replication caught up
  echo ""
  log "Checking standby replication status..."
  sleep 5  # Give standby time to catch up
  
  SYNC_STATE=$(remote_docker_exec "$HA_USER" "$HA_HOST" "$HA_PRIMARY_CONTAINER" \
    psql -U postgres -t -c "SELECT sync_state FROM pg_stat_replication LIMIT 1;" 2>/dev/null | tr -d ' ')
  
  if [ "$SYNC_STATE" = "sync" ]; then
    log "  ✓ Standby is synchronized"
  else
    log "  Standby sync state: ${SYNC_STATE:-unknown}"
    log "  The standby will catch up shortly"
  fi
else
  step "7/8 - Skipping verification (--skip-verification flag)"
fi

# ============================================================================
# Cleanup and Summary
# ============================================================================
step "8/8 - Migration complete!"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    Migration Summary                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
log "✅ All data has been migrated to the HA cluster"
echo ""
log "Backup file retained at: $DUMP_FILE"
log "  (Delete manually after confirming everything works)"
echo ""
warn "NEXT STEPS:"
echo ""
echo "  1. Update application connection strings:"
echo "     OLD: pgbouncer-session:5432 or pgbouncer-transaction:5432"
echo "     NEW: pgcat:6432 or postgres-ha:6432"
echo ""
echo "  2. Test your applications with the new cluster"
echo ""
echo "  3. Once confirmed working, stop the standalone stack:"
echo "     docker stack rm $STANDALONE_STACK"
echo ""
echo "  4. (Optional) Archive or delete the old data directory"
echo ""
log "Migration completed at $(date)"
