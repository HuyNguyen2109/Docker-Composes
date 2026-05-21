#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="wireguard"
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
# === Env ===
export PASSWORD=$(vault kv get -field=grafana-admin-password kubernetes/docker-secrets)
export WG_HOST=$(curl -s ifconfig.me)
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" > /dev/null 2>&1 || true
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
