#!/usr/bin/env bash
# =============================================================================
# homelab-shutdown.sh — Gracefully shut down homelab hosts
# =============================================================================
# Runs on: tower.local (unRAID 7.3.0, 192.168.1.40) via User Scripts plugin
#
# Hosts shut down in parallel:
#   proxmox-00 (192.168.1.10) — Proxmox VE; handles talos-00 VM automatically
#   talos-01   (192.168.1.12) — bare-metal k8s node
#   talos-02   (192.168.1.13) — bare-metal k8s node
#
# Prerequisites on tower.local:
#   ~/.ssh/homelab-linux   — SSH private key
#   ubuntu sudo NOPASSWD   — required on talos-01 / talos-02
# =============================================================================

set -uo pipefail

# =============================================================================
# HOST CONFIG — edit here if IPs or users change
# =============================================================================
# Format: "name ip ssh_user"
HOSTS=(
  "proxmox-00  192.168.1.10  root"
  "talos-01    192.168.1.12  ubuntu"
  "talos-02    192.168.1.13  ubuntu"
)
SSH_KEY="${HOME}/.ssh/homelab-linux"

# =============================================================================
# COLORS (only when stdout is a terminal)
# =============================================================================
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi
CHECK="✓"; CROSS="✗"; WARN="⚠"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================
if ! command -v ssh &>/dev/null; then
  echo -e "${RED}${CROSS} ssh not found. Cannot continue.${RESET}" >&2
  exit 1
fi

# =============================================================================
# /etc/hosts UPDATE (idempotent; ephemeral on unRAID — correct for this session)
# =============================================================================
update_hosts() {
  local entries=(
    "192.168.1.10 proxmox-00"
    "192.168.1.12 talos-01"
    "192.168.1.13 talos-02"
  )
  for entry in "${entries[@]}"; do
    if ! grep -qF "${entry}" /etc/hosts; then
      echo "${entry}" >> /etc/hosts
    fi
  done
}
update_hosts

# =============================================================================
# PARALLEL SHUTDOWN
# =============================================================================
echo -e "\n${CYAN}${BOLD}══ Homelab Shutdown ══${RESET}\n"

declare -A PIDS
declare -A STATUS

for host_def in "${HOSTS[@]}"; do
  read -r name ip user <<< "${host_def}"

  if [[ "${user}" == "root" ]]; then
    remote_cmd="shutdown -h now"
  else
    remote_cmd="sudo shutdown -h now"
  fi

  (
    ssh -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${user}@${ip}" "${remote_cmd}" &>/dev/null
  ) &
  PIDS["${name}"]=$!
  echo -e "  ${YELLOW}${WARN}${RESET}  $(printf '%-16s' "${name}")  shutdown command sent..."
done

# Wait and collect per-host exit codes
for host_def in "${HOSTS[@]}"; do
  read -r name ip user <<< "${host_def}"
  if wait "${PIDS[${name}]}"; then
    STATUS["${name}"]="ok"
  else
    STATUS["${name}"]="fail"
  fi
done

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n  ${BOLD}$(printf '%-16s' 'Host')  Result${RESET}"
echo    "  ──────────────────────────────"
for host_def in "${HOSTS[@]}"; do
  read -r name ip user <<< "${host_def}"
  if [[ "${STATUS[${name}]:-fail}" == "ok" ]]; then
    echo -e "  ${GREEN}${CHECK}${RESET}  $(printf '%-16s' "${name}")  ${GREEN}shutdown sent${RESET}"
  else
    echo -e "  ${RED}${CROSS}${RESET}  $(printf '%-16s' "${name}")  ${RED}SSH failed (already down?)${RESET}"
  fi
done
echo ""
