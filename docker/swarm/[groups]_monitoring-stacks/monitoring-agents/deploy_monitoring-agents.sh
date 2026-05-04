#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------
# Define stack name (change this as needed)
STACK_NAME="monitoring-agents"
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

log "🎯 Deploying stack with Grafana goes to node codename: $SWARM_NODE_CODENAME"
# === Get secrets from Vault ===
log "🔐 Fetching secrets from Vault..."
GRAFANA_ADMIN_PASSWORD=$(vault kv get -field=grafana-admin-password kubernetes/docker-secrets)
GRAFANA_DB_ADMIN_PASSWORD=$(vault kv get -field=grafana-db-admin-password kubernetes/docker-secrets)
GRAFANA_AUTHENTIK_CLIENT_ID=$(vault kv get -field=grafana-authentik-client-id kubernetes/docker-secrets)
GRAFANA_AUTHENTIK_CLIENT_SECRET=$(vault kv get -field=grafana-authentik-client-secret kubernetes/docker-secrets)
GRAFANA_SECRET_KEY=$(vault kv get -field=grafana-secret-key kubernetes/docker-secrets)
ALERTMANAGER_TELEGRAM_BOT_INTEGRATION_KEY=$(vault kv get -field=grafana-alertmanager-telegram-bot kubernetes/docker-secrets)
CACHE_AUTH=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
# === Create Docker Config via STDIN ===
log "Parsing variables..."
GRAFANA_CONFIG_FILE="grafana-conf"
PROMETHEUS_RULES="prometheus-rules"
PROMETHEUS_CONFIG_FILE="prometheus-conf"
ALERTMANAGER_CONFIG_FILE="alertmanager-conf"
ALERTMANAGER_TELEGRAM_TMPL="telegram-tmpl"
ALERT_MANAGER_URL="localhost"
POSTGRES_HOST="pgbouncer-session"
ALERTMANAGER_TELEGRAM_CHAT_ID=-1003129190360
ALERTMANAGER_TELEGRAM_MESSAGE_THREAD_ID=""
OIDC_APPLICATION_SLUG="grafana"
CACHE_URL="valkey-server:6379"

export ALERTMANAGER_IMAGE_TAG="v0.31.0"
export CADVISOR_IMAGE_TAG="v0.55.1"
export PROMETHEUS_IMAGE_TAG="main-distroless"
export NODE_EXPORTER_IMAGE_TAG="v1.10.2"
export GRAFANA_IMAGE_TAG="12.3.2-ubuntu"

export OIDC_URL="auth.mcb-svc.work"
export GRAFANA_URL="grafana.mcb-svc.work"
export SWARM_NODE_CODENAME="$SWARM_NODE_CODENAME"

log "Parsing/Updating all necessary variables into config..."

log "1. config $PROMETHEUS_CONFIG_FILE"
docker config rm "$PROMETHEUS_CONFIG_FILE" >/dev/null 2>&1 || true
cat "./configs/prometheus-conf.yml" | docker config create "$PROMETHEUS_CONFIG_FILE" - > /dev/null 2>&1 || true

log "2. config $PROMETHEUS_RULES"
docker config rm "$PROMETHEUS_RULES" >/dev/null 2>&1 || true
cat "./configs/prometheus-rules.yml" | docker config create "$PROMETHEUS_RULES" - > /dev/null 2>&1 || true

log "3. config $GRAFANA_CONFIG_FILE"
docker config rm "$GRAFANA_CONFIG_FILE" >/dev/null 2>&1 || true
sed -e "s|{{ GRAFANA_ADMIN_PASSWORD }}|$GRAFANA_ADMIN_PASSWORD|g" \
    -e "s|{{ GRAFANA_DB_ADMIN_PASSWORD }}|$GRAFANA_DB_ADMIN_PASSWORD|g" \
    -e "s|{{ GRAFANA_AUTHENTIK_CLIENT_ID }}|$GRAFANA_AUTHENTIK_CLIENT_ID|g" \
    -e "s|{{ GRAFANA_AUTHENTIK_CLIENT_SECRET }}|$GRAFANA_AUTHENTIK_CLIENT_SECRET|g" \
    -e "s|{{ GRAFANA_SECRET_KEY }}|$GRAFANA_SECRET_KEY|g" \
    -e "s|{{ OIDC_URL }}|$OIDC_URL|g" \
    -e "s|{{ GRAFANA_URL }}|$GRAFANA_URL|g" \
    -e "s|{{ POSTGRES_HOST }}|$POSTGRES_HOST|g" \
    -e "s|{{ OIDC_APPLICATION_SLUG }}|$OIDC_APPLICATION_SLUG|g" \
    -e "s|{{ CACHE_URL }}|$CACHE_URL|g" \
    -e "s|{{ CACHE_AUTH }}|$CACHE_AUTH|g" \
    ./configs/grafana.ini | docker config create "$GRAFANA_CONFIG_FILE" - > /dev/null 2>&1 || true

log "4. config $ALERTMANAGER_TELEGRAM_TMPL"
docker config rm "$ALERTMANAGER_TELEGRAM_TMPL" >/dev/null 2>&1 || true
sed -e "s|{{ GRAFANA_URL }}|$GRAFANA_URL|g" \
    -e "s|{{ ALERT_MANAGER_URL }}|$ALERT_MANAGER_URL|g" \
  ./templates/telegram.tmpl | docker config create "$ALERTMANAGER_TELEGRAM_TMPL" - > /dev/null 2>&1 || true

log "5. config $ALERTMANAGER_CONFIG_FILE"
docker config rm "$ALERTMANAGER_CONFIG_FILE" >/dev/null 2>&1 || true
sed -e "s|{{ TELEGRAM_BOT_TOKEN }}|$ALERTMANAGER_TELEGRAM_BOT_INTEGRATION_KEY|g" \
    -e "s|{{ TELEGRAM_CHAT_ID }}|$ALERTMANAGER_TELEGRAM_CHAT_ID|g" \
    -e "s|{{ TELEGRAM_MESSAGE_THREAD_ID }}|$ALERTMANAGER_TELEGRAM_MESSAGE_THREAD_ID|g" \
  "./configs/alertmanager.yml" | docker config create "$ALERTMANAGER_CONFIG_FILE" - > /dev/null 2>&1 || true

# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
