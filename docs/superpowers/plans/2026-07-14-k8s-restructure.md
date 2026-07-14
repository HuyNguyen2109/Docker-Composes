# K8s Cluster Restructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure homelab K8s cluster from 3-node stacked CP to 1 CP (talos-alpha) + 3 workers, with etcd data migrated and Patroni continuity preserved.

**Architecture:** Phased approach — snapshot old etcd, bootstrap talos-alpha with Kubespray, restore etcd snapshot to new node, demote old CP nodes to workers, install HAProxy on talos-alpha.

**Tech Stack:** Kubespray v2.23.0, Ansible, etcdctl v3, HAProxy, Ubuntu 24.04

## Global Constraints

- Zero destruction of existing workloads, PVs, secrets
- Patroni 3-node etcd on talos-00/01/02 must remain running throughout
- Single CP is intentional (HA loss accepted)
- talos-alpha (192.168.1.10) is pre-provisioned with SSH access via `~/ssh-keys/homelab-linux`
- Inventory at `k8s/k8s-setups/inventory/homelab-k8s/inventory.ini`
- Kubespray at `k8s/k8s-setups/kubespray/` (git submodule, v2.23.0)

---

### Task 1: Pre-flight SSH Connectivity Check

**Action:** Verify SSH access to all 4 nodes before any changes.

- [ ] **Step 1: Test SSH to all nodes**

```bash
for node in talos-alpha talos-00 talos-01 talos-02; do
  ip=$(grep "$node" k8s/k8s-setups/inventory/homelab-k8s/inventory.ini | grep -oP 'ansible_host=\S+' | cut -d= -f2)
  echo -n "$node ($ip): "
  ssh -i ~/ssh-keys/homelab-linux -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$ip "hostname && uptime" 2>&1 || echo "UNREACHABLE"
done
```

Expected: All 4 nodes respond with hostname and uptime.

---

### Task 2: Collect Current Cluster State

**Action:** Export current cluster state and etcd snapshot for rollback.

- [ ] **Step 1: Export full cluster state**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get all --all-namespaces -o yaml" \
  > /tmp/cluster-state-$(date +%Y%m%d-%H%M%S).yaml
```

Expected: YAML file created at `/tmp/cluster-state-*.yaml` with namespaces, pods, services, deployments.

- [ ] **Step 2: List current nodes**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide"
```

Expected: talos-00, talos-01, talos-02 all Ready, control-plane role.

- [ ] **Step 3: Check current etcd cluster health**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-00.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-00-key.pem \
    endpoint health"
```

Expected: 3 endpoints healthy (127.0.0.1:2379, 192.168.1.12:2379, 192.168.1.13:2379).

- [ ] **Step 4: Check etcd member list**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-00.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-00-key.pem \
    member list"
```

Expected: 3 members (etcd1, etcd2, etcd3).

- [ ] **Step 5: Take etcd snapshot**

```bash
SNAPSHOT="/tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db"
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-00.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-00-key.pem \
    snapshot save /tmp/etcd-backup.db && \
   sudo chmod 644 /tmp/etcd-backup.db"
echo "SNAPSHOT=$SNAPSHOT"
```

Expected: "Snapshot saved at /tmp/etcd-backup.db" output.

- [ ] **Step 6: Verify snapshot integrity**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup.db"
```

Expected: Shows hash, revision, total keys > 0, 3 members.

- [ ] **Step 7: Copy snapshot to talos-alpha**

```bash
scp -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11:/tmp/etcd-backup.db /tmp/etcd-backup.db
scp -i ~/ssh-keys/homelab-linux /tmp/etcd-backup.db ubuntu@192.168.1.10:/tmp/etcd-backup.db
```

Expected: File transfers complete without error.

- [ ] **Step 8: Backup HAProxy config from existing node**

```bash
scp -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11:/etc/haproxy/haproxy.cfg /tmp/haproxy.cfg
```

Expected: File copied successfully.

- [ ] **Step 9: Backup etcd certs for potential cross-cluster access**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo tar czf /tmp/etcd-certs.tar.gz /etc/kubernetes/ssl/etcd/"
scp -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11:/tmp/etcd-certs.tar.gz /tmp/etcd-certs.tar.gz
scp -i ~/ssh-keys/homelab-linux /tmp/etcd-certs.tar.gz ubuntu@192.168.1.10:/tmp/etcd-certs.tar.gz
```

