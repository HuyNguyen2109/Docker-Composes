# K8s Cluster Restructure — Design Spec

**Date**: 2026-07-14
**Status**: Draft
**Approach**: A — Phased Kubespray + Manual etcd Migration

---

## 1. Goal

Restructure the homelab K8s cluster from a 3-node stacked control-plane topology to a
1 control-plane + 3 worker separated topology, with etcd decoupled for Patroni.

### Current State
```
talos-00 (192.168.1.11) — CP + worker + etcd
talos-01 (192.168.1.12) — CP + worker + etcd
talos-02 (192.168.1.13) — CP + worker + etcd
```
- 3-node stacked control-plane (HA)
- etcd: 3-node cluster, shared by K8s AND Patroni PostgreSQL HA
- API server endpoint: `https://192.168.1.14:6443` (VIP)
- HAProxy on each node: K8s LB on 6444, Patroni on 6432/6433, Rancher on 3001, Authentik on 9443
- K8s v1.34.4, Ubuntu 24.04.4, containerd v2.2.1, Calico VXLAN

### Target State
```
talos-alpha (192.168.1.10) — CP only + etcd (K8s state)
talos-00   (192.168.1.11) — worker only + etcd (Patroni, decoupled from K8s)
talos-01   (192.168.1.12) — worker only + etcd (Patroni, decoupled from K8s)
talos-02   (192.168.1.13) — worker only + etcd (Patroni, decoupled from K8s)
```
- 1 control-plane (no HA — intentional)
- etcd split: talos-alpha has K8s-only etcd; talos-00/01/02 keep etcd for Patroni
- HAProxy on all nodes, K8s backend updated to talos-alpha:6443 only

---

## 2. Constraints

- **No destruction**: All existing workloads, PVs, secrets must survive
- **Patroni continuity**: 3-node etcd on talos-00/01/02 must keep running
- **Single CP is intentional**: User accepts loss of HA
- **talos-alpha is pre-provisioned**: Ubuntu 24.04, SSH key `~/ssh-keys/homelab-linux`
- **Kubespray manages cluster going forward**: Inventory at `k8s/k8s-setups/inventory/homelab-k8s/`

---

## 3. Inventory Changes

Old inventory (`k8s/k8s-setups/kubespray/inventory/homelab-k8s/inventory.ini.old`):
```ini
[kube_control_plane]
talos-00 ... talos-01 ... talos-02 ...

[etcd:children]
kube_control_plane

[kube_node:children]
kube_control_plane
```

New inventory (`k8s/k8s-setups/inventory/homelab-k8s/inventory.ini`):
```ini
[kube_control_plane]
talos-alpha ansible_host=192.168.1.10 ip=192.168.1.10 etcd_member_name=etcd0

[kube_node]
talos-00 ansible_host=192.168.1.11 ip=192.168.1.11 etcd_member_name=etcd1
talos-01 ansible_host=192.168.1.12 ip=192.168.1.12 etcd_member_name=etcd2
talos-02 ansible_host=192.168.1.13 ip=192.168.1.13 etcd_member_name=etcd3

[etcd:children]
kube_control_plane

[k8s_cluster:children]
kube_control_plane
kube_node
```

Critical: talos-00/01/02 are NOT under `[etcd:children]` — Kubespray will not manage their etcd.

---

## 4. Execution Phases

### Phase 1: Pre-flight & Backup (0 downtime)

1. SSH connectivity check to all 4 nodes
2. Export current cluster state: `kubectl get all --all-namespaces -o yaml > cluster-state.yaml`
3. etcd snapshot from any existing CP node:
   ```
   ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
     --cert=/etc/kubernetes/ssl/etcd/node-talos-00.pem \
     --key=/etc/kubernetes/ssl/etcd/node-talos-00-key.pem \
     snapshot save /tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db
   ```
4. Verify snapshot: `etcdctl snapshot status <snapshot> — should show 3 members, hash, revision`
5. Backup HAProxy config from any node: `/etc/haproxy/haproxy.cfg`
6. Copy snapshot + certs + haproxy.cfg to talos-alpha

### Phase 2: Bootstrap talos-alpha (0 downtime to existing cluster)

```
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-alpha
```

This installs: containerd, kubelet, kube-proxy, etcd (single-node), kube-apiserver,
kube-controller-manager, kube-scheduler on talos-alpha.

At this point talos-alpha is a standalone fresh K8s cluster — it does NOT affect
the existing cluster.

### Phase 3: etcd Data Migration (~5 min API downtime)

1. Stop kube-apiserver on talos-alpha: `systemctl stop kube-apiserver`
2. Restore old snapshot into talos-alpha's etcd:
   ```
   ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup-<date>.db \
     --data-dir=/var/lib/etcd \
     --name=etcd0 \
     --initial-cluster=etcd0=https://192.168.1.10:2380 \
     --initial-advertise-peer-urls=https://192.168.1.10:2380
   ```
3. Fix ownership: `chown -R etcd:etcd /var/lib/etcd`
4. Restart etcd: `systemctl restart etcd`
5. Verify etcd: `etcdctl endpoint health` (single member, healthy)
6. Start kube-apiserver: `systemctl start kube-apiserver`
7. **Verification gate**: `kubectl get nodes` must show talos-00/01/02 with pre-migration state

### Phase 4: Install HAProxy + Demote Old Nodes

#### 4a. HAProxy on talos-alpha
- Copy `/etc/haproxy/haproxy.cfg` from existing node
- Update K8s backend section:
  ```
  backend k8s_api_backend
      mode tcp
      balance roundrobin
      option tcp-check
      server k8s-master-1 192.168.1.10:6443 check fall 3 rise 2
  ```
- Patroni, Rancher, Authentik backends unchanged
- Install + start HAProxy

#### 4b. Rolling node demotion (one at a time)

For each node (talos-00, talos-01, talos-02):
```
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# Run kubespray for this node as worker only:
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit <node>
kubectl uncordon <node>
```

Kubespray will:
- Remove kube-apiserver, kube-controller-manager, kube-scheduler from the node
- Keep kubelet, kube-proxy, containerd (worker components)
- Update kubelet.conf to point to talos-alpha:6443
- NOT touch etcd (node is not in [etcd:children])

#### 4c. Update HAProxy on old nodes
Update K8s backend on talos-00/01/02 to point to `talos-alpha:6443` only.
Reload HAProxy.

### Phase 5: Verification

- `kubectl get nodes` — all 4 nodes Ready, talos-alpha = control-plane role, others = none or worker
- `kubectl get pods -A` — all workloads healthy, no CrashLoopBackOff
- ArgoCD health: `curl -sk -H "Authorization: Bearer $ARGOCD_TOKEN" https://argocd.ingress.internal/api/v1/applications | jq '.items[].status.health.status'`
- `ssh ubuntu@192.168.1.11 "systemctl status etcd"` — running on all 3 old nodes
- Patroni health: connect to `192.168.1.11:6432` (HAProxy primary), verify leader exists
- HAProxy stats: verify K8s backend on each node shows talos-alpha:6443 UP

---

## 5. Rollback Plan

If Phase 3/4 fails:
1. Revert inventory to old `.old` file
2. `ansible-playbook -i <old-inventory> cluster.yml` to restore 3-node stacked topology
3. Remove talos-alpha from cluster

---

## 6. Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| etcd snapshot corrupt/incomplete | Verify with `snapshot status` before restore; keep old etcd intact |
| Snapshot restore fails on new etcd version mismatch | Use same etcd version (Kubespray manages this) |
| Worker kubelet can't reach new API server | Verify connectivity before draining; HAProxy backends act as fallback |
| Longhorn volumes stuck during drain | Drain one node at a time; Longhorn replicas self-heal |
| Patroni etcd disrupted | talos-00/01/02 NOT in [etcd:children] — Kubespray won't touch their etcd |

---

## 7. Post-Migration

- Update ArgoCD Application server target (if it uses a specific API endpoint)
- Update any external kubectl kubeconfigs to point to talos-alpha
- Remove old VIP 192.168.1.14 if no longer needed
- Consider implementing talos-cloud-00 as external API endpoint in a future iteration
