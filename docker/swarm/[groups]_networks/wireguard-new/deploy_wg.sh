#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="wireguard-new"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Env ===
export WG_HOST=$(curl -s ifconfig.me)
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