---

### Task 3: Velero Full Cluster Backup

**Action:** Take a full Velero backup of the entire cluster before any changes.

- [ ] **Step 1: Update BackupStorageLocation to new S3 endpoint**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
    patch backupstoragelocation default -n velero --type merge \
    -p '{\"spec\":{\"config\":{\"s3Url\":\"https://s3.mcb-homelab.com\"}}}'"
```

Expected: `backupstoragelocation.velero.io/default patched`

- [ ] **Step 2: Verify BSL is Available**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get backupstoragelocations -n velero -o jsonpath='{.items[0].status.phase}'"
```

Expected: `Available`

- [ ] **Step 3: Create Velero backup CR**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -" <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-restructure
  namespace: velero
spec:
  includedNamespaces:
  - '*'
  storageLocation: default
  ttl: 720h
EOF
```

Expected: `backup.velero.io/pre-restructure created`

- [ ] **Step 4: Poll until backup completes**

```bash
for i in $(seq 1 12); do
  STATUS=$(ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
    "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
      get backup.velero.io pre-restructure -n velero -o jsonpath='{.status.phase}'" 2>/dev/null)
  echo "Attempt $i: status=$STATUS"
  if [ "$STATUS" = "Completed" ]; then
    echo "VELERO BACKUP COMPLETED"
    break
  elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "FailedValidation" ]; then
    echo "VELERO BACKUP FAILED — abort"
    ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
      "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
        describe backup.velero.io pre-restructure -n velero | grep -A20 'Status:'" 2>/dev/null
    exit 1
  fi
  sleep 30
done
```

Expected: `Completed` status, ~2,000+ items backed up.

- [ ] **Step 5: Verify backup details**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
    get backup.velero.io pre-restructure -n velero \
    -o jsonpath='Status: {.status.phase}, Items: {.status.progress.itemsBackedUp}/{.status.progress.totalItems}, Errors: {.status.errors}'"
```

Expected: `Status: Completed, Items: N/N, Errors: 0`

---

### Task 4: Bootstrap talos-alpha via Kubespray

**Action:** Run `cluster.yml --limit talos-alpha` to install fresh CP on talos-alpha.

- [ ] **Step 1: Verify inventory resolves correctly**

```bash
cd k8s/k8s-setups/kubespray
ansible-inventory -i ../inventory/homelab-k8s/inventory.ini --list | python3 -c "
import json,sys
data=json.load(sys.stdin)
for g in ['kube_control_plane','kube_node','etcd']:
    hosts = data.get(g,{}).get('hosts',[])
    if not hosts and g in data:
        hosts = [h for c in data[g].get('children',[]) for h in data.get(c,{}).get('hosts',[])]
    print(f'{g}: {hosts}')
"
```

Expected: `kube_control_plane: ['talos-alpha']`, `kube_node: ['talos-00','talos-01','talos-02']`, `etcd: ['talos-alpha']`.

- [ ] **Step 2: Run cluster.yml against talos-alpha only**

```bash
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-alpha -v
```

Expected: Playbook completes successfully (all tasks OK, no failed).

- [ ] **Step 3: Verify talos-alpha has etcd + CP components**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl status etcd; sudo systemctl status kube-apiserver; sudo systemctl status kube-controller-manager; sudo systemctl status kube-scheduler; sudo systemctl status kubelet"
```

Expected: All services active (running).

- [ ] **Step 4: Verify talos-alpha has a fresh empty K8s cluster**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes"
```

