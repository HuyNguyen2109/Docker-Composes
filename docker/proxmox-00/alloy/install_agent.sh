#!/usr/bin/env bash
# Native install of an Alloy agent on proxmox-00 (executed successfully 2026-09-08).
# NOTE: this host has no Docker and no Arcane environment registered, so the
# compose-based deploy_agent.sh path does not apply. Alloy (official Grafana DEB
# package) and node-exporter (Debian package) run as plain systemd services.
#
# PREREQUISITES:
#   1. Root SSH from the controller (homelab key).
#   2. Internet egress from proxmox-00 (verified working).
#
# POST-INSTALL (connectivity to the central stack — REQUIRED for data flow):
#   NetBird agent is installed by this script but still needs a setup key from
#   the self-hosted NetBird management (talos-cloud-00). Once the key exists:
#       netbird up --setup-key <KEY>
#       ping -c2 100.88.153.244     # must succeed before logs/metrics flow
#
# Usage (as root on proxmox-00):
#   bash install_agent.sh
set -euo pipefail

CONFIG_SRC="/etc/alloy/config.alloy"   # copy from repo: docker/proxmox-00/alloy/config.alloy

echo "== installing node-exporter (Debian package) =="
apt-get update -qq
apt-get install -y prometheus-node-exporter

echo "== adding Grafana apt repo (official Alloy packages) =="
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq

echo "== installing Alloy (official DEB package) =="
apt-get install -y alloy
alloy --version

echo "== installing config (scp from controller first) =="
install -d -m 0755 /etc/alloy
install -m 0644 "$CONFIG_SRC" /etc/alloy/config.alloy

echo "== systemd journal access for the alloy user =="
usermod -aG systemd-journal,adm alloy || true

echo "== enabling services =="
systemctl enable --now prometheus-node-exporter
systemctl enable --now alloy
systemctl is-active alloy prometheus-node-exporter

echo "== installing NetBird (connectivity to central) =="
curl -fsSL https://pkgs.netbird.io/install.sh | bash
netbird version

echo
echo "DONE. Remaining step (human): create a setup key in the NetBird UI, then"
echo "  netbird up --setup-key <KEY>"
echo "Verify afterwards: ping -c2 100.88.153.244"