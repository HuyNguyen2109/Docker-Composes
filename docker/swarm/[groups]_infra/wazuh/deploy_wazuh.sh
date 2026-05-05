#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="wazuh-siem"
CERTS_DIR="./config/wazuh_indexer_ssl_certs"
# Special envs for generate/renew certs stack
export UI_URL="siem.mcb-svc.work"
export IMAGE_TAG="4.14.3"
export BASE_WAZUH_VERSION="4.14"
export CERT_GEN_IMAGE_TAG="0.0.4"

# === Parse command-line arguments ===
WAZUH_INDEXER_NODE_CODENAME=""
WAZUH_MANAGER_NODE_CODENAME=""
WAZUH_DASHBOARD_NODE_CODENAME=""
WAZUH_MANAGER_CONFIGNAME="wazuh-manager-config"
WAZUH_INDEXER_CONFIGNAME="wazuh-indexer-config"
WAZUH_INDEXER_INTERNALUSERS_CONFIGNAME="internal-users-config"
WAZUH_DASHBOARD_OPENSEARCH_CONFIGNAME="wazuh-dashboard-opensearch-config"
WAZUH_DASHBOARD_GENERAL_CONFIGNAME="wazuh-general-config"
# List of Wazuh SSL certificate files
WAZUH_CERTS=(
  "wazuh.manager.pem"
  "wazuh.manager-key.pem"
  "root-ca-manager.pem"
  "wazuh.indexer.pem"
  "wazuh.indexer-key.pem"
  "admin.pem"
  "admin-key.pem"
  "root-ca.pem"
  "wazuh.dashboard.pem"
  "wazuh.dashboard-key.pem"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gen-certs)
      docker context use default
      docker compose -f generate-indexer-certs.yml run --rm generator
      shift 1
      exit 1
      ;;
    --gen-certs-debug)
      docker context use default
      docker compose -f generate-indexer-certs.yml run --rm generator bash
      shift 1
      exit 1
      ;;
    --indexer-node)
      WAZUH_INDEXER_NODE_CODENAME="$2"
      shift 2
      ;;
    --manager-node)
      WAZUH_MANAGER_NODE_CODENAME="$2"
      shift 2
      ;;
    --dashboard-node)
      WAZUH_DASHBOARD_NODE_CODENAME="$2"
      shift 2
      ;;
    -h|--help)
      log "Usage: $0 --indexer-node <WAZUH_INDEXER_NODE_CODENAME>"
      log "Usage: $0 --manager-node <WAZUH_MANAGER_NODE_CODENAME>"
      log "Usage: $0 --dashboard-node <WAZUH_DASHBOARD_NODE_CODENAME>"
      log "Options:"
      log "  --indexer-node    Specify the indexer node codename (alpha, beta, gamma)"
      log "  --manager-node    Specify the manager node codename (alpha, beta, gamma)"
      log "  --dashboard-node  Specify the dashboard node codename (alpha, beta, gamma)"
      log "  --gen-certs               Generate or renew Wazuh Indexer SSL certificates"
      log "  -h, --help                Show this help message"
      log ""
      log "Example: $0 --indexer-node alpha"
      exit 0
      ;;
    *)
      err "❌ Unknown option: $1"
      err "Use --help for usage information"
      exit 1
      ;;
  esac
