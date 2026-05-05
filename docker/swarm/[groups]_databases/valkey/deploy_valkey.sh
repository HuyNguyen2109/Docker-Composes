#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="valkey"
VALKEY_CONFIG="valkey-config"
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
# === Parse command-line arguments ===
SWARM_NODE_CODENAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node|--codename|-n)
      SWARM_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --node <SWARM_NODE_CODENAME>"
      log "Options:"
      log "  --node, --codename, -n    Specify the node codename (alpha, beta, gamma)"
      log "  -h, --help                Show this help message"
      log ""
      log "Example: $0 --node alpha"
      exit 0
      ;;
    *)
      err "❌ Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "$SWARM_NODE_CODENAME" ]; then
  err "❌ SWARM_NODE_CODENAME is required."
  err "Usage: $0 --node <SWARM_NODE_CODENAME>"
  err "Example: $0 --node alpha"
  exit 1
fi

log "🎯 Deploying stack to node codename: $SWARM_NODE_CODENAME"
# === Get secrets from Vault ===
log "🔐 Fetching secrets from Vault..."
VALKEY_AUTH_PASSWORD=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
export SWARM_NODE_CODENAME="$SWARM_NODE_CODENAME"
# === Create Docker Config via STDIN ===
log "Parsing all necessary variables into config..."
docker config rm $VALKEY_CONFIG >/dev/null 2>&1 || true
cat <<EOF | docker config create $VALKEY_CONFIG - >/dev/null 2>&1 || true
# valkey.conf - minimal config for production-like use

bind 0.0.0.0
protected-mode yes
requirepass $VALKEY_AUTH_PASSWORD

port 6379
daemonize no
supervised no

# Persistence
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# Optional: snapshotting (RDB)
save 900 1
save 300 10
save 60 10000

dir /data

# Memory limit
maxmemory 1024mb
maxmemory-policy allkeys-lru

# Logging
logfile ""
loglevel notice

EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach=true
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
