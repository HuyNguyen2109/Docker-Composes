#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="portainer-prd"
export DOCKER_BASED_DIR="/mnt/docker-local"
PORTAINER_DATA_DIR="${DOCKER_BASED_DIR}/portainer"
PORTAINER_VOLUME_NAME="portainer-data"
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
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
sleep 10

log "📦 Ensuring Portainer Docker volume exists..."
if ! docker volume create "$PORTAINER_VOLUME_NAME" >/dev/null; then
  err "❌ Failed to create Docker volume ${PORTAINER_VOLUME_NAME}."
  exit 1
fi

if [ -f "${PORTAINER_DATA_DIR}/portainer.db" ]; then
  if docker run --rm -v "${PORTAINER_VOLUME_NAME}:/to" alpine sh -c '[ -z "$(ls -A /to 2>/dev/null)" ]'; then
    log "📂 Migrating Portainer data from ${PORTAINER_DATA_DIR} into ${PORTAINER_VOLUME_NAME}..."
    if ! docker run --rm \
      -v "${PORTAINER_DATA_DIR}:/from:ro" \
      -v "${PORTAINER_VOLUME_NAME}:/to" \
      alpine sh -c 'cp -a /from/. /to/'; then
      err "❌ Failed to migrate Portainer data into ${PORTAINER_VOLUME_NAME}."
      exit 1
    fi

    PORTAINER_BACKUP_DIR="${DOCKER_BASED_DIR}/portainer-nfs-backup-$(date +%Y%m%d%H%M%S)"
    log "🗃️ Preserving the original NFS-backed data at ${PORTAINER_BACKUP_DIR}..."
    if ! mv "${PORTAINER_DATA_DIR}" "${PORTAINER_BACKUP_DIR}"; then
      err "❌ Failed to move ${PORTAINER_DATA_DIR} to ${PORTAINER_BACKUP_DIR}."
      exit 1
    fi
  else
    warn "Portainer volume ${PORTAINER_VOLUME_NAME} already contains data, skipping migration."
  fi
else
  warn "No existing Portainer database found at ${PORTAINER_DATA_DIR}, skipping migration."
fi

export UI_URL="dashboard.mcb-homelab.com"
export IMAGE_TAG="2.40.0-alpine"
export SWARM_NODE_CODENAME="$SWARM_NODE_CODENAME"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
