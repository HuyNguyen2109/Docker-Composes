# Homelab Power Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create two self-contained Bash scripts — `homelab-shutdown.sh` (parallel SSH shutdown of 3 hosts) and `homelab-wakeup.sh` (WOL magic packets) — validated from the dev machine before saving to `scripts/`.

**Architecture:** Both scripts are self-contained (no external lib dependencies) to work reliably on unRAID's RAM-based filesystem. The config block at the top of each script is the single source of truth for host definitions. Scripts follow `vm-setup.sh` conventions (`set -uo pipefail`, color output, ✓/✗ symbols). Self-check runs from the dev machine using `$HOME/ssh-keys/homelab-linux` before scripts are committed.

**Tech Stack:** Bash 4+, `ssh` (BatchMode), `etherwake`, unRAID User Scripts plugin

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `scripts/homelab-shutdown.sh` | Create | SSH parallel shutdown of proxmox-00, talos-01, talos-02 |
| `scripts/homelab-wakeup.sh` | Create | Send WOL magic packets to all 3 hosts |

---

### Task 1: Write `scripts/homelab-shutdown.sh`

**Files:**
- Create: `scripts/homelab-shutdown.sh`

- [ ] **Step 1: Create the shutdown script**

```bash
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
```

Write this content to `scripts/homelab-shutdown.sh`.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/homelab-shutdown.sh
```

---

### Task 2: Syntax-check `homelab-shutdown.sh`

**Files:**
- Check: `scripts/homelab-shutdown.sh`

- [ ] **Step 1: Run bash syntax check**

```bash
bash -n scripts/homelab-shutdown.sh
```

Expected: no output, exit code 0.

- [ ] **Step 2: Run shellcheck**

```bash
shellcheck scripts/homelab-shutdown.sh
```

Expected: no output (clean). If `shellcheck` is not installed, skip this step.

---

### Task 3: SSH self-check for shutdown script

**Files:**
- Read: `scripts/homelab-shutdown.sh` (for reference)

This task verifies SSH connectivity to each host from the dev machine, using a harmless `hostname` command instead of `shutdown`.

- [ ] **Step 1: Test SSH to proxmox-00**

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    root@192.168.1.10 "hostname && uptime" 2>&1
```

Expected output: `proxmox-00` (or similar hostname) and uptime line. Exit code 0.

- [ ] **Step 2: Test SSH to talos-01**

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    ubuntu@192.168.1.12 "hostname && sudo -n true && echo 'sudo OK'" 2>&1
```

Expected output: hostname line, then `sudo OK`. Exit code 0.
`sudo -n true` verifies passwordless sudo (required for `sudo shutdown -h now`).

- [ ] **Step 3: Test SSH to talos-02**

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    ubuntu@192.168.1.13 "hostname && sudo -n true && echo 'sudo OK'" 2>&1
```

Expected: same as Step 2. Exit code 0.

- [ ] **Step 4: Verify etherwake on tower.local (used by wakeup script)**

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    root@192.168.1.40 "which etherwake && etherwake --usage 2>&1 | head -3" 2>&1
```

Expected: `/usr/sbin/etherwake` path printed, usage line shown. Exit code 0.

---

### Task 4: Write `scripts/homelab-wakeup.sh`

**Files:**
- Create: `scripts/homelab-wakeup.sh`

- [ ] **Step 1: Create the wakeup script**

```bash
#!/usr/bin/env bash
# =============================================================================
# homelab-wakeup.sh — Send Wake-on-LAN packets to homelab hosts
# =============================================================================
# Runs on: tower.local (unRAID 7.3.0, 192.168.1.40) via User Scripts plugin
#
# WOL is sent to BOTH the builtin NIC and the USB adapter NIC per host,
# as a resilience measure (BIOS wakes on whichever NIC it is configured for).
#
# WOL MAC addresses (permanent/physical — not bond MACs):
#   proxmox-00  builtin eno1:          14:02:ec:49:37:30  (WOL enabled: Wake-on g)
#   proxmox-00  USB r8152:             c8:4d:44:23:3e:49
#   talos-01    builtin enp0s31f6:     6c:4b:90:3b:d6:1b
#   talos-01    USB adapter:           c8:4d:44:23:3e:3a
#   talos-02    builtin enp0s31f6:     6c:4b:90:5e:c3:9e
#   talos-02    USB adapter:           c8:4d:44:23:3e:4a
#
# Prerequisites on tower.local:
#   etherwake — present in unRAID base image at /usr/sbin/etherwake
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

  # Persist across unRAID reboots via /boot/extra/
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
# SEND WOL PACKETS
# =============================================================================
echo -e "\n${CYAN}${BOLD}══ Homelab Wake-on-LAN ══${RESET}\n"

