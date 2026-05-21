#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="pocketid"
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
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Env ===
log "Setting environment variables for deployment..."
export INSTANCE_IMAGE_TAG="v2.1-distroless"
export S3_REGION="us-east"
export S3_ENDPOINT="https://s3.us-east-005.backblazeb2.com"
export S3_BUCKET="McBourdeux-NAS-Backup"
export S3_ACCESS_KEY_ID=$(vault kv get -field=s3-client-id kubernetes/docker-secrets)
export S3_SECRET_ACCESS_KEY=$(vault kv get -field=s3-client-secret kubernetes/docker-secrets)
export PG_HOST="pgbouncer"
export PG_DB="pocket_id"
export PG_USER="pocket_id_admin"
export PG_PASS=$(vault kv get -field=pocketid-db-password kubernetes/docker-secrets)
export ENCRYPTION_KEY=$(vault kv get -field=pocketid-enc-key kubernetes/docker-secrets)
export DB_CONNECTION_STRING="postgresql://${PG_USER}:${PG_PASS}@${PG_HOST}:5432/${PG_DB}?sslmode=disable"
export APP_URL="http://auth.mcb-svc.work"
export SWARM_NODE_CODENAME=$SWARM_NODE_CODENAME
sleep 5
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
