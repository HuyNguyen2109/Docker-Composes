#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
GPU_NODE_IP="192.168.1.9"
GPU_NODE_USER="ubuntu"
SSH_KEY="/root/ssh-keys/homelab-linux"
REMOTE_DIR="/opt/immich"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# === Check if Vault CLI is installed ===
log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "❌ Vault CLI is not installed!"
    exit 1
fi
log "Checking Vault credentials..."
REQUIRED_VARS=(VAULT_ADDR VAULT_TOKEN)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    err "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# === Vault connectivity check ===
log "🔐 Fetching secrets from Vault..."
log "Testing Vault connectivity at $VAULT_ADDR..."
export VAULT_CLIENT_TIMEOUT=30s
export VAULT_MAX_RETRIES=3
if ! timeout 30 vault status >/dev/null 2>&1; then
    err "❌ Cannot connect to Vault at $VAULT_ADDR (timeout after 30s)"
    exit 1
fi
log "✓ Vault is reachable"
# === Fetch secrets from Vault ===
DB_PASS=$(vault kv get -field=immich-db-password kubernetes/docker-secrets)
REDIS_PASS=$(vault kv get -field=dragonflydb-credentials kubernetes/docker-secrets)
log "✓ Secrets fetched"
# === Write ephemeral .env file ===
ENV_FILE="$(mktemp)"
cat > "$ENV_FILE" << EOF
IMMICH_VERSION=v2.7.5
BASE_LOCATION=/mnt/docker-datastore-archive/immich
DB_URL=postgresql://immich-db-admin:${DB_PASS}@192.168.1.40:5432/immich?schema=public
REDIS_HOSTNAME=192.168.1.31
REDIS_PASSWORD=${REDIS_PASS}
EOF
# === Copy files to GPU node ===
log "📦 Copying compose files to $GPU_NODE_USER@$GPU_NODE_IP:$REMOTE_DIR ..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$GPU_NODE_USER@$GPU_NODE_IP" "mkdir -p $REMOTE_DIR"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/docker-compose.yml" \
    "$SCRIPT_DIR/immich.json" \
    "$ENV_FILE" \
    "$GPU_NODE_USER@$GPU_NODE_IP:$REMOTE_DIR/"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$GPU_NODE_USER@$GPU_NODE_IP" \
    "mv $REMOTE_DIR/$(basename $ENV_FILE) $REMOTE_DIR/.env && chmod 600 $REMOTE_DIR/.env"
rm -f "$ENV_FILE"
log "✓ Files copied"
# === Deploy on GPU node ===
log "🚀 Deploying Immich on $GPU_NODE_IP ..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$GPU_NODE_USER@$GPU_NODE_IP" \
    "cd $REMOTE_DIR && docker compose pull && docker compose up -d --remove-orphans --force-recreate"
log "✅ Immich deployed successfully on $GPU_NODE_IP"
