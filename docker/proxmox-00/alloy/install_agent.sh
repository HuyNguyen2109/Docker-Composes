#!/usr/bin/env bash
# Native (systemd) install of an Alloy agent on proxmox-00.
# NOTE: this host has no Docker and no Arcane environment registered, so the
# compose-based deploy_agent.sh path does not apply. Alloy and node-exporter
# run as plain systemd services.
#
# PREREQUISITES (not yet met — see report):
#   1. NetBird agent installed, registered (setup key from the management
#      console on talos-cloud-00) and connected so that 100.88.153.244 is
#      reachable: `ping -c2 100.88.153.244` must succeed.
#   2. Root SSH from the controller (homelab key).
#
# Usage (as root on proxmox-00):
#   bash install_agent.sh
set -euo pipefail

ALLOY_VERSION="v1.16.1"
ALLOY_URL="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-linux-amd64.zip"
CONFIG_SRC="/root/workspace/My-DevOps/docker/proxmox-00/alloy/config.alloy"   # local repo path on controller

echo "== installing node-exporter (Debian package) =="
apt-get update -qq
apt-get install -y prometheus-node-exporter unzip

echo "== installing Alloy $ALLOY_VERSION =="
TMP="$(mktemp -d)"
curl -sL -o "${TMP}/alloy.zip" "$ALLOY_URL"
unzip -o -q "${TMP}/alloy.zip" -d "${TMP}"
install -m 0755 "${TMP}/alloy-linux-amd64" /usr/local/bin/alloy
rm -rf "$TMP"
alloy --version

echo "== installing config =="
install -d -m 0755 /etc/alloy
install -m 0644 "$CONFIG_SRC" /etc/alloy/config.alloy

echo "== installing systemd units =="
cat > /etc/systemd/system/alloy.service << 'UNIT'
[Unit]
Description=Grafana Alloy agent (central observability)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/alloy run --server.http.listen-addr=127.0.0.1:12345 /etc/alloy/config.alloy
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now alloy
systemctl enable --now prometheus-node-exporter

echo "== status =="
systemctl --no-pager status alloy --lines=3
systemctl is-active prometheus-node-exporter

echo "DONE — verify: curl -s http://100.88.153.244:3100/loki/api/v1/query_range --get --data-urlencode 'query={host=\"proxmox-00\"}' --data-urlencode 'limit=3'"