#!/usr/bin/env bash
# Deploys the central observability stack to talos-cloud-01.
# Fallback path if Arcane API is unavailable (see Task 1 decision).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="opc@140.245.100.82"
SSH_KEY="/root/ssh-keys/oracle"
REMOTE_DIR="/docker-volume/observability"

[ -x "$(command -v vault)" ] || { echo "vault CLI required" >&2; exit 1; }

echo "== fetching S3 credentials from Vault =="
S3_ENDPOINT="$(vault kv get -field=common-s3-endpoint kubernetes/docker-secrets)"
# The loki-config s3 URL embeds the endpoint host inside s3://...@HOST/bucket, so
# the env var must be hostname-only; the https scheme lives in the separate
# `endpoint:` field of the storage config.
S3_HOST="${S3_ENDPOINT#https://}"
S3_ACCESS="$(vault kv get -field=loki-s3-access-key kubernetes/docker-secrets)"
S3_SECRET="$(vault kv get -field=loki-s3-secret-key kubernetes/docker-secrets)"
GF_PASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -hex 16)}"
echo "Grafana admin password: ${GF_PASS}  (set GRAFANA_ADMIN_PASSWORD to override)"

echo "== building .env =="
printf 'AWS_ENDPOINTS=%s\nAWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' \
  "$S3_HOST" "$S3_ACCESS" "$S3_SECRET" "$GF_PASS" > "${DIR}/.env"
chmod 600 "${DIR}/.env"

echo "== preparing remote dirs =="
ssh -i "$SSH_KEY" "$TARGET" "sudo mkdir -p ${REMOTE_DIR}/{loki,prometheus,grafana} && sudo chown -R \$(id -u):\$(id -g) ${REMOTE_DIR}"

echo "== uploading stack =="
scp -i "$SSH_KEY" -r "${DIR}/compose.yaml" "${DIR}/config" "${DIR}/.env" "$TARGET":/tmp/obs/
ssh -i "$SSH_KEY" "$TARGET" "sudo cp -r /tmp/obs/* ${REMOTE_DIR}/"

echo "== starting stack =="
ssh -i "$SSH_KEY" "$TARGET" "cd ${REMOTE_DIR} && sudo docker compose up -d"

echo "== health check =="
ssh -i "$SSH_KEY" "$TARGET" "cd ${REMOTE_DIR} && sudo docker compose ps"