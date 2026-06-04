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
  + talos-cloud-00 (14.225.220.145) & talos-cloud-01 (103.167.150.158): user root, SSH key auth and stored at $HOME/ssh-key/oracle, password auth disabled

## Repository Overview

Personal homelab DevOps monorepo. Three main layers:

1. **`scripts/vm-setup.sh`** — Cross-distro VM/VPS provisioning Bash script (~1100 lines)
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

## `shellcheck` 

`vm-setup.sh` must remain shellcheck-clean. Check with:
```bash
shellcheck scripts/vm-setup.sh
```

## Design Docs

Specs and implementation plans live in `docs/superpowers/specs/` and `docs/superpowers/plans/` (date-prefixed filenames, e.g. `2026-05-21-vm-setup-script-design.md`).
