# Kubespray Inventory Migration Design

**Date**: 2026-05-21  
**Topic**: Migrate current K8s cluster state into kubespray inventory  
**Kubespray version**: 2.32.0  

---

## Overview

Migrate the running K8s homelab cluster state into the `inventory/homelab-k8s/` kubespray inventory so that future kubespray runs will match (not conflict with) the current running configuration.

**Constraint**: Read-only migration — do not modify the running cluster. All changes are to inventory files only. Verify with `--check` (dry-run) after each set of changes.

---

## Current Cluster State (Discovered)

### Nodes

| Hostname | IP | Role | etcd name |
|---|---|---|---|
| talos-00 | 192.168.1.11 | control-plane + worker | etcd1 |
| talos-01 | 192.168.1.12 | control-plane + worker | etcd2 |
| talos-02 | 192.168.1.13 | control-plane + worker | etcd3 |

- OS: Ubuntu 24.04.4 LTS (amd64)
- SSH user: `ubuntu`, key: `~/ssh-keys/homelab-linux`
- Node names differ from default kubespray convention (talos-XX not node1/2/3)
- All nodes are **both control-plane and worker** (no taints, workloads on all nodes)

### Kubernetes

- Version: **v1.34.4**
- Container runtime: **containerd v2.2.1** (systemd cgroup, overlayfs snapshotter)
- etcd: **v3.5.27** deployed as host systemd service

### Networking

| Setting | Value |
|---|---|
| CNI | Calico v3.30.6 |
| Calico backend | VXLAN |
| VXLAN mode | Always |
| IPIP mode | Never |
| Pod subnet | 10.233.64.0/18 |
| Service subnet | 10.233.0.0/18 |
| Calico pool blocksize | 26 (/26 per node) |
| kube-proxy mode | ipvs |
| kube-proxy strictARP | true (required by metallb) |

### API Server Notable Flags

- `--request-timeout=120s` (kubespray default: `1m0s` → needs override)
- `--encryption-provider-config` set → secrets encryption enabled
- `--audit-policy-file` set → audit logging enabled
- `--profiling=False` → already default in kubespray
- `--authorization-mode=Node,RBAC` → standard
- `--tls-min-version=VersionTLS12`
- `--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305`

### Kubelet Notable Settings

- `cgroupDriver: systemd` (default in kubespray)
- `protectKernelDefaults: true`
- `rotateCertificates: true` + `serverTLSBootstrap: true`
- `shutdownGracePeriod: 60s` / `shutdownGracePeriodCriticalPods: 20s` (already kubespray defaults)
- `seccompDefault: true`
- `clusterDNS: [169.254.25.10]` (nodelocaldns — standard kubespray)
- `eviction-hard=nodefs.available<1%,imagefs.available<1%,nodefs.inodesFree<1%`
- **kube-reserved**: cpu=200m, memory=512Mi, ephemeral-storage=2Gi, pid=1000  
  (kubespray defaults: 100m/256Mi/500Mi/1000 — **differs, needs override**)
- **system-reserved**: cpu=250m, memory=256Mi, ephemeral-storage=2Gi, pid=1000  
  (kubespray defaults: 500m/512Mi/500Mi/1000 — **differs, needs override**)

### etcd Settings

All match kubespray defaults (`etcd_heartbeat_interval: 250`, `etcd_election_timeout: 5000`, `etcd_compaction_retention: 8`, `etcd_snapshot_count: 100000`, `etcd_quota_backend_bytes: 2147483648`, `etcd_max_request_bytes: 1572864`) — **no overrides needed**.

### DNS

- CoreDNS upstream: **192.168.1.3, 192.168.1.4** (Pi-hole)
- nodelocaldns bound to 169.254.25.10 (standard)

### Running Addons (kubespray-managed)

| Addon | Status | Notes |
|---|---|---|
| Calico CNI | ✅ Running | Managed via k8s-net-calico.yml |
| CoreDNS | ✅ Running | Standard |
| nodelocaldns | ✅ Running | Standard |
| dns-autoscaler | ✅ Running | Standard |
| kube-proxy | ✅ Running | Standard |
| **metrics-server** | ✅ Running | Needs enabling in addons.yml |
| **metallb** | ✅ Running | Needs enabling in addons.yml |
| **snapshot-controller** | ✅ Running | Needs enabling in addons.yml |

**External addons** (NOT kubespray-managed, leave as-is):
- Rancher (cattle-* namespaces)
- cert-manager (cert-manager namespace)
- portainer
- velero
- csi-nfs (NFS CSI driver)
- external-secrets
- traefik (ingress)
- kubelet-csr-approver

### MetalLB Configuration

- Pool name: `primary`
- IP range: `192.168.1.30-192.168.1.39`
- Protocol: L2 (Layer 2 advertisement)

---

## Inventory Files to Update

### 1. `inventory/homelab-k8s/inventory.ini`

**All nodes in both `kube_control_plane` and `kube_node` groups** (stacked topology, nodes serve both roles).

```ini
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
```

### 2. `group_vars/all/all.yml`

**Additions** (append to existing file):
- `ansible_user: ubuntu`
- `ansible_ssh_private_key_file: ~/ssh-keys/homelab-linux`
- `upstream_dns_servers: [192.168.1.3, 192.168.1.4]`

### 3. `group_vars/all/etcd.yml`

No changes needed — all etcd settings match kubespray defaults.

### 4. `group_vars/all/containerd.yml`

No changes needed — overlayfs snapshotter is already the kubespray default.

### 5. `group_vars/k8s_cluster/k8s-cluster.yml`

**Uncomment/change** these settings:
- `kube_encrypt_secret_data: true` (was false)
- `kubernetes_audit: true` (was false)
- `kube_proxy_strict_arp: true` (was false — required by metallb)
- `kube_reserved: true`
- `kube_memory_reserved: 512Mi` (override from 256Mi)
- `kube_cpu_reserved: 200m` (override from 100m)
- `kube_ephemeral_storage_reserved: 2Gi` (override from 500Mi)
- `kube_pid_reserved: 1000` (same as default — explicit for clarity)
- `system_reserved: true`
- `system_memory_reserved: 256Mi` (override from 512Mi)
- `system_cpu_reserved: 250m` (override from 500m)
- `system_ephemeral_storage_reserved: 2Gi` (override from 500Mi)
- `tls_min_version: VersionTLS12`
- `tls_cipher_suites` (3 ciphers matching running config)
- `kube_apiserver_request_timeout: "120s"` (override from 1m0s)
- `eviction_hard` with 1% thresholds

### 6. `group_vars/k8s_cluster/k8s-net-calico.yml`

**Uncomment/set**:
- `calico_network_backend: vxlan`
- `calico_vxlan_mode: 'Always'`
- `calico_ipip_mode: 'Never'`

### 7. `group_vars/k8s_cluster/addons.yml`

**Enable**:
- `metrics_server_enabled: true`
- `metrics_server_container_port: 4443` (running on 4443, not default 10250)
- `csi_snapshot_controller_enabled: true`
- `metallb_enabled: true`
- `metallb_speaker_enabled: true`
- `metallb_config` with primary pool (192.168.1.30-192.168.1.39), layer2

---

## Verification

After all inventory changes:
1. Run `ansible-playbook -i inventory/homelab-k8s/inventory.ini cluster.yml --check` to dry-run
2. Confirm zero changes proposed by Ansible (idempotent)
3. Repeat for addons-related plays if needed

---

## Approach Decision

**Direct file editing** — No new files or external tooling needed. Each file is updated surgically to reflect discovered cluster state, with commented explanations where values differ from kubespray defaults.
