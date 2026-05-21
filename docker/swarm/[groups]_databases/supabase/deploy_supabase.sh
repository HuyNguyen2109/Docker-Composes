#!/bin/bash
# ----------------------
log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
# ----------------------

# Define stack name
STACK_NAME="supabase-stack"

# Define config names
KONG_CONFIG="kong-config"
VECTOR_CONFIG="vector-config"

log "Starting Supabase stack deployment..."

# === Remove existing Docker stack and configs ===
log "Removing existing stack and configs if they exist..."
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
sleep 5

docker config rm $KONG_CONFIG >/dev/null 2>&1 || true
docker config rm $VECTOR_CONFIG >/dev/null 2>&1 || true

# === Check if Vault CLI is installed ===
log "Checking if Vault CLI is installed..."
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

# === Function to URL encode strings ===
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# === Fetch secrets from Vault and export as environment variables ===
log "🔐 Fetching secrets from Vault (https://vault.mcb-svc.work/ui/vault/secrets/kubernetes/kv/docker-secrets/)..."

# Postgres password
export SUPABASE_POSTGRES_PASSWORD=$(vault kv get -field=supabase-postgres-password kubernetes/docker-secrets 2>/dev/null)
if [ -z "$SUPABASE_POSTGRES_PASSWORD" ]; then
    warn "⚠️  supabase-postgres-password not found in Vault. Generating random password (alphanumeric only)..."
    # Generate password with only alphanumeric characters to avoid special character issues
    export SUPABASE_POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    log "✅ Generated new postgres password (not displayed for security)"
    log "Please save this password to Vault using: vault kv put kubernetes/docker-secrets supabase-postgres-password=<generated-password>"
    log "To retrieve the password from Vault: vault kv get -field=supabase-postgres-password kubernetes/docker-secrets"
fi

# URL-encode the password for use in connection strings
export SUPABASE_POSTGRES_PASSWORD_ENCODED=$(urlencode "$SUPABASE_POSTGRES_PASSWORD")

# JWT Secret
export SUPABASE_JWT_SECRET=$(vault kv get -field=supabase-jwt-secret kubernetes/docker-secrets 2>/dev/null)
if [ -z "$SUPABASE_JWT_SECRET" ]; then
    warn "⚠️  supabase-jwt-secret not found in Vault. Generating random secret..."
    export SUPABASE_JWT_SECRET=$(openssl rand -base64 64)
    log "✅ Generated new JWT secret (not displayed for security)"
    log "Please save this secret to Vault using: vault kv put kubernetes/docker-secrets supabase-jwt-secret=<generated-secret>"
    log "To retrieve the JWT secret from Vault: vault kv get -field=supabase-jwt-secret kubernetes/docker-secrets"
fi

# Anonymous Key (JWT with role 'anon')
export SUPABASE_ANON_KEY=$(vault kv get -field=supabase-anon-key kubernetes/docker-secrets 2>/dev/null)
if [ -z "$SUPABASE_ANON_KEY" ]; then
    warn "⚠️  supabase-anon-key not found in Vault."
    warn "You need to generate JWT tokens using the JWT secret."
    warn "Visit: https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys"
    err "Please create the anon key and save it to Vault, then re-run this script."
    exit 1
fi

# Service Role Key (JWT with role 'service_role')
export SUPABASE_SERVICE_ROLE_KEY=$(vault kv get -field=supabase-service-role-key kubernetes/docker-secrets 2>/dev/null)
if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
    warn "⚠️  supabase-service-role-key not found in Vault."
    warn "You need to generate JWT tokens using the JWT secret."
    warn "Visit: https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys"
    err "Please create the service_role key and save it to Vault, then re-run this script."
    exit 1
fi

# SMTP Password
# export SUPABASE_SMTP_PASSWORD=$(vault kv get -field=supabase-smtp-password kubernetes/docker-secrets 2>/dev/null)
# if [ -z "$SUPABASE_SMTP_PASSWORD" ]; then
#     warn "⚠️  supabase-smtp-password not found in Vault. Using empty password."
#     export SUPABASE_SMTP_PASSWORD=""
# fi

# === Export environment variables for docker-compose ===
log "Setting environment variables..."

export API_EXTERNAL_URL="${API_EXTERNAL_URL:-https://api.supabase.mcb-svc.work}"
export SITE_URL="${SITE_URL:-https://supabase.mcb-svc.work}"
export ADDITIONAL_REDIRECT_URLS="${ADDITIONAL_REDIRECT_URLS:-}"
export DISABLE_SIGNUP="${DISABLE_SIGNUP:-false}"
export ENABLE_EMAIL_SIGNUP="${ENABLE_EMAIL_SIGNUP:-true}"
export ENABLE_EMAIL_AUTOCONFIRM="${ENABLE_EMAIL_AUTOCONFIRM:-false}"
export ENABLE_PHONE_SIGNUP="${ENABLE_PHONE_SIGNUP:-false}"
export ENABLE_PHONE_AUTOCONFIRM="${ENABLE_PHONE_AUTOCONFIRM:-false}"

export SMTP_ADMIN_EMAIL="${SMTP_ADMIN_EMAIL:-admin@mcb-svc.work}"
export SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
export SMTP_PORT="${SMTP_PORT:-587}"
export SMTP_USER="${SMTP_USER:-noreply@mcb-svc.work}"
export SMTP_SENDER_NAME="${SMTP_SENDER_NAME:-Supabase}"

export STUDIO_DEFAULT_ORGANIZATION="${STUDIO_DEFAULT_ORGANIZATION:-MCB Organization}"
export STUDIO_DEFAULT_PROJECT="${STUDIO_DEFAULT_PROJECT:-Default Project}"

export LOGFLARE_API_KEY="${LOGFLARE_API_KEY:-your-logflare-api-key}"

# === Create Kong configuration ===
log "Creating Kong configuration..."
cat <<'EOF' | docker config create $KONG_CONFIG - >/dev/null 2>&1
_format_version: "2.1"
_transform: true

services:
  - name: auth-v1-open
    url: http://auth:9999/verify
    routes:
      - name: auth-v1-open
        strip_path: true
        paths:
          - /auth/v1/verify
    plugins:
      - name: cors

  - name: auth-v1-open-callback
    url: http://auth:9999/callback
    routes:
      - name: auth-v1-open-callback
        strip_path: true
        paths:
          - /auth/v1/callback
    plugins:
      - name: cors

  - name: auth-v1-open-authorize
    url: http://auth:9999/authorize
    routes:
      - name: auth-v1-open-authorize
        strip_path: true
        paths:
          - /auth/v1/authorize
    plugins:
      - name: cors

  - name: auth-v1
    _comment: "GoTrue: /auth/v1/* -> http://auth:9999/*"
    url: http://auth:9999/
    routes:
      - name: auth-v1-all
        strip_path: true
        paths:
          - /auth/v1/
    plugins:
      - name: cors

  - name: rest-v1
    _comment: "PostgREST: /rest/v1/* -> http://rest:3000/*"
    url: http://rest:3000/
    routes:
      - name: rest-v1-all
        strip_path: true
        paths:
          - /rest/v1/
    plugins:
      - name: cors

  - name: realtime-v1
    _comment: "Realtime: /realtime/v1/* -> ws://realtime:4000/socket/*"
    url: http://realtime:4000/socket/
    routes:
      - name: realtime-v1-all
        strip_path: true
        paths:
          - /realtime/v1/
    plugins:
      - name: cors

  - name: storage-v1
    _comment: "Storage: /storage/v1/* -> http://storage:5000/*"
    url: http://storage:5000/
    routes:
      - name: storage-v1-all
        strip_path: true
        paths:
          - /storage/v1/
    plugins:
      - name: cors

  - name: meta
    _comment: "PG-Meta: /pg/* -> http://meta:8080/*"
    url: http://meta:8080/
    routes:
      - name: meta-all
        strip_path: true
        paths:
          - /pg/

  - name: functions-v1
    _comment: "Edge Functions: /functions/v1/* -> http://functions:9000/*"
    url: http://functions:9000/
    routes:
      - name: functions-v1-all
        strip_path: true
        paths:
          - /functions/v1/
    plugins:
      - name: cors

consumers:
  - username: anon
    keyauth_credentials:
      - key: anon-key
  - username: service_role
    keyauth_credentials:
      - key: service-role-key
EOF

# === Create Vector configuration ===
log "Creating Vector configuration..."
cat <<'EOF' | docker config create $VECTOR_CONFIG - >/dev/null 2>&1
api:
  enabled: true
  address: 127.0.0.1:8686
  playground: false

sources:
  docker_host:
    type: docker_logs
    docker_host: unix:///var/run/docker.sock

sinks:
  logflare_logs:
    type: http
    inputs:
      - docker_host
    uri: http://analytics:4000/api/logs?source_name=docker
    encoding:
      codec: json
    headers:
      Content-Type: application/json
EOF

log "✅ All secrets fetched from Vault and exported as environment variables!"

# === Deploy the stack ===
log "Deploying Supabase stack to Docker Swarm..."
docker stack deploy -c docker-compose.yml "$STACK_NAME" --detach

log "✅ Docker stack '$STACK_NAME' deployed successfully!"
log ""
log "📋 Stack Information:"
log "   - Studio UI:    https://supabase.mcb-svc.work"
log "   - API Gateway:  https://api.supabase.mcb-svc.work"
log "   - Kong Port:    8000 (ingress mode)"
log "   - Studio Port:  3000 (ingress mode)"
log "   - Analytics:    4000 (ingress mode)"
log ""
log "🔍 To check the status of the stack, run:"
log "   docker stack ps $STACK_NAME"
log ""
log "📝 To view logs of a service, run:"
log "   docker service logs -f ${STACK_NAME}_<service-name>"
log ""
log "🔐 Important: Make sure to save the following to Vault if not already done:"
log "   - supabase-postgres-password"
log "   - supabase-jwt-secret"
log "   - supabase-anon-key (generate from JWT secret)"
log "   - supabase-service-role-key (generate from JWT secret)"
log "   - supabase-smtp-password"
log ""
log "📚 For JWT key generation, visit:"
log "   https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys"