Expected: Only talos-alpha listed, Ready (fresh cluster — no old nodes visible).

---

### Task 5: Migrate etcd Data to talos-alpha

**Action:** Stop talos-alpha's kube-apiserver, restore etcd snapshot, restart.

- [ ] **Step 1: Stop kube-apiserver on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl stop kube-apiserver"
```

- [ ] **Step 2: Verify etcd peer/client ports on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-alpha.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-alpha-key.pem \
    endpoint health"
```

Expected: Single endpoint healthy (talos-alpha etcd is running).

- [ ] **Step 3: Stop etcd on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl stop etcd"
```

- [ ] **Step 4: Remove current etcd data (fresh empty cluster data)**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo rm -rf /var/lib/etcd/*"
```

- [ ] **Step 5: Restore snapshot into talos-alpha etcd**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
    --data-dir=/var/lib/etcd \
    --name=etcd0 \
    --initial-cluster=etcd0=https://192.168.1.10:2380 \
    --initial-advertise-peer-urls=https://192.168.1.10:2380 \
    --initial-cluster-token=k8s-etcd-cluster"
```

Expected: Output showing restored snapshot with hash/revision info.

- [ ] **Step 6: Fix etcd data directory ownership**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo chown -R etcd:etcd /var/lib/etcd"
```

- [ ] **Step 7: Restart etcd on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl start etcd"
```

- [ ] **Step 8: Verify restored etcd is healthy**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-alpha.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-alpha-key.pem \
    endpoint health && \
   sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-alpha.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-alpha-key.pem \
    get /registry/namespaces/default --print-value-only"
```

Expected: `https://127.0.0.1:2379 is healthy: successfully committed proposal`. Namespace data visible.

- [ ] **Step 9: Start kube-apiserver on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl start kube-apiserver"
sleep 10
```

- [ ] **Step 10: Verify old cluster state is visible through talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes"
```

Expected: **All 3 old nodes** (talos-00, talos-01, talos-02) appear as Ready. This confirms etcd data migration succeeded.

- [ ] **Step 11: Verify pods are running**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A | head -30"
```

Expected: Workloads running in all namespaces (no mass CrashLoopBackOff).

---

### Task 6: Install HAProxy on talos-alpha

**Action:** Copy HAProxy config from existing node, update K8s backend, install on talos-alpha.

- [ ] **Step 1: Read existing HAProxy config from backup**

```bash
cat /tmp/haproxy.cfg
```

- [ ] **Step 2: Create updated HAProxy config for talos-alpha**

Replace the K8s backend section in `/tmp/haproxy.cfg`:

```
backend k8s_api_backend
    mode tcp
    balance roundrobin
    option tcp-check
    server k8s-master-1 192.168.1.10:6443 check fall 3 rise 2
```

Keep all other sections (Patroni, Rancher, Authentik) unchanged.

- [ ] **Step 3: Copy updated config to talos-alpha**

```bash
scp -i ~/ssh-keys/homelab-linux /tmp/haproxy.cfg ubuntu@192.168.1.10:/tmp/haproxy.cfg
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg"
```

- [ ] **Step 4: Install HAProxy on talos-alpha (if not already installed)**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo apt-get update -qq && sudo apt-get install -y -qq haproxy"
```

- [ ] **Step 5: Start/enable HAProxy on talos-alpha**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo systemctl enable haproxy && sudo systemctl restart haproxy && sudo systemctl status haproxy"
```

Expected: active (running).

- [ ] **Step 6: Verify HAProxy is listening on expected ports**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo ss -tlnp | grep haproxy"
```

Expected: Listening on 6444, 6432, 6433, 3001, 9443.

---

### Task 7: Rolling Demotion of Old Control-Plane Nodes

**Action:** Drain each old node, run Kubespray to strip CP components, uncordon. Repeat for all 3.

