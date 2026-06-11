# Copilot Instructions

## Overall
- This repository is a personal homelab DevOps monorepo with scripts, Kubernetes manifests, Terraform configs, and Docker Swarm stacks.
- The main cluster information:
  + proxmox-00 (bare-metal hypervisor): user root, IP: 192.168.1.10, SSH key auth, no password login
  + kubernetes cluster: 3-node stacked control-plane (all nodes are control-plane + worker), SSH-key stored at $HOME/ssh-keys/homelab-linux:
    * talos-00 (VM): user ubuntu, IP: 192.168.1.11, SSH key auth, password login disabled
    * talos-01 (bare-metal): user ubuntu, IP: 192.168.1.12, SSH key auth, password login disabled
    * talos-02 (bare-metal): user ubuntu, IP: 192.168.1.13, SSH key auth, password login disabled
  + tower.local (unRAID server): user root, IP: 192.168.1.40, password login enabled, password stored at $HOME/ssh-keys/.unraid-password.txt
  + talos-cloud-00 (14.225.220.145) & talos-cloud-01 (103.167.150.158): user root, SSH key auth and stored at $HOME/ssh-keys/oracle, password auth disabled

## Repository Overview

Personal homelab DevOps monorepo. Main components:

1. **`scripts/`** — Bash scripts for homelab management (detailed below)
   - `vm-setup.sh` — Cross-distro VM/VPS provisioning (~1100 lines)
   - `homelab-shutdown.sh` — Graceful parallel SSH shutdown of homelab hosts
   - `homelab-wakeup.sh` — Wake-on-LAN for homelab hosts
   - `three-month-ups-battery-test.sh` — NUT-based UPS deep battery test automation
2. **`k8s/`** — Kubernetes manifests and Helm values, deployed via ArgoCD from the `develop` branch
3. **`terraform/proxmox-provision-ubuntu-k8s/`** — Proxmox VM provisioning via Terraform Cloud + HashiCorp Vault
4. **`docker/`** — Docker Swarm stack definitions

## Branch Convention

ArgoCD syncs from the **`develop`** branch (`targetRevision: develop` in all `k8s/argocd/apps/*.yaml`). Commits intended for the cluster must land on `develop`.

## Secrets Architecture

All secrets flow through **HashiCorp Vault**:

- **Terraform** reads credentials via the `vault` provider (`vault.mcb-svc.work`), path `kubernetes/terraform`
- **Kubernetes** pulls secrets via **External Secrets Operator (ESO)** using a `ClusterSecretStore` named `vault-backend` backed by Vault (`vault.mcb-homelab.com`), KV v2, path prefix `kubernetes/`
- ESO authenticates via Kubernetes auth (mount path `kubernetes`, role `eso-role`, SA `vault-auth` in `kube-system`)
- New application secrets: add an `ExternalSecret` referencing `vault-backend` and place it in the app's `manifests/` folder

## Kubernetes / ArgoCD Conventions

- Apps are defined in `k8s/argocd/apps/<app>.yaml` as `Application` CRDs pointing back to this repo
- Helm values live in `k8s/<app>/values/values.yaml`; raw manifests in `k8s/<app>/manifests/`
- Apps use the **`avp-helm`** ArgoCD plugin (Vault-aware Helm rendering) — values files may contain `<path:kubernetes/...#property>` placeholders
- Ingress class is **`traefik`**; TLS via **cert-manager** (`selfsigned-clusterissuer`)
- Persistent storage uses the **`longhorn`** StorageClass
- Target cluster name in ArgoCD: `homelab-cluster`; ArgoCD namespace: `administrator-apps`

## Kubernetes Cluster (Kubespray)

- Inventory: `k8s/k8s-setups/inventory/homelab-k8s/`
- Kubespray is a **git submodule** at `k8s/k8s-setups/kubespray` (upstream: `kubernetes-sigs/kubespray`)
- 3-node stacked control-plane topology — all nodes are both control-plane and workers (no taints)
- CNI: **Calico VXLAN**; CRI: **containerd**; etcd runs as host systemd service on all control-plane nodes
- After cloning, run: `git submodule update --init --recursive`

## Terraform Conventions

- Provider: `bpg/proxmox` (pin version in `required_providers`); `hashicorp/vault`
- Remote state + runs via **Terraform Cloud** (org: `Mcbourdeux-Homelab`, workspace: `Proxmox`)
- VMs defined via `var.vm_definitions` map in `terraform.tfvars`
- `sshpass` must be installed on the machine running Terraform for SSH provisioning

## `scripts/vm-setup.sh` Conventions

- Uses `set -uo pipefail` (not `set -e`); Bash 4+ required
- All commands wrapped with `run_cmd "<description>" <cmd> [args...]` — this handles spinner, logging on failure (non-fatal), and `TOTAL_ERRORS` tracking
- Failures are non-fatal by default (return code ignored with `|| true`); only Section 2 (system update) is explicitly fatal
- Temporary files registered in `TMP_FILES` array and cleaned by the `EXIT/INT/TERM/HUP` trap
- OS-specific logic uses `$OS_TYPE` (values: `debian`, `rhel`, `arch`, `suse`) and `$PKG_MGR`
- Install status tracked in `declare -A INSTALL_STATUS` and `declare -A INSTALL_VERSION`
- `kubectl` version extraction: `grep -o '"gitVersion": "[^"]*"' | head -1 | cut -d'"' -f4` (kubectl 1.28+ removed `--short`; 1.33 JSON has spaces after colon)
- Vault SHA256 verification: save zip with versioned filename; `grep "${VAULT_ZIP}" vault_SHA256SUMS | sha256sum --check --status`
- The script never pins versions — always installs the latest available at runtime

## `scripts/homelab-shutdown.sh` Conventions

- Gracefully shuts down proxmox-00, talos-01, and talos-02 **in parallel** via SSH
- Designed to run on **tower.local** (unRAID 7.3.0) via the User Scripts plugin
- Uses `~/.ssh/homelab-linux` SSH key for authentication
- Updates `/etc/hosts` idempotently (ephemeral on unRAID — correct for the session)
- Non-root users (ubuntu) get `sudo shutdown -h now`; root gets `shutdown -h now` directly
- Colorised terminal output (turns off when stdout is not a TTY)
- Usage: `scripts/homelab-shutdown.sh`

## `scripts/homelab-wakeup.sh` Conventions

- Sends Wake-on-LAN packets to proxmox-00, talos-01, and talos-02
- Designed to run on **tower.local** (unRAID 7.3.0) via the User Scripts plugin
- Sends WOL to **both** the builtin NIC and the USB adapter NIC per host (resilience)
- Sends **3 bursts** per NIC for UDP reliability
- Target interface: `br0`
- Auto-installs `etherwake` from Slackware repository if missing; persists via `/boot/extra/`
- Updates `/etc/hosts` idempotently (ephemeral on unRAID)
- WOL MAC addresses documented inline with bond/fail_over_mac considerations:
  - proxmox-00: builtin `14:02:ec:49:37:30`, USB `c8:4d:44:23:3e:49`
  - talos-01: bond MAC `8a:c0:fc:36:31:75` (both fields — bonded NICs use bond MAC only)
  - talos-02: builtin `6c:4b:90:5e:c3:9e`, USB `c8:4d:44:23:3e:4a`
- Usage: `scripts/homelab-wakeup.sh`

## `scripts/three-month-ups-battery-test.sh` Conventions

- Bi-weekly UPS deep battery test automation using **NUT (Network UPS Tools)**
- Uses native NUT instant commands: `test.battery.start.deep` and `test.battery.stop`
- **Stages**: Pre-flight → Start test → Monitor discharge → Stop test → Wait for OL → Finalise
- Pre-flight safety checks (Stage 0):
  - Verifies `upsc`/`upscmd` are installed and UPS is reachable
  - Confirms `test.battery.start.deep` / `test.battery.stop` are supported by the driver
  - Aborts if UPS status is OB (On Battery), LB (Low Battery), or FSD (Forced Shutdown)
  - Aborts if current battery charge is below `SAFETY_THRESHOLD` (80%)
  - Bi-weekly gate: aborts if last successful run was < 10 days ago
- Monitors `battery.charge` every `POLL_INTERVAL` (60s) until `STOP_PCT` (30%) or `TIMEOUT_SECS` (2h)
- Automatically calls `test.battery.stop` and waits up to `ONLINE_WAIT_SECS` (300s) for OL status
- Has a **cleanup trap** that sends `test.battery.stop` on unexpected exit
- Supports `--dry-run` mode to validate without sending actual commands
- **Prerequisites**: NUT user must have `instcmds = ALL` (or at minimum the two battery test commands)
- Config variables at top of script: `UPS_NAME`, `UPS_HOST`, `NUT_USER`, `NUT_PASS`, `STOP_PCT`, `POLL_INTERVAL`, etc.
- Usage: `scripts/three-month-ups-battery-test.sh [--dry-run]`

## `shellcheck` 

`vm-setup.sh` must remain shellcheck-clean. Check with:
```bash
shellcheck scripts/vm-setup.sh
```

## Design Docs

Specs and implementation plans live in `docs/superpowers/specs/` and `docs/superpowers/plans/` (date-prefixed filenames, e.g. `2026-05-21-vm-setup-script-design.md`).


<!-- headroom:rtk-instructions -->
# RTK (Rust Token Killer) - Token-Optimized Commands

When running shell commands, **always prefix with `rtk`**. This reduces context
usage by 60-90% with zero behavior change. If rtk has no filter for a command,
it passes through unchanged — so it is always safe to use.

## Key Commands
```bash
# Git (59-80% savings)
rtk git status          rtk git diff            rtk git log

# Files & Search (60-75% savings)
rtk ls <path>           rtk read <file>         rtk grep <pattern>
rtk find <pattern>      rtk diff <file>

# Test (90-99% savings) — shows failures only
rtk pytest tests/       rtk cargo test          rtk test <cmd>

# Build & Lint (80-90% savings) — shows errors only
rtk tsc                 rtk lint                rtk cargo build
rtk prettier --check    rtk mypy                rtk ruff check

# Analysis (70-90% savings)
rtk err <cmd>           rtk log <file>          rtk json <file>
rtk summary <cmd>       rtk deps                rtk env

# GitHub (26-87% savings)
rtk gh pr view <n>      rtk gh run list         rtk gh issue list

# Infrastructure (85% savings)
rtk docker ps           rtk kubectl get         rtk docker logs <c>

# Package managers (70-90% savings)
rtk pip list            rtk pnpm install        rtk npm run <script>
```

## Rules
- In command chains, prefix each segment: `rtk git add . && rtk git commit -m "msg"`
- For debugging, use raw command without rtk prefix
- `rtk proxy <cmd>` runs command without filtering but tracks usage
<!-- /headroom:rtk-instructions -->