done
# === Validate SSL certificate files exist ===
log "Checking SSL certificate files in '$CERTS_DIR'..."
if ls "$CERTS_DIR"/*.pem "$CERTS_DIR"/*.key >/dev/null 2>&1; then
  log "SSL certificate (.pem/.key) files found in '$CERTS_DIR'."
else
  err "No .pem or .key files found in '$CERTS_DIR'."
  exit 1
fi

# === Check if Vault CLI is installed ===
log "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    err "❌ Vault CLI is not installed!"
    exit 1
fi

log "Checking Vault credentials..."
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

NODE_CODENAMES=($WAZUH_INDEXER_NODE_CODENAME $WAZUH_MANAGER_NODE_CODENAME $WAZUH_DASHBOARD_NODE_CODENAME)
for codename in "${NODE_CODENAMES[@]}"; do
  if [ -z "$codename" ]; then
    err "❌ Node codename is required."
    err "Usage: $0 --indexer-node <WAZUH_INDEXER_NODE_CODENAME>"
    err "Example: $0 --indexer-node alpha"
    exit 1
  fi
done

# === Remove existing Docker services if it exists ===
log "Destroy old stack and preparing data..."
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
docker config rm "$WAZUH_MANAGER_CONFIGNAME" >/dev/null 2>&1 || true
docker config rm "$WAZUH_INDEXER_INTERNALUSERS_CONFIGNAME" >/dev/null 2>&1 || true
docker config rm "$WAZUH_DASHBOARD_OPENSEARCH_CONFIGNAME" >/dev/null 2>&1 || true
docker config rm "$WAZUH_DASHBOARD_GENERAL_CONFIGNAME" >/dev/null 2>&1 || true
docker config rm "$WAZUH_INDEXER_CONFIGNAME" >/dev/null 2>&1 || true

export WAZUH_INDEXER_NODE_CODENAME=$WAZUH_INDEXER_NODE_CODENAME
export WAZUH_MANAGER_NODE_CODENAME=$WAZUH_MANAGER_NODE_CODENAME
export WAZUH_DASHBOARD_NODE_CODENAME=$WAZUH_DASHBOARD_NODE_CODENAME

export INDEXER_ADMIN_USERNAME="admin"
export INDEXER_ADMIN_PASSWORD="$(vault kv get -field=wazuh_indexer_admin_password kubernetes/docker-secrets)"
export API_USERNAME="wazuh-wui"
export API_PASSWORD="$(vault kv get -field=wazuh_api_password  kubernetes/docker-secrets)"
export DASHBOARD_USERNAME="kibanaserver"
export DASHBOARD_PASSWORD="$(vault kv get -field=wazuh_dasboard_password  kubernetes/docker-secrets)"

log "Parsing new config files..."
docker config create "$WAZUH_MANAGER_CONFIGNAME" ./config/wazuh_cluster/wazuh_manager.conf 
docker config create "$WAZUH_INDEXER_CONFIGNAME" ./config/wazuh_indexer/wazuh.indexer.yml 
docker config create "$WAZUH_DASHBOARD_OPENSEARCH_CONFIGNAME" ./config/wazuh_dashboard/opensearch_dashboards.yml 
sed -e "s|{{ API_PASSWORD }}|$API_PASSWORD|g" \
    ./config/wazuh_dashboard/wazuh.yml | docker config create "$WAZUH_DASHBOARD_GENERAL_CONFIGNAME" - 

ADMIN_HASHED_PASSWORD=$(htpasswd -nbB $INDEXER_ADMIN_USERNAME $INDEXER_ADMIN_PASSWORD | awk -F: '{print $2}')
DASHBOARD_HASHED_PASSWORD=$(htpasswd -nbB $DASHBOARD_USERNAME $DASHBOARD_PASSWORD | awk -F: '{print $2}')
sed -e "s|{{ ADMIN_HASHED_PASSWORD }}|$ADMIN_HASHED_PASSWORD|g" \
    -e "s|{{ DASHBOARD_HASHED_PASSWORD }}|$DASHBOARD_HASHED_PASSWORD|g" \
    ./config/wazuh_indexer/internal_users.yml | docker config create "$WAZUH_INDEXER_INTERNALUSERS_CONFIGNAME" - 

sleep 5

log "Parsing new certs..."
for cert in "${WAZUH_CERTS[@]}"; do
  log "Uploading cert config: $CERTS_DIR/$cert"
  sudo chmod 600 "$CERTS_DIR/$cert"
  sudo chown "$USER":"$USER" "$CERTS_DIR/$cert"
  docker config rm "$cert" >/dev/null 2>&1 || true
  docker config create "$cert" "$CERTS_DIR/$cert" 
  sleep 5
done


# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach --prune
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