- [ ] **Step 1: Drain talos-00**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf drain talos-00 \
    --ignore-daemonsets --delete-emptydir-data --force --timeout=300s"
```

- [ ] **Step 2: Run cluster.yml on talos-00 to convert to worker**

```bash
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-00 -v
```

- [ ] **Step 3: Verify CP components removed from talos-00**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "systemctl status kube-apiserver 2>&1 | head -3; \
   systemctl status etcd 2>&1 | head -3"
```

Expected: kube-apiserver = not found/inactive. etcd = **active (running)** — for Patroni.

- [ ] **Step 4: Update HAProxy K8s backend on talos-00**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo sed -i 's/server k8s-master-1.*/server k8s-master-1 192.168.1.10:6443 check fall 3 rise 2/' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-2/d' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-3/d' /etc/haproxy/haproxy.cfg && \
   sudo systemctl reload haproxy"
```

- [ ] **Step 5: Uncordon talos-00**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon talos-00"
```

- [ ] **Step 6: Wait for talos-00 workloads to reschedule**

```bash
sleep 30
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector spec.nodeName=talos-00 | tail -5"
```

- [ ] **Step 7: Drain talos-01**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf drain talos-01 \
    --ignore-daemonsets --delete-emptydir-data --force --timeout=300s"
```

- [ ] **Step 8: Run cluster.yml on talos-01 to convert to worker**

```bash
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-01 -v
```

- [ ] **Step 9: Verify CP components removed, etcd still running on talos-01**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.12 \
  "systemctl status kube-apiserver 2>&1 | head -3; \
   systemctl status etcd 2>&1 | head -3"
```

Expected: kube-apiserver = not found/inactive. etcd = active (running).

- [ ] **Step 10: Update HAProxy K8s backend on talos-01**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.12 \
  "sudo sed -i 's/server k8s-master-1.*/server k8s-master-1 192.168.1.10:6443 check fall 3 rise 2/' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-2/d' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-3/d' /etc/haproxy/haproxy.cfg && \
   sudo systemctl reload haproxy"
```

- [ ] **Step 11: Uncordon talos-01**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon talos-01"
```

- [ ] **Step 12: Wait for talos-01 workloads to reschedule**

```bash
sleep 30
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector spec.nodeName=talos-01 | tail -5"
```

- [ ] **Step 13: Drain talos-02**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf drain talos-02 \
    --ignore-daemonsets --delete-emptydir-data --force --timeout=300s"
```

- [ ] **Step 14: Run cluster.yml on talos-02 to convert to worker**

```bash
cd k8s/k8s-setups/kubespray
ansible-playbook -i ../inventory/homelab-k8s/inventory.ini cluster.yml --limit talos-02 -v
```

- [ ] **Step 15: Verify CP components removed, etcd still running on talos-02**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.13 \
  "systemctl status kube-apiserver 2>&1 | head -3; \
   systemctl status etcd 2>&1 | head -3"
```

Expected: kube-apiserver = not found/inactive. etcd = active (running).

- [ ] **Step 16: Update HAProxy K8s backend on talos-02**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.13 \
  "sudo sed -i 's/server k8s-master-1.*/server k8s-master-1 192.168.1.10:6443 check fall 3 rise 2/' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-2/d' /etc/haproxy/haproxy.cfg && \
   sudo sed -i '/server k8s-master-3/d' /etc/haproxy/haproxy.cfg && \
   sudo systemctl reload haproxy"
```

- [ ] **Step 17: Uncordon talos-02**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon talos-02"
```

- [ ] **Step 18: Wait for talos-02 workloads to reschedule**

```bash
sleep 30
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector spec.nodeName=talos-02 | tail -5"
```

- [ ] **Step 9: Verify all old nodes still have etcd running**

```bash
for ip in 192.168.1.11 192.168.1.12 192.168.1.13; do
  echo -n "Node $ip etcd: "
  ssh -i ~/ssh-keys/homelab-linux ubuntu@$ip \
    "sudo systemctl is-active etcd" 2>&1
done
```

