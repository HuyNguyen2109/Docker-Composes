# Kubespray Inventory Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the kubespray `inventory/homelab-k8s/` directory so it accurately reflects the running 3-node K8s cluster (v1.34.4), enabling future kubespray runs to be idempotent against the cluster.

**Architecture:** Read cluster state via kubectl/SSH → update inventory files surgically → dry-run `--check` to verify zero drift. No cluster changes are made. All modifications are confined to `inventory/homelab-k8s/`.

**Tech Stack:** Ansible/Kubespray v2.32.0, Kubernetes v1.34.4, Calico v3.30.6, containerd v2.2.1, etcd v3.5.27. SSH user `ubuntu`, key at `~/ssh-keys/homelab-linux`.

---

## Files Modified

| File | Change |
|---|---|
| `inventory/homelab-k8s/inventory.ini` | Rewrite: populate all 3 nodes with correct host vars |
| `inventory/homelab-k8s/group_vars/all/all.yml` | Add: ansible SSH settings, upstream DNS |
| `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml` | Update: encryption, audit, proxy strictARP, reserved resources, TLS, eviction, request timeout |
| `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-net-calico.yml` | Update: VXLAN backend/mode |
| `inventory/homelab-k8s/group_vars/k8s_cluster/addons.yml` | Update: enable metrics-server, metallb, snapshot-controller |

All paths are relative to `/root/workspace/My-DevOps/k8s/k8s-setups/kubespray/`.

---

### Task 1: Populate `inventory.ini` with cluster nodes

**Files:**
- Modify: `inventory/homelab-k8s/inventory.ini`

- [ ] **Step 1: Verify current node state before writing**

```bash
kubectl get nodes -o wide --no-headers
```

Expected output shows 3 nodes — talos-00 (192.168.1.11), talos-01 (192.168.1.12), talos-02 (192.168.1.13) — all Ready, all control-plane role.

- [ ] **Step 2: Rewrite inventory.ini with all nodes**

Replace the entire content of `inventory/homelab-k8s/inventory.ini` with:

```ini
# Homelab K8s cluster — 3-node stacked control-plane topology.
# All nodes are control-plane AND workers (no taints, no dedicated workers).
# etcd runs as a host systemd service on all control-plane nodes.
# SSH: user=ubuntu, key=~/ssh-keys/homelab-linux (set in group_vars/all/all.yml)

[kube_control_plane]
talos-00 ansible_host=192.168.1.11  ip=192.168.1.11  etcd_member_name=etcd1
talos-01 ansible_host=192.168.1.12  ip=192.168.1.12  etcd_member_name=etcd2
talos-02 ansible_host=192.168.1.13  ip=192.168.1.13  etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[kube_node:children]
kube_control_plane

[k8s_cluster:children]
kube_control_plane
kube_node

[calico_rr]

[vault]
```

- [ ] **Step 3: Verify inventory parses cleanly**

From the kubespray directory (`/root/workspace/My-DevOps/k8s/k8s-setups/kubespray/`):

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
python3 -m venv ../python-env 2>/dev/null || true
source ../python-env/bin/activate 2>/dev/null || true
pip install -q -r requirements.txt 2>/dev/null || true
ansible-inventory -i inventory/homelab-k8s/inventory.ini --list 2>&1 | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('Control plane:', d['kube_control_plane']['hosts'])
print('kube_node:', d['kube_node']['hosts'])
print('etcd:', d['etcd']['hosts'])
"
```

Expected: all three nodes listed in kube_control_plane, kube_node, and etcd groups.

- [ ] **Step 4: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/inventory.ini
git commit -m "feat(kubespray): populate inventory.ini with homelab cluster nodes

3-node stacked control-plane: talos-00/01/02 at 192.168.1.11-13
All nodes serve as both control-plane and worker.
etcd deployed as host service (etcd1/2/3 member names).

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Add SSH settings and upstream DNS to `group_vars/all/all.yml`

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/all/all.yml`

- [ ] **Step 1: Verify SSH connectivity**

```bash
ssh -i ~/ssh-keys/homelab-linux -o StrictHostKeyChecking=no ubuntu@192.168.1.11 "hostname && whoami"
```

Expected output: `talos-00` and `ubuntu`.

- [ ] **Step 2: Add SSH and DNS settings to the top of all.yml**

Insert after the opening `---` line (before `## Directory where the binaries will be installed`):

