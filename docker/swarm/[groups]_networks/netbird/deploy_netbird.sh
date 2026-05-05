#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="netbird"
NETBIRD_MANAGEMENT_CONFIG="management-config-json"
# === Remove existing Docker services if it exists ===
docker config rm "$NETBIRD_MANAGEMENT_CONFIG" >/dev/null 2>&1 || true
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# Check if Vault CLI has been installed
echo "Checking vault cli is installed..."
if ! command -v vault >/dev/null 2>&1; then
    echo "❌ Vault CLI is not installed!"
    exit 1
fi
echo "Checking Vault credentials for Vault..."
REQUIRED_VARS=(
  VAULT_ADDR
  VAULT_TOKEN
)
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Environment variable '$VAR' is not set or is empty."
    exit 1
  fi
done
# Load environment variables from .env file
export NETBIRD_DOMAIN="netbird.mcb-svc.work"
export NETBIRD_STORE_ENGINE_POSTGRES_DSN="host=postgresql-master user=netbird-admin password=$(vault kv get -field=netbird-db-password kubernetes/docker-secrets) dbname=netbird port=5432"
# Create management.json config file
cat <<EOF | docker config create "$NETBIRD_MANAGEMENT_CONFIG" -
{
  "HttpConfig": {
    "ListenAddress": ":33073"
  },
  "StoreConfig": {
    "Engine": "postgres",
    "Postgres": {
      "DSN": "host=postgresql-master user=netbird-admin password=$(vault kv get -field=netbird-db-password kubernetes/docker-secrets) dbname=netbird port=5432"
    }
  },
  "AuthConfig": {
    "OIDCConfig": {
      "Issuer": "https://auth.mcb-svc.work/application/o/netbird/",
      "ClientID": "$(vault kv get -field=netbird-oidc-client-id kubernetes/docker-secrets)",
      "ClientSecret": "$(vault kv get -field=netbird-oidc-client-secret kubernetes/docker-secrets)",
      "RedirectURI": "https://api.${NETBIRD_DOMAIN}"
    }
  }
}
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
