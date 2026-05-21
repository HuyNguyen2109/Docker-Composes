#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="authentik-prd"
SERVER_SWARM_NODE_CODENAME=""
WORKER_SWARM_NODE_CODENAME=""
# === Check if codename has been passed as argument ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-node)
      SERVER_SWARM_NODE_CODENAME="$2"
      shift 2
      ;;
    --worker-node)
      WORKER_SWARM_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --server-node <SERVER_SWARM_NODE_CODENAME> --worker-node <WORKER_SWARM_NODE_CODENAME>"
      log "Options:"
      log "  --server-node    Specify the server node codename (alpha, beta, gamma)"
      log "  --worker-node    Specify the worker node codename (alpha, beta, gamma)"
      log "  -h, --help       Show this help message"
      log ""
      log "Example: $0 --server-node alpha --worker-node beta"
      exit 0
      ;;
    *)
      err "❌ Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "$SERVER_SWARM_NODE_CODENAME" ]; then
  err "❌ SERVER_SWARM_NODE_CODENAME is required."
  err "Usage: $0 --node <SERVER_SWARM_NODE_CODENAME>"
  err "Example: $0 --node alpha"
  exit 1
fi
if [ -z "$WORKER_SWARM_NODE_CODENAME" ]; then
  err "❌ WORKER_SWARM_NODE_CODENAME is required."
  err "Usage: $0 --worker-node <WORKER_SWARM_NODE_CODENAME>"
  err "Example: $0 --worker-node beta"
  exit 1
fi
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Vault CLI is installed ===
log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "❌ Vault CLI is not installed!"
    exit 1
fi
log "Checking Vault credentials for Vault..."
REQUIRED_VARS=(
  VAULT_ADDR
  VAULT_TOKEN
)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    err "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Get secrets from Vault ===
log "🔐 Fetching secrets from Vault..."
log "Testing Vault connectivity at $VAULT_ADDR..."
export VAULT_CLIENT_TIMEOUT=30s
export VAULT_MAX_RETRIES=3
if ! timeout 30 vault status >/dev/null 2>&1; then
    err "❌ Cannot connect to Vault at $VAULT_ADDR (timeout after 30s)"
    err "Vault resolves to: $(host vault.mcb-svc.work 2>/dev/null | grep 'has address' || echo 'DNS lookup failed')"
    err "This machine may not have network access to Vault on port 443"
    err "Possible solutions: 1) Check firewall rules 2) Use VPN/SSH tunnel 3) Run from authorized network"
    exit 1
fi
log "✓ Vault is reachable"
export S3_ACCESS_KEY_ID=$(vault kv get -field=s3-client-id kubernetes/docker-secrets)
export S3_SECRET_ACCESS_KEY=$(vault kv get -field=s3-client-secret kubernetes/docker-secrets)
export S3_ENDPOINT="https://$(vault kv get -field=s3-endpoint kubernetes/docker-secrets)"
export S3_REGION="us-east"
export S3_BUCKET="McBourdeux-NAS-Backup"
export S3_PREFIX="authentik-db-backup-prd"
export PG_PASS=$(vault kv get -field=authentik-db-password kubernetes/docker-secrets)
export AUTHENTIK_SECRET_KEY=$(vault kv get -field=authentik-secret-key kubernetes/docker-secrets)
export AUTHENTIK_OUTPOST_TOKEN=$(vault kv get -field=authentik-outpost-token kubernetes/docker-secrets)
export PG_HOST="pgbouncer-session"
export PG_DB="authentik_db"
export PG_USER="authentik_admin"
# Read replicas should bypass PgBouncer and connect directly to PostgreSQL
# This reduces pool contention since reads don't need pooling as critically
export REPLICA_0_HOST="postgres"
export UI_URL="auth.mcb-svc.work"
export AUTHENTIK_TAG="2025.12.0"
# Set to 0 to release connections immediately back to pool (critical for session mode)
export PG_CONN_MAX="0"
export SERVER_SWARM_NODE_CODENAME=$SERVER_SWARM_NODE_CODENAME
export WORKER_SWARM_NODE_CODENAME=$WORKER_SWARM_NODE_CODENAME
export AUTHENTIK_PUBLIC_URL="auth.mcb-svc.work"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