```yaml
## Ansible SSH connection settings
ansible_user: ubuntu
ansible_ssh_private_key_file: ~/ssh-keys/homelab-linux

## Upstream DNS servers (Pi-hole instances on the homelab network)
## CoreDNS forwards external queries to these resolvers.
upstream_dns_servers:
  - 192.168.1.3
  - 192.168.1.4

```

- [ ] **Step 3: Verify ansible can reach all nodes**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
source ../python-env/bin/activate 2>/dev/null || true
ansible -i inventory/homelab-k8s/inventory.ini all -m ping 2>&1 | tail -15
```

Expected: all 3 nodes respond with `pong`.

- [ ] **Step 4: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/all/all.yml
git commit -m "feat(kubespray): add SSH connection and upstream DNS settings

- ansible_user: ubuntu, key: ~/ssh-keys/homelab-linux
- upstream_dns_servers: 192.168.1.3, 192.168.1.4 (Pi-hole)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Update `k8s-cluster.yml` — security and proxy settings

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml`

These settings are currently defaulted to `false` in kubespray but are `true` in the running cluster.

- [ ] **Step 1: Verify running state for each setting**

```bash
# Encryption at rest — should see --encryption-provider-config in API server args
kubectl get pod kube-apiserver-talos-00 -n kube-system -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep encryption

# Audit logging — should see --audit-policy-file
kubectl get pod kube-apiserver-talos-00 -n kube-system -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep audit

# kube-proxy strictARP — should be true
kubectl get cm kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' | grep strictARP
```

Expected: encryption-provider-config path present, audit-policy-file present, `strictARP: true`.

- [ ] **Step 2: Update k8s-cluster.yml — encryption, audit, strictARP**

Change these three lines in `k8s-cluster.yml`:

Change `kube_encrypt_secret_data: false` to:
```yaml
## Encrypting Secret Data at Rest — ENABLED on this cluster
kube_encrypt_secret_data: true
```

Change `kubernetes_audit: false` to:
```yaml
# audit log for kubernetes — ENABLED on this cluster
kubernetes_audit: true
```

Change `kube_proxy_strict_arp: false` to:
```yaml
# configure arp_ignore and arp_announce — REQUIRED for MetalLB Layer2
kube_proxy_strict_arp: true
```

- [ ] **Step 3: Update kube_apiserver_request_timeout**

The running cluster uses `--request-timeout=120s` (kubespray default is `1m0s`). Add after the `kube_apiserver_port: 6443` line:

```yaml
# Override default 1m0s — running cluster uses 120s
kube_apiserver_request_timeout: "120s"
```

- [ ] **Step 4: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml
git commit -m "feat(kubespray): enable encryption, audit, metallb strictARP, request timeout

- kube_encrypt_secret_data: true (secrets encrypted at rest)
- kubernetes_audit: true (audit logging active)
- kube_proxy_strict_arp: true (required by MetalLB layer2)
- kube_apiserver_request_timeout: 120s (override default 1m0s)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Update `k8s-cluster.yml` — TLS and eviction settings

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml`

- [ ] **Step 1: Verify running TLS and eviction settings**

```bash
# TLS settings from API server
kubectl get pod kube-apiserver-talos-00 -n kube-system -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -E "tls-min|tls-cipher"

# Eviction hard thresholds from kubelet env on a node
ssh -i ~/ssh-keys/homelab-linux -o StrictHostKeyChecking=no ubuntu@192.168.1.11 "sudo grep eviction /etc/kubernetes/kubelet.env"
```

Expected: `VersionTLS12`, 3 cipher suites, `eviction-hard=nodefs.available<1%,imagefs.available<1%,nodefs.inodesFree<1%`.

- [ ] **Step 2: Add TLS settings to k8s-cluster.yml**

Uncomment and update the TLS section (currently commented with `# tls_min_version: ""`):

```yaml
## Support tls min version, Possible values: VersionTLS10, VersionTLS11, VersionTLS12, VersionTLS13.
tls_min_version: "VersionTLS12"

## Support tls cipher suites.
tls_cipher_suites:
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
```

- [ ] **Step 3: Add eviction_hard settings**

Uncomment and update the eviction section (currently `# eviction_hard: {}`):

```yaml
## Eviction Thresholds — using aggressive 1% thresholds
## https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/#eviction-thresholds
eviction_hard:
  nodefs.available: "1%"
  nodefs.inodesFree: "1%"
  imagefs.available: "1%"
```

- [ ] **Step 4: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml
git commit -m "feat(kubespray): add TLS min version, cipher suites, eviction thresholds

