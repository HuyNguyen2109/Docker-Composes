#!/bin/bash

# Logging functions
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }

# Directory for PgDog configs
CONFIG_DIR="$(dirname "$0")/pgdog-configs"


# Create Docker configs for PgDog
docker config create pgdog-transaction-config - < "$CONFIG_DIR/pgdog-transaction.toml"  >/dev/null 2>&1 || true
docker config create pgdog-session-config - < "$CONFIG_DIR/pgdog-session.toml"  >/dev/null 2>&1 || true

log "Deploying stack..."
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "Docker stack '$STACK_NAME' deployed successfully!"
log ""
log "Architecture: App → PgDog (pooling + R/W split) → PostgreSQL"
log ""
log "Connection endpoints:"
log "  Single endpoint (recommended): pgdog:6432 or postgres-ha:6432"
log "  Direct primary (write):        postgres-primary:5432"
log "  Direct standby (read):         postgres-standby:5432"
log ""
log "Query routing (automatic via PgDog):"
log "  - SELECT queries → load balanced to replica"
log "  - INSERT/UPDATE/DELETE → primary"
log ""
log "Prometheus metrics: http://<any-manager>:9930/metrics"
