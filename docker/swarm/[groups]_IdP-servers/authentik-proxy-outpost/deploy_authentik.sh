#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
SWARM_NODE_CODENAME=""
# === Check if codename has been passed as argument ===
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
# === Remove existing Docker services if it exists ===
log "Fetching variables for stack deployment..."
STACK_NAME="authentik-proxy"
export PG_PASS=$(vault kv get -field=authentik-db-password kubernetes/docker-secrets)
export AUTHENTIK_SECRET_KEY=$(vault kv get -field=authentik-secret-key kubernetes/docker-secrets)
export PG_HOST="pgbouncer"
export PG_DB="authentik_db"
export PG_USER="authentik_admin"
export REPLICA_0_HOST="pgbouncer"
export UI_URL="auth.mcb-svc.work"
export AUTHENTIK_TAG="2025.12.0"
export PG_CONN_MAX="60"
export SWARM_NODE_CODENAME=$SWARM_NODE_CODENAME
export AUTHENTIK_PUBLIC_URL="auth.mcb-svc.work"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