- tls_min_version: VersionTLS12
- 3 cipher suites matching running API server and kubelet
- eviction_hard: 1% thresholds for nodefs, inodesFree, imagefs

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Update `k8s-cluster.yml` — reserved resources

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml`

- [ ] **Step 1: Verify reserved resources on a node**

```bash
ssh -i ~/ssh-keys/homelab-linux -o StrictHostKeyChecking=no ubuntu@192.168.1.11 \
  "sudo grep -A10 'Reserved\|reserved' /etc/kubernetes/kubelet-config.yaml"
```

Expected:
```
kubeReserved:
  cpu: "200m"
  memory: "512Mi"
  ephemeral-storage: "2Gi"
  pid: "1000"
systemReserved:
  cpu: "250m"
  memory: "256Mi"
  ephemeral-storage: "2Gi"
  pid: "1000"
```

- [ ] **Step 2: Enable kube_reserved and set values**

Uncomment and set (in the `## Whether to run kubelet...` section of k8s-cluster.yml):

```yaml
# Whether to run kubelet and container-engine daemons in a dedicated cgroup.
kube_reserved: true
## The following two items need to be set when kube_reserved is true
kube_reserved_cgroups_for_service_slice: kube.slice
kube_reserved_cgroups: "/{{ kube_reserved_cgroups_for_service_slice }}"
kube_memory_reserved: 512Mi
kube_cpu_reserved: 200m
kube_ephemeral_storage_reserved: 2Gi
kube_pid_reserved: "1000"
```

- [ ] **Step 3: Enable system_reserved and set values**

```yaml
## Optionally reserve resources for OS system daemons.
system_reserved: true
## The following two items need to be set when system_reserved is true
system_reserved_cgroups_for_service_slice: system.slice
system_reserved_cgroups: "/{{ system_reserved_cgroups_for_service_slice }}"
system_memory_reserved: 256Mi
system_cpu_reserved: 250m
system_ephemeral_storage_reserved: 2Gi
```

- [ ] **Step 4: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/k8s_cluster/k8s-cluster.yml
git commit -m "feat(kubespray): configure kube and system reserved resources

kube_reserved: cpu=200m, memory=512Mi, storage=2Gi, pid=1000
system_reserved: cpu=250m, memory=256Mi, storage=2Gi
Values reflect actual kubelet-config.yaml on running nodes.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: Update Calico network settings

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/k8s_cluster/k8s-net-calico.yml`

- [ ] **Step 1: Verify Calico backend mode**

```bash
# Check calico-config configmap
kubectl get cm calico-config -n kube-system -o jsonpath='{.data.calico_backend}'

# Check IPPool mode
kubectl get ippool default-pool -o jsonpath='{.spec.vxlanMode}'
kubectl get ippool default-pool -o jsonpath='{.spec.ipipMode}'
```

Expected: `vxlan`, `Always`, `Never`.

- [ ] **Step 2: Uncomment and set Calico VXLAN settings**

In `k8s-net-calico.yml`, uncomment and set these lines:

```yaml
# Set calico network backend: "bird", "vxlan" or "none"
calico_network_backend: vxlan

# IP in IP and VXLAN is mutually exclusive modes.
# set IP in IP encapsulation mode: "Always", "CrossSubnet", "Never"
calico_ipip_mode: 'Never'

# set VXLAN encapsulation mode: "Always", "CrossSubnet", "Never"
calico_vxlan_mode: 'Always'
```

- [ ] **Step 3: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/k8s_cluster/k8s-net-calico.yml
git commit -m "feat(kubespray): configure Calico VXLAN backend

calico_network_backend: vxlan
calico_vxlan_mode: Always
calico_ipip_mode: Never
Matches running cluster: VXLAN-only, no IPIP encapsulation.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 7: Enable running addons in `addons.yml`

**Files:**
- Modify: `inventory/homelab-k8s/group_vars/k8s_cluster/addons.yml`

- [ ] **Step 1: Verify running addons**

```bash
# Metrics server
kubectl get deployment metrics-server -n kube-system --no-headers

# MetalLB
kubectl get pods -n metallb-system --no-headers | awk '{print $1, $3}'

# Snapshot controller
kubectl get deployment snapshot-controller -n kube-system --no-headers

