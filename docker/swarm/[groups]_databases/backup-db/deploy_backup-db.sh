#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="backup-db"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Check if Vault CLI is installed ===
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
# === Get secrets from Vault ===
echo "🔐 Fetching secrets from Vault..."
export S3_ACCESS_KEY_ID=$(vault kv get -field=s3-client-id kubernetes/docker-secrets)
export S3_SECRET_ACCESS_KEY=$(vault kv get -field=s3-client-secret kubernetes/docker-secrets)
export S3_ENDPOINT="https://$(vault kv get -field=s3-endpoint kubernetes/docker-secrets)"
export PG_PASS=$(vault kv get -field=authentik-db-password kubernetes/docker-secrets)
export AUTHENTIK_SECRET_KEY=$(vault kv get -field=authentik-secret-key kubernetes/docker-secrets)
export VALKEY_AUTH_PASSWORD=$(vault kv get -field=valkey-auth-password kubernetes/docker-secrets)
export S3_REGION="auto"
export S3_BUCKET="authentik"
export S3_PREFIX="authentik-db-backup-prd"
export PG_HOST="postgresql-master"
export PG_DB="authentik-prd"
export PG_USER="authentik_dbadmin"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