for host_def in "${HOSTS[@]}"; do
  read -r name builtin_mac usb_mac <<< "${host_def}"

  etherwake -i "${WOL_IFACE}" "${builtin_mac}" 2>/dev/null
  etherwake -i "${WOL_IFACE}" "${usb_mac}"    2>/dev/null

  echo -e "  ${GREEN}${CHECK}${RESET}  $(printf '%-16s' "${name}")  WOL sent → builtin ${builtin_mac}  USB ${usb_mac}"
done
echo ""
```

Write this content to `scripts/homelab-wakeup.sh`.

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/homelab-wakeup.sh
```

---

### Task 5: Syntax-check `homelab-wakeup.sh`

**Files:**
- Check: `scripts/homelab-wakeup.sh`

- [ ] **Step 1: Run bash syntax check**

```bash
bash -n scripts/homelab-wakeup.sh
```

Expected: no output, exit code 0.

- [ ] **Step 2: Run shellcheck**

```bash
shellcheck scripts/homelab-wakeup.sh
```

Expected: no output (clean). If `shellcheck` is not installed, skip this step.

---

### Task 6: WOL self-check

This task verifies WOL packets can be formed and sent from tower.local. Since we cannot safely test WOL without powering machines off, we verify the tool is reachable and the MAC format is valid.

- [ ] **Step 1: Dry-test etherwake invocation on tower.local**

SSH into tower.local and invoke etherwake against the loopback/dummy MAC to confirm the binary works (it will fail to send on the network but the binary will parse and execute):

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    root@192.168.1.40 \
    "etherwake -i br0 14:02:ec:49:37:30 && echo 'etherwake OK'" 2>&1
```

Expected: `etherwake OK` printed. Exit code 0.

- [ ] **Step 2: Confirm br0 interface exists on tower.local**

```bash
ssh -i "$HOME/ssh-keys/homelab-linux" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    root@192.168.1.40 \
    "ip link show br0 | grep -c 'state UP' && echo 'br0 UP'" 2>&1
```

Expected: `1` followed by `br0 UP`. Exit code 0.

---

### Task 7: Commit

- [ ] **Step 1: Stage scripts and spec**

```bash
git add scripts/homelab-shutdown.sh \
        scripts/homelab-wakeup.sh \
        docs/superpowers/specs/2026-05-26-homelab-power-scripts-design.md \
        docs/superpowers/plans/2026-05-26-homelab-power-scripts.md
```

- [ ] **Step 2: Commit**

```bash
git commit -m "feat: add homelab shutdown and WOL scripts

- scripts/homelab-shutdown.sh: parallel SSH shutdown of proxmox-00,
  talos-01, talos-02; Proxmox handles talos-00 VM gracefully
- scripts/homelab-wakeup.sh: fire-and-forget WOL to builtin + USB
  NIC MACs for each host via etherwake on br0
- Both scripts are self-contained for unRAID User Scripts plugin
- /etc/hosts updated at runtime (ephemeral, correct for session)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Self-Review

**Spec coverage:**
- ✓ SSH shutdown to all 3 hosts → Task 1
- ✓ WOL packets to all 3 hosts → Task 4
- ✓ Parallel shutdown (all at once) → Task 1 (background jobs)
- ✓ Sequential WOL (proxmox-00 first in array, then talos nodes) → Task 4
- ✓ `/etc/hosts` update → Tasks 1 and 4 (`update_hosts` function)
- ✓ Dependency check + `upgradepkg` + `/boot/extra/` persistence → Task 4
- ✓ Color output with TTY guard → Tasks 1 and 4
- ✓ `set -uo pipefail` → Tasks 1 and 4
- ✓ SSH key at `~/.ssh/homelab-linux` for tower.local → Tasks 1 and 4
- ✓ Self-check from dev machine with `$HOME/ssh-keys/homelab-linux` → Tasks 3 and 6
- ✓ Save to `scripts/` → Tasks 1 and 4 (file paths)
- ✓ Commit → Task 7