# MetalLB pool config
kubectl get ipaddresspool primary -n metallb-system -o jsonpath='{.spec.addresses}'
```

Expected: metrics-server 1/1 Running, metallb controller+speakers Running, snapshot-controller Running, pool `["192.168.1.30-192.168.1.39"]`.

- [ ] **Step 2: Enable metrics-server in addons.yml**

Change `metrics_server_enabled: false` to:

```yaml
# Metrics Server deployment — RUNNING on this cluster
metrics_server_enabled: true
metrics_server_container_port: 4443
metrics_server_kubelet_insecure_tls: true
metrics_server_metric_resolution: 15s
metrics_server_kubelet_preferred_address_types: "InternalIP,ExternalIP,Hostname"
```

- [ ] **Step 3: Enable snapshot controller in addons.yml**

Change `# csi_snapshot_controller_enabled: false` to:

```yaml
# CSI Volume Snapshot Controller — RUNNING on this cluster
csi_snapshot_controller_enabled: true
```

- [ ] **Step 4: Enable MetalLB in addons.yml**

Change `metallb_enabled: false` to:

```yaml
# MetalLB deployment — RUNNING on this cluster (Layer 2 mode)
metallb_enabled: true
metallb_speaker_enabled: "{{ metallb_enabled }}"
metallb_namespace: "metallb-system"
metallb_config:
  speaker:
    nodeselector:
      kubernetes.io/os: "linux"
    tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
  controller:
    nodeselector:
      kubernetes.io/os: "linux"
    tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
  address_pools:
    primary:
      ip_range:
        - 192.168.1.30-192.168.1.39
      auto_assign: true
  layer2:
    - primary
```

- [ ] **Step 5: Commit**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/kubespray/inventory/homelab-k8s/group_vars/k8s_cluster/addons.yml
git commit -m "feat(kubespray): enable running addons: metrics-server, metallb, snapshot-controller

- metrics_server_enabled: true (port 4443, insecure-tls, 15s resolution)
- csi_snapshot_controller_enabled: true
- metallb_enabled: true (layer2, pool primary 192.168.1.30-192.168.1.39)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 8: Dry-run verification — connectivity and facts

**Files:** none modified

- [ ] **Step 1: Set up Python env and install requirements**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
source ../python-env/bin/activate 2>/dev/null || python3 -m venv ../python-env && source ../python-env/bin/activate
pip install -q -r requirements.txt
```

Expected: no errors, ansible installed.

- [ ] **Step 2: Test ansible connectivity to all nodes**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible -i inventory/homelab-k8s/inventory.ini all -m ping
```

Expected: All 3 nodes return `pong`. Zero failures.

- [ ] **Step 3: Gather facts from all nodes**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible -i inventory/homelab-k8s/inventory.ini all -m setup -a "filter=ansible_distribution*" 2>&1 | grep -A3 "ansible_distribution"
```

Expected: Ubuntu 24.04 reported for all nodes.

---

### Task 9: Dry-run `cluster.yml` — verify inventory matches running state

**Files:** none modified

> **IMPORTANT**: `--check` mode is read-only. It predicts what Ansible *would* change without making any actual modifications to the cluster. A "changed" result means the inventory doesn't yet match the running state — **do not run without `--check`**.

- [ ] **Step 1: Dry-run the cluster playbook (facts-only pass)**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible-playbook \
  -i inventory/homelab-k8s/inventory.ini \
  cluster.yml \
  --check \
  --tags=facts \
  -v 2>&1 | tail -30
```

Expected: Tasks complete, no unreachable hosts, minimal or zero changes.

- [ ] **Step 2: Dry-run focused on network and container runtime**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible-playbook \
  -i inventory/homelab-k8s/inventory.ini \
  cluster.yml \
  --check \
  --tags=network,container-engine \
  -v 2>&1 | grep -E "TASK|changed|ok|failed|unreachable" | tail -40
```

Expected: Most tasks `ok` (no changes), zero `failed`, zero `unreachable`.

- [ ] **Step 3: Dry-run focused on kubernetes master components**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible-playbook \
  -i inventory/homelab-k8s/inventory.ini \
  cluster.yml \
  --check \
  --tags=master \
  -v 2>&1 | grep -E "TASK|changed|ok|failed|unreachable" | tail -40
```

Expected: Most tasks `ok`, zero `failed`, zero `unreachable`. A few `changed` on cert/config items is acceptable if the dry-run reports it would only update non-critical metadata.

- [ ] **Step 4: Dry-run addons**

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible-playbook \
  -i inventory/homelab-k8s/inventory.ini \
  cluster.yml \
  --check \
  --tags=apps \
  -v 2>&1 | grep -E "TASK|changed|ok|failed|unreachable" | tail -40
```

Expected: Addon tasks show `ok` or `changed` (acceptable since addons were installed externally with potentially different templating). Zero `failed`, zero `unreachable`.

- [ ] **Step 5: Record any remaining drift**

If any tasks still show `changed`, document them:

```bash
cd /root/workspace/My-DevOps/k8s/k8s-setups/kubespray
ansible-playbook \
  -i inventory/homelab-k8s/inventory.ini \
  cluster.yml \
  --check \
  -v 2>&1 | grep "^changed:" | sort | uniq -c | sort -rn | head -20
```

Document any remaining drift items in the commit message.

---

### Task 10: Commit design doc, plan, and final state

**Files:**
- `docs/superpowers/specs/2026-05-21-kubespray-inventory-migration-design.md`
- `docs/superpowers/plans/2026-05-21-kubespray-inventory-migration.md`

- [ ] **Step 1: Commit documentation**

```bash
cd /root/workspace/My-DevOps
git add docs/superpowers/specs/2026-05-21-kubespray-inventory-migration-design.md
git add docs/superpowers/plans/2026-05-21-kubespray-inventory-migration.md
git commit -m "docs: add kubespray inventory migration design and implementation plan

Captures full cluster state discovered during migration:
- 3-node stacked control-plane (talos-00/01/02)
- Kubernetes v1.34.4, Calico v3.30.6 VXLAN, containerd v2.2.1
- MetalLB layer2, metrics-server, snapshot-controller addons

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

- [ ] **Step 2: Squash all feature commits into one**

```bash
cd /root/workspace/My-DevOps
# Count commits since last push
git log --oneline origin/HEAD..HEAD 2>/dev/null | head -20
# Squash all into one commit
git log --oneline | head -20
```

Then interactively squash (or rebase) all inventory migration commits:

```bash
# Find number of commits to squash (count all commits in this session)
N=$(git log --oneline origin/HEAD..HEAD 2>/dev/null | wc -l)
git rebase -i HEAD~${N}
```

In the editor, mark the first commit as `pick` and all others as `squash` (or `s`). Use this commit message:

```
feat(kubespray): migrate homelab K8s cluster state to inventory

Discovered cluster state via kubectl + SSH and updated
inventory/homelab-k8s/ to match:

Cluster:
  - 3-node stacked control-plane: talos-00/01/02 (192.168.1.11-13)
  - K8s v1.34.4, containerd v2.2.1, etcd v3.5.27 (host service)
  - All nodes are both control-plane and worker (no taints)

Networking:
  - Calico v3.30.6, VXLAN backend, mode Always, IPIP Never
  - Pod CIDR: 10.233.64.0/18, Service CIDR: 10.233.0.0/18
  - kube-proxy: ipvs + strictARP=true (MetalLB requirement)

Security:
  - Secrets encryption at rest enabled
  - Audit logging enabled
  - TLS min: VersionTLS12, 3 cipher suites

Resources:
  - kube_reserved: cpu=200m, memory=512Mi, storage=2Gi
  - system_reserved: cpu=250m, memory=256Mi, storage=2Gi
  - eviction_hard: 1% thresholds

Addons enabled:
  - metrics-server (port 4443, kubelet-insecure-tls)
  - metallb layer2 (pool: 192.168.1.30-192.168.1.39)
  - csi snapshot-controller

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

- [ ] **Step 3: Push to remote**

```bash
cd /root/workspace/My-DevOps
git push origin HEAD
```

---

## Self-Review Checklist

- [x] **inventory.ini**: All 3 nodes with correct IPs, etcd member names, dual kube_control_plane+kube_node membership
- [x] **SSH settings**: ansible_user + key path in all.yml
- [x] **DNS**: upstream_dns_servers set to Pi-hole addresses
- [x] **Encryption**: kube_encrypt_secret_data: true
- [x] **Audit**: kubernetes_audit: true
- [x] **Proxy**: kube_proxy_strict_arp: true + ipvs mode already set
- [x] **API timeout**: kube_apiserver_request_timeout: 120s
- [x] **TLS**: min version + cipher suites matching running config
- [x] **Eviction**: 1% thresholds set
- [x] **Reserved resources**: both kube_reserved and system_reserved with actual values
- [x] **Calico**: VXLAN backend, mode, and IPIP mode
- [x] **metrics-server**: enabled with port 4443
- [x] **metallb**: enabled with actual IP pool and L2 advertisement
- [x] **snapshot-controller**: enabled
- [x] **Dry-run**: verification steps included after each logical group of changes
- [x] **Squash commits**: final task squashes into single commit per user preference
