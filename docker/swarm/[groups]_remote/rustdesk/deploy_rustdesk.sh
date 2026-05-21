#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="rustdesk"

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

log "🎯 Deploying to node codename: $SWARM_NODE_CODENAME"
# === Remove existing Docker services if it exists ===
export SWARM_NODE_CODENAME=$SWARM_NODE_CODENAME
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" >/dev/null 2>&1 || true
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
