#!/usr/bin/env bash
# Deploys an Alloy agent stack to a Docker host via SSH (fallback path —
# use Arcane API if available per Task 1). Usage: deploy_agent.sh <host> <user> <ssh_key> <local_dir> <remote_dir>
set -euo pipefail
HOST="$1"; USER="$2"; KEY="$3"; LOCAL_DIR="$4"; REMOTE_DIR="$5"
ssh -i "$KEY" "$USER@$HOST" "sudo mkdir -p $REMOTE_DIR"
scp -i "$KEY" -r "$LOCAL_DIR"/compose.yaml "$LOCAL_DIR"/config.alloy "$USER@$HOST":/tmp/alloy/
ssh -i "$KEY" "$USER@$HOST" "sudo cp -r /tmp/alloy/* $REMOTE_DIR/ && cd $REMOTE_DIR && sudo docker compose up -d && sudo docker compose ps --format '{{.Name}} {{.Status}}'"