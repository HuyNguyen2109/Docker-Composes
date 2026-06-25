# AGENTS.md — Workspace Guide for AI Coding Agents

This file describes the structure, conventions, and key context of the workspace
at `/root/workspace/My-DevOps`. Use it to orient yourself before making changes.

---

## Repository Type

This is a **personal homelab DevOps monorepo** containing:
- Bash provisioning scripts
- Kubernetes manifests (deployed via ArgoCD)
- Terraform configurations (Proxmox VM provisioning)
- Docker Swarm stack definitions

---

## Top-Level Directory Layout

```
.
├── AGENTS.md                          ← This file
├── README.md
├── LICENSE
├── .gitignore
├── .gitmodules
├── .github/
│   └── copilot-instructions.md        ← GitHub Copilot instructions (source for this file)
├── .thorclient/
├── scripts/
│   ├── vm-setup.sh                    ~1100-line cross-distro VM/VPS provisioning script
│   ├── homelab-shutdown.sh            Graceful parallel SSH shutdown of homelab hosts
│   ├── homelab-wakeup.sh              Wake-on-LAN for homelab hosts
│   └── three-month-ups-battery-test.sh  NUT-based UPS deep battery test automation
├── k8s/                               ← Kubernetes manifests + Helm values + ArgoCD apps
│   ├── argocd/apps/                   ← ArgoCD Application CRDs (one per app)
│   ├── k8s-setups/                    ← Kubespray inventory + git submodule
│   │   ├── inventory/homelab-k8s/     ← Kubespray inventory files
│   │   └── kubespray/                 ← Git submodule (kubernetes-sigs/kubespray)
│   └── <app>/
│       ├── values/values.yaml         ← Helm values (may have Vault placeholders)
│       └── manifests/                 ← Raw Kubernetes manifests
├── terraform/
│   └── proxmox-provision-ubuntu-k8s/  ← Proxmox VM provisioning (Terraform Cloud + Vault)
├── docker/                            ← Docker Swarm stack definitions
└── docs/
    └── superpowers/
        ├── specs/                     ← Design specs (date-prefixed, e.g. 2026-05-21-*)
        └── plans/                     ← Implementation plans (date-prefixed)
```

---

## Key Conventions

### Branch Strategy
- **`develop`** branch is the target for ArgoCD syncing. All cluster-bound commits
  must land on `develop`. ArgoCD apps reference `targetRevision: develop`.

### Secrets Architecture
- All secrets flow through **HashiCorp Vault**.
- **Kubernetes**: External Secrets Operator (ESO) via `ClusterSecretStore`
  named `vault-backend` pointing to `vault.mcb-homelab.com` (KV v2, prefix `kubernetes/`).
  ESO auth: Kubernetes auth mount at `kubernetes`, role `eso-role`, SA `vault-auth`
  in `kube-system`.
- **Terraform**: Reads credentials via the `vault` provider at `vault.mcb-svc.work`,
  path `kubernetes/terraform`.
- New app secrets: create an `ExternalSecret` referencing `vault-backend` in the
  app's `manifests/` folder.

### Kubernetes / ArgoCD
- Apps defined in `k8s/argocd/apps/<app>.yaml` → `Application` CRDs pointing back to this repo.
- Helm values in `k8s/<app>/values/values.yaml`; raw manifests in `k8s/<app>/manifests/`.
- ArgoCD plugin: **`avp-helm`** (Vault-aware Helm rendering). Values files may
  contain `<path:kubernetes/...#property>` placeholders.
- Ingress class: **`traefik`**; TLS via **cert-manager** (`selfsigned-clusterissuer`).
- Persistent storage: **`longhorn`** StorageClass.
- Target cluster name: `homelab-cluster`; ArgoCD namespace: `administrator-apps`.

### Kubernetes Cluster (Kubespray)
- 3-node stacked control-plane (all nodes = control-plane + worker, no taints).
- Inventory: `k8s/k8s-setups/inventory/homelab-k8s/`.
- CNI: **Calico VXLAN**; CRI: **containerd**; etcd runs as host systemd service.
- After cloning: `git submodule update --init --recursive`.

### Terraform
- Provider: `bpg/proxmox` + `hashicorp/vault` (pinned versions in `required_providers`).
- Remote state + runs via **Terraform Cloud** (org: `Mcbourdeux-Homelab`, workspace: `Proxmox`).
- VMs defined via `var.vm_definitions` map in `terraform.tfvars`.

### `scripts/vm-setup.sh` — Shell Script Conventions
- Uses `set -uo pipefail` (not `set -e`); Bash 4+ required.
- All commands wrapped with `run_cmd "<description>" <cmd> [args...]` (spinner,
  non-fatal error logging, `TOTAL_ERRORS` tracking).
- Failures are non-fatal by default (`|| true`); only **Section 2** (system update) is fatal.
- Temp files tracked in `TMP_FILES` array → cleaned by `EXIT/INT/TERM/HUP` trap.
- OS detection: `$OS_TYPE` (debian|rhel|arch|suse) + `$PKG_MGR`.
- Install status tracked in `INSTALL_STATUS` (assoc array) and `INSTALL_VERSION`.
- `kubectl` version extraction: `grep -o '"gitVersion": "[^"]*"' | head -1 | cut -d'"' -f4`
  (no `--short` flag; kubectl 1.33 JSON has spaces after colon).
- Vault SHA256: save zip with versioned filename; `grep "${VAULT_ZIP}" vault_SHA256SUMS | sha256sum --check --status`.
- The script **never pins versions** — always installs latest available at runtime.
- Must remain **shellcheck-clean**: `shellcheck scripts/vm-setup.sh`.

### `scripts/homelab-shutdown.sh`

Gracefully shuts down proxmox-00, talos-01, and talos-02 **in parallel** via SSH.

- **Design**: Runs on tower.local (unRAID 7.3.0) via the User Scripts plugin
- **Auth**: `~/.ssh/homelab-linux` SSH private key
- **Hosts defined inline**: proxmox-00 (root), talos-01 (ubuntu), talos-02 (ubuntu)
- Idempotently updates `/etc/hosts` (ephemeral on unRAID)
- Non-root users get `sudo shutdown -h now`; root gets `shutdown -h now`
- Parallel SSH via background `&` with PID tracking and per-host exit code collection
- Colorised summary table at the end (OK = green, fail = red with "already down?" hint)
- Usage: `scripts/homelab-shutdown.sh`

### `scripts/homelab-wakeup.sh`

Sends Wake-on-LAN packets to proxmox-00, talos-01, and talos-02.

- **Design**: Runs on tower.local (unRAID 7.3.0) via the User Scripts plugin
- Sends WOL to **both** the builtin NIC and the USB adapter NIC per host (resilience)
- **3 bursts** per NIC for UDP reliability; target interface: `br0`
- Auto-installs `etherwake` from Slackware repository if missing; persists via `/boot/extra/`
- WOL MAC addresses with bond/fail_over_mac edge cases documented inline:
  - proxmox-00: builtin `14:02:ec:49:37:30`, USB `c8:4d:44:23:3e:49`
  - talos-01: bond MAC `8a:c0:fc:36:31:75` (both fields — fail_over_mac=none, bond MAC only)
  - talos-02: builtin `6c:4b:90:5e:c3:9e`, USB `c8:4d:44:23:3e:4a` (fail_over_mac=active)
- Idempotently updates `/etc/hosts` (ephemeral on unRAID)
- Usage: `scripts/homelab-wakeup.sh`

### `scripts/three-month-ups-battery-test.sh`

Bi-weekly UPS deep battery exercise simulation via **NUT (Network UPS Tools)**.

- Uses native NUT instant commands: `test.battery.start.deep` / `test.battery.stop`
- **5-stage pipeline**:
  1. Pre-flight — dependency checks, UPS reachability, command support, status/charge validation, bi-weekly gate
  2. Start test — sends `test.battery.start.deep`, verifies UPS begins discharging
  3. Monitor — polls `battery.charge` every 60s until STOP_PCT (30%) or timeout (2h)
  4. Stop test — sends `test.battery.stop`
  5. Wait for OL — polls `ups.status` until Online (max 300s), then finalises
- Pre-flight abort conditions: OB, LB, FSD status; charge < 80%; last run < 10 days ago
- **Cleanup trap**: sends `test.battery.stop` on unexpected exit
- `--dry-run` mode validates without sending actual commands
- **NUT requirement**: user must have `instcmds = ALL` in `upsd.users`
- Config variables at top of script: `UPS_NAME`, `UPS_HOST`, `NUT_USER`, `NUT_PASS`, `STOP_PCT`, `POLL_INTERVAL`, `TIMEOUT_SECS`, `ONLINE_WAIT_SECS`, `SAFETY_THRESHOLD`, log/state file paths
- Usage: `scripts/three-month-ups-battery-test.sh [--dry-run]`

---

## Infrastructure Nodes

| Hostname        | Type              | User     | Auth                                     | Notes                           |
|-----------------|-------------------|----------|------------------------------------------|---------------------------------|
| proxmox-00      | Bare-metal hypervisor | root | SSH key (no password)                    | Proxmox host                    |
| talos-00        | VM (control-plane) | ubuntu  | SSH key @ `$HOME/ssh-keys/homelab-linux` | Kubernetes node                 |
| talos-01        | Bare-metal (CP)    | ubuntu  | SSH key @ `$HOME/ssh-keys/homelab-linux` | Kubernetes node                 |
| talos-02        | Bare-metal (CP)    | ubuntu  | SSH key @ `$HOME/ssh-keys/homelab-linux` | Kubernetes node                 |
| tower.local     | unRAID server      | root    | SSH key @ `$HOME/ssh-keys/homelab-linux` | Storage/NAS                     |
| talos-cloud-00  | Cloud VM           | root    | SSH key @ `$HOME/ssh-keys/oracle`        | Cloud node                      |

> **Note:** Actual IP addresses have been redacted; they are stored only in
> `.github/copilot-instructions.md`.

---

## Design Docs

Specs and implementation plans are in:
- `docs/superpowers/specs/` ← design specifications
- `docs/superpowers/plans/`  ← implementation plans

Filenames are date-prefixed: `YYYY-MM-DD-<topic>.md`.

---

## Agent Conventions

1. **RTK awareness**: The project uses `rtk` (Rust Token Killer) to prefix commands
   for reduced context usage. See `.github/copilot-instructions.md` for the full
   RTK reference. When running shell commands in this repo, prefer `rtk`-prefixed
   commands where applicable.
2. **Shellcheck**: The `vm-setup.sh` script must stay shellcheck-clean.
3. **Develop branch**: All commits intended for cluster deployment must target `develop`.
4. **Vault placeholders**: Helm values may contain `<path:kubernetes/...#property>`
   syntax resolved by the `avp-helm` ArgoCD plugin.