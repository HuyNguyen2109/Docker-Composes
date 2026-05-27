#!/usr/bin/env bash
# =============================================================================
# homelab-wakeup.sh — Send Wake-on-LAN packets to homelab hosts
# =============================================================================
# Runs on: tower.local (unRAID 7.3.0, 192.168.1.40) via User Scripts plugin
#
# WOL is sent to BOTH the builtin NIC and the USB adapter NIC per host,
# as a resilience measure (BIOS wakes on whichever NIC it is configured for).
#
# WOL MAC addresses — use the MAC the NIC is actually programmed with at runtime:
#
#   proxmox-00  builtin eno1 (igb):  14:02:ec:49:37:30  (permanent MAC, no bond override)
#   proxmox-00  USB r8152:           c8:4d:44:23:3e:49
#
#   talos-01    builtin enp0s31f6:   6c:4b:90:3b:d6:1b  (permanent MAC — correct)
#               bond mode active-backup, fail_over_mac=none, bond MAC 8a:c0:fc:36:31:75
#               WOL always targets the NIC's burned-in hardware MAC (unaffected by bonding)
#   talos-01    USB adapter:         c8:4d:44:23:3e:3a
#
#   talos-02    builtin enp0s31f6:   6c:4b:90:5e:c3:9e  (permanent MAC — correct)
#               bond mode active-backup WITH fail_over_mac active — each NIC keeps
#               its own permanent MAC, so WOL to permanent MAC works.
#   talos-02    USB adapter:         c8:4d:44:23:3e:4a
#
# Prerequisites on tower.local:
#   etherwake — present in unRAID base image at /usr/sbin/etherwake
#
# Prerequisites on each TARGET host (one-time setup):
#   BIOS/UEFI → Power Management → Wake on LAN: ENABLED
#   (Without this, WOL packets are silently ignored at hardware level)
#   No OS-level WOL persistence is needed — WOL flag is retained by the BIOS/NIC.
# =============================================================================

set -uo pipefail

# =============================================================================
# HOST CONFIG — edit here if MACs change
# =============================================================================
# Format: "name builtin_mac usb_mac"
HOSTS=(
  "proxmox-00  14:02:ec:49:37:30  c8:4d:44:23:3e:49"
  "talos-01    6c:4b:90:3b:d6:1b  c8:4d:44:23:3e:3a"
  "talos-02    6c:4b:90:5e:c3:9e  c8:4d:44:23:3e:4a"
)
WOL_IFACE="br0"

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
ensure_etherwake() {
  if command -v etherwake &>/dev/null; then
    return 0
  fi

  echo -e "${YELLOW}${WARN}  etherwake not found — searching Slackware repository...${RESET}"

  # net-tools package contains ether-wake on Slackware 15.0 x86_64
  local pkg_url pkg_file
  pkg_url="https://slackware.uk/slackware/slackware64-15.0/slackware64/n/net-tools-2.10-x86_64-1.txz"
  pkg_file="/tmp/net-tools-2.10-x86_64-1.txz"

  if ! command -v curl &>/dev/null; then
    echo -e "${RED}${CROSS}  curl not found; cannot download package.${RESET}" >&2
    exit 1
  fi

  echo -e "  Downloading: ${pkg_url}"
  if ! curl -fsSL --connect-timeout 15 -o "${pkg_file}" "${pkg_url}"; then
    echo -e "${RED}${CROSS}  Download failed.${RESET}" >&2
    exit 1
  fi

  upgradepkg --install-new "${pkg_file}"

  # Persist across unRAID reboots — packages in /boot/extra/ are auto-installed on boot
  mkdir -p /boot/extra
  cp "${pkg_file}" /boot/extra/
  rm -f "${pkg_file}"

  if ! command -v etherwake &>/dev/null; then
    echo -e "${RED}${CROSS}  etherwake still not found after install. Cannot continue.${RESET}" >&2
    exit 1
  fi

  echo -e "${GREEN}${CHECK}  etherwake installed and persisted to /boot/extra/${RESET}"
}
ensure_etherwake

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
# SEND WOL PACKETS (fire-and-forget, 3 bursts per NIC for UDP reliability)
# =============================================================================
echo -e "\n${CYAN}${BOLD}══ Homelab Wake-on-LAN ══${RESET}\n"

for host_def in "${HOSTS[@]}"; do
  read -r name builtin_mac usb_mac <<< "${host_def}"

  for _burst in 1 2 3; do
    etherwake -i "${WOL_IFACE}" "${builtin_mac}" 2>/dev/null
    etherwake -i "${WOL_IFACE}" "${usb_mac}"    2>/dev/null
    sleep 1
  done

  echo -e "  ${GREEN}${CHECK}${RESET}  $(printf '%-16s' "${name}")  WOL sent (×3) → builtin ${builtin_mac}  USB ${usb_mac}"
done
echo ""