Expected: `active` for all 3 nodes.

---

### Task 8: Full Cluster Verification

**Action:** Comprehensive verification of the restructured cluster.

- [ ] **Step 1: Verify all 4 nodes visible and roles correct**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide --show-labels | grep -E 'NAME|node-role'"
```

Expected: talos-alpha = control-plane, talos-00/01/02 = no control-plane label (worker role).

- [ ] **Step 2: Check all pods healthy**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector status.phase!=Running | grep -v 'Completed\|Succeeded'"
```

Expected: No output (all pods Running or Completed).

- [ ] **Step 3: Verify CoreDNS is running**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n kube-system -l k8s-app=kube-dns"
```

Expected: CoreDNS pods Running.

- [ ] **Step 4: Verify Calico node pods on all nodes**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n kube-system -l k8s-app=calico-node -o wide"
```

Expected: 4 calico-node pods, one per node, all Running.

- [ ] **Step 5: Verify MetalLB**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n metallb-system"
```

Expected: controller and speakers Running.

- [ ] **Step 6: Verify Longhorn**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n longhorn-system | grep -v Running"
```

Expected: No non-Running pods (all healthy).

- [ ] **Step 7: Verify HAProxy K8s backends healthy on all nodes**

```bash
for ip in 192.168.1.10 192.168.1.11 192.168.1.12 192.168.1.13; do
  echo "=== Node $ip HAProxy K8s backend ==="
  echo "show stat" | ssh -i ~/ssh-keys/homelab-linux ubuntu@$ip \
    "sudo socat stdio /run/haproxy/admin.sock 2>/dev/null" 2>/dev/null | grep k8s-master
done
```

Expected: `k8s-master-1` shows UP on all nodes, pointing to 192.168.1.10:6443.

- [ ] **Step 8: Verify ArgoCD app sync status**

```bash
curl -sk -H "Authorization: Bearer $ARGOCD_TOKEN" \
  "https://argocd.ingress.internal/api/v1/applications" | \
  python3 -c "import json,sys; apps=json.load(sys.stdin)['items']; [print(f\"{a['metadata']['name']}: {a['status']['health']['status']}\") for a in apps]"
```

Expected: All apps show Healthy.

- [ ] **Step 9: Verify Patroni etcd cluster still operational**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.11 \
  "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/ssl/etcd/ca.pem \
    --cert=/etc/kubernetes/ssl/etcd/node-talos-00.pem \
    --key=/etc/kubernetes/ssl/etcd/node-talos-00-key.pem \
    endpoint health"
```

Expected: 3 endpoints healthy (the old etcd cluster intact).

- [ ] **Step 10: Integration test — create a test deployment**

```bash
ssh -i ~/ssh-keys/homelab-linux ubuntu@192.168.1.10 \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf create deployment nginx-test --image=nginx:alpine --replicas=2 && \
   sleep 10 && \
   sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -l app=nginx-test -o wide && \
   sudo kubectl --kubeconfig /etc/kubernetes/admin.conf delete deployment nginx-test"
```

Expected: 2 nginx-test pods Running on worker nodes, then deleted successfully.

---

### Task 9: Commit Changes

**Action:** Commit the updated inventory to git.

- [ ] **Step 1: Stage and commit the updated inventory**

```bash
cd /root/workspace/My-DevOps
git add k8s/k8s-setups/inventory/homelab-k8s/inventory.ini
git commit -m "feat(k8s): restructure homelab-k8s to 1 CP (talos-alpha) + 3 worker topology"
```

- [ ] **Step 2: Stage and commit the design spec and plan**

```bash
git add docs/superpowers/specs/2026-07-14-k8s-restructure-design.md
git add docs/superpowers/plans/2026-07-14-k8s-restructure.md
git commit -m "docs: add k8s cluster restructure design spec and implementation plan"
```
