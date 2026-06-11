#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------

STACK_NAME="netbird"
NETBIRD_CONFIG_NAME="netbird-config-yaml"
LEGACY_CONFIG_NAME="management-config-json"
VAULT_SECRETS_PATH="kubernetes/docker-secrets"
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
  exit 1
fi

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "❌ Required command '$cmd' is not installed."
    exit 1
  fi
}

generate_auth_secret() {
  openssl rand -base64 32 | tr -d '\n='
}

generate_store_key() {
  openssl rand -base64 32 | tr -d '\n'
}

get_or_create_vault_secret() {
  local field="$1"
  local generator="$2"
  local label="$3"
  local value=""

  if value=$(vault kv get -field="$field" "$VAULT_SECRETS_PATH" 2>/dev/null); then
    printf "%s" "$value"
    return 0
  fi

  log "Generating missing ${label} in Vault field '${field}'..." >&2
  value="$($generator)"
  if [ -z "$value" ]; then
    err "❌ Failed to generate ${label}."
    exit 1
  fi

  vault kv patch "$VAULT_SECRETS_PATH" "$field=$value" >/dev/null
  printf "%s" "$value"
}

require_command docker
require_command vault
require_command openssl

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

log "🎯 Deploying to node codename: $SWARM_NODE_CODENAME"
log "🔐 Loading NetBird secrets from Vault..."

export NETBIRD_DOMAIN="netbird.mcb-homelab.com"
export TRAEFIK_ENTRYPOINT="websecure"
export TRAEFIK_CERTRESOLVER="letsencrypt"
export NETBIRD_SERVER_TAG="latest"
export NETBIRD_DASHBOARD_TAG="latest"
export SWARM_NODE_CODENAME="$SWARM_NODE_CODENAME"

NETBIRD_AUTH_SECRET="guayeHDCpTkBTqECJ4O6PyXA5zPy1mWv0wAvngwOgjQ"
NETBIRD_STORE_ENCRYPTION_KEY="Hc25Ohlbk0BvIjUU1GjP/y82X/1B2qENEVl7q2T17uc="

# NETBIRD_AUTH_SECRET="$(get_or_create_vault_secret "netbird-auth-secret" generate_auth_secret "NetBird relay auth secret")"
# NETBIRD_STORE_ENCRYPTION_KEY="$(get_or_create_vault_secret "netbird-store-encryption-key" generate_store_key "NetBird store encryption key")"

log "🧹 Removing existing NetBird stack and Docker configs..."
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
sleep 10
docker config rm "$NETBIRD_CONFIG_NAME" >/dev/null 2>&1 || true
docker config rm "$LEGACY_CONFIG_NAME" >/dev/null 2>&1 || true

log "📝 Creating NetBird combined configuration..."
cat <<EOF | docker config create "$NETBIRD_CONFIG_NAME" -
server:
  listenAddress: ":80"
  exposedAddress: "https://${NETBIRD_DOMAIN}:443"
  dnsDomain: "${NETBIRD_DOMAIN}"
  stunPorts:
    - 3478
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"
  authSecret: "${NETBIRD_AUTH_SECRET}"
  dataDir: "/var/lib/netbird"
  disableAnonymousMetrics: true

  auth:
    issuer: "https://${NETBIRD_DOMAIN}/oauth2"
    signKeyRefreshEnabled: true
    dashboardRedirectURIs:
      - "https://${NETBIRD_DOMAIN}/nb-auth"
      - "https://${NETBIRD_DOMAIN}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  store:
    engine: "sqlite"
    encryptionKey: "${NETBIRD_STORE_ENCRYPTION_KEY}"
EOF

log "🚀 Deploying Docker stack..."
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach
log "✅ Docker stack '$STACK_NAME' deployed successfully!"
