#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
STACK_NAME="termix-ssh"
MASTER_DATA_FOLDER=""
REQUIRED_DIRECTORY="termix"

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

# === Set node-specific configuration based on codename ===
case "$SWARM_NODE_CODENAME" in
  alpha)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_MANAGER_HOSTNAME)
    MASTER_DATA_FOLDER="/mnt/docker/data"
    ;;
  beta)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="root"
    NODES=($SWARM_WORKER_VN_HOSTNAME)
    MASTER_DATA_FOLDER="/mnt/docker/data"
    ;;
  gamma)
    SSH_KEY="$HOME/ssh-keys/oracle.key"
    NODE_USER="ubuntu"
    NODES=($SWARM_WORKER_SG_HOSTNAME)
    MASTER_DATA_FOLDER="/data-drive/docker/data"
    ;;
  *)
    err "❌ Unknown SWARM_NODE_CODENAME: $SWARM_NODE_CODENAME"
    err "Valid options: alpha, beta, gamma"
    exit 1
    ;;
esac

export MASTER_DATA_FOLDER=$MASTER_DATA_FOLDER
export SWARM_NODE_CODENAME

log "SSH to node to create required sub-directories"
for NODE in "${NODES[@]}"; do
  log "🔧 Preparing data folder on $NODE..."
  if ssh -i $SSH_KEY $NODE_USER@$NODE "[ -d $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY ]"; then
      log "  ✓ Directory $REQUIRED_DIRECTORY already exists, skipping..."
    else
      log "  📁 Creating directory $REQUIRED_DIRECTORY..."
      ssh -i $SSH_KEY $NODE_USER@$NODE "sudo mkdir -p $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY && sudo chown docker:docker $MASTER_DATA_FOLDER/$REQUIRED_DIRECTORY"
    fi
done

# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true

# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
