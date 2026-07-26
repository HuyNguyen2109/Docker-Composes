# Longhorn to Synology CSI Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all 9 Longhorn PersistentVolumeClaims to the new `synology-iscsi-storage` StorageClass, eliminating Longhorn dependency.

**Architecture:** Stop workloads, copy critical data (Grafana dashboards), delete old PVCs, update values files to reference `synology-iscsi-storage`, let Helm/StatefulSets recreate fresh PVCs, restore Grafana data, verify.

**Tech Stack:** kubectl, Helm (via ArgoCD avp-helm plugin), rsync (temporary helper pods), Synology CSI driver (`csi.san.synology.com`)

## Global Constraints

- Target SC: `synology-iscsi-storage` (provisioner: `csi.san.synology.com`, reclaimPolicy: Retain)
- All workloads must retain `nodeSelector: node-role.kubernetes.io/storage: "true"` (already applied)
- Values file changes must be committed to `develop` branch for ArgoCD sync
- ArgoCD apps have `selfHeal: true` — scaling operations may be reverted automatically
- Critical data only for Grafana PVC (20Gi) — must be backed up and restored
- Loki data is replayable from upstream log agents — no backup needed
- Harbor trivy cache and jobservice logs are disposable — no backup needed

## Inventory

| # | PVC | Namespace | Size | Workload | Critical |
|---|-----|-----------|------|----------|----------|
| 1 | data-loki-backend-0 | monitoring | 10Gi | sts/loki-backend | No |
| 2 | data-loki-backend-1 | monitoring | 10Gi | sts/loki-backend | No |
| 3 | data-loki-backend-2 | monitoring | 10Gi | sts/loki-backend | No |
| 4 | data-loki-write-0 | monitoring | 10Gi | sts/loki-write | No |
| 5 | data-loki-write-1 | monitoring | 10Gi | sts/loki-write | No |
| 6 | data-loki-write-2 | monitoring | 10Gi | sts/loki-write | No |
| 7 | kube-prometheus-stack-grafana | monitoring | 20Gi | deploy/...-grafana | **Yes** |
| 8 | data-harbor-trivy-0 | administrator-apps | 10Gi | sts/harbor-trivy | No |
| 9 | harbor-jobservice | administrator-apps | 1Gi | deploy/harbor-jobservice | No |

## Values Files to Modify

| File | Change |
|------|--------|
| `k8s/kube-prometheus-stack/values/values.yaml:1474` | `storageClassName: "longhorn"` → `"synology-iscsi-storage"` |
| `k8s/kube-prometheus-stack/values/loki.yaml:1595` | `storageClass: null` → `storageClass: synology-iscsi-storage` |
| `k8s/kube-prometheus-stack/values/loki.yaml:1744` | `storageClass: null` → `storageClass: synology-iscsi-storage` |
| `k8s/kube-prometheus-stack/values/loki.yaml:1882` | `storageClass: null` → `storageClass: synology-iscsi-storage` |
| `k8s/harbor/values/values.yaml:25` | `storageClass: longhorn` → `storageClass: synology-iscsi-storage` |
| `k8s/harbor/values/values.yaml:28` | `storageClass: longhorn` → `storageClass: synology-iscsi-storage` |
| `k8s/harbor/values/values.yaml:31` | `storageClass: longhorn` → `storageClass: synology-iscsi-storage` |

---

### Task 1: Pre-Flight Verification

**Files:** None (operational task)

**Interfaces:**
- Consumes: kubectl cluster access, synology-csi running
- Produces: Confirmation that all prerequisites are met

- [ ] **Step 1: Verify Synology CSI is healthy**

```bash
kubectl get pods -n synology-csi -o wide
kubectl get sc synology-iscsi-storage
```

Expected: All synology-csi pods Running, SC exists with `csi.san.synology.com` provisioner.

- [ ] **Step 2: Verify all 9 volumes and workloads are healthy**

```bash
kubectl -n storageclass-system get volumes.longhorn.io -o custom-columns='NAME:.metadata.name,ROBUST:.status.robustness'
kubectl get pods -n monitoring | grep -E 'loki-backend|loki-write|grafana'
kubectl get pods -n administrator-apps | grep -E 'harbor-trivy|harbor-jobservice'
```

Expected: All volumes `healthy`, all pods `Running`.

- [ ] **Step 3: Record current PV names for cleanup**

```bash
kubectl get pvc --all-namespaces -o json | \
  python3 -c "
import sys,json
for pvc in json.load(sys.stdin)['items']:
    if pvc['spec'].get('storageClassName') == 'longhorn':
        print(f'{pvc[\"metadata\"][\"namespace\"]}/{pvc[\"metadata\"][\"name\"]} -> {pvc[\"spec\"][\"volumeName\"]}')
"
```

Save this output — needed for Task 5 cleanup.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-07-26-longhorn-to-synology-csi-migration.md
git commit -m "docs: add Longhorn-to-Synology CSI migration plan"
```

---

### Task 2: Update All Values Files and Commit

**Files:**
- Modify: `k8s/kube-prometheus-stack/values/values.yaml`
- Modify: `k8s/kube-prometheus-stack/values/loki.yaml`
- Modify: `k8s/harbor/values/values.yaml`

**Interfaces:**
- Produces: All storageClass references changed from `longhorn`/`null` to `synology-iscsi-storage`

- [ ] **Step 1: Change Grafana storageClass**

Edit `k8s/kube-prometheus-stack/values/values.yaml` line 1474:
```yaml
# Before:
    storageClassName: "longhorn"
# After:
    storageClassName: "synology-iscsi-storage"
```

- [ ] **Step 2: Change Loki write storageClass**

Edit `k8s/kube-prometheus-stack/values/loki.yaml` around line 1744:
```yaml
# Before:
    storageClass: null
# After:
    storageClass: synology-iscsi-storage
```

- [ ] **Step 3: Change Loki backend storageClass**

Edit `k8s/kube-prometheus-stack/values/loki.yaml` around line 2019:
```yaml
# Before:
    storageClass: null
# After:
    storageClass: synology-iscsi-storage
```
Note: This applies to `backend.persistence.storageClass`.

- [ ] **Step 4: Change Loki read storageClass (around line 1882)**

Actually check the Loki read section. The `read` component in the current deployment uses `emptyDir` (no PVC), so the `read.persistence.storageClass` only applies if `legacyReadTarget` is enabled. Skip this if read has no PVCs — verify with:

```bash
kubectl get deploy loki-read -n monitoring -o yaml | grep -A5 volumes | grep persistentVolumeClaim
```

If no PVC found, skip the read storageClass change.

- [ ] **Step 5: Change Harbor storage classes**

Edit `k8s/harbor/values/values.yaml`:
```yaml
# Before (lines 24-32):
  persistentVolumeClaim:
    registry:
      storageClass: longhorn
      size: 10Gi
    jobservice:
      storageClass: longhorn
      size: 1Gi
    trivy:
      storageClass: longhorn
      size: 10Gi
# After:
  persistentVolumeClaim:
    registry:
      storageClass: synology-iscsi-storage
      size: 10Gi
    jobservice:
      storageClass: synology-iscsi-storage
      size: 1Gi
    trivy:
      storageClass: synology-iscsi-storage
      size: 10Gi
```

- [ ] **Step 6: Commit and push all values changes**

```bash
git add k8s/kube-prometheus-stack/values/values.yaml \
        k8s/kube-prometheus-stack/values/loki.yaml \
        k8s/harbor/values/values.yaml
git commit -m "feat: migrate storage from longhorn to synology-iscsi-storage"
git push origin develop
```

---

### Task 3: Migrate Loki Volumes (6 PVCs, Non-Critical)

**Files:** None (operational task)

**Interfaces:**
- Consumes: Values files updated (Task 2), kubectl access
- Produces: 6 new Loki PVCs on synology-iscsi-storage, old Longhorn PVCs deleted

**Strategy:** Delete old PVCs, let StatefulSets recreate them with new StorageClass. Loki replays data from upstream log sources (Promtail/Alloy agents) and S3 backend.

- [ ] **Step 1: Scale down Loki StatefulSets**

```bash
kubectl scale sts loki-backend -n monitoring --replicas=0
kubectl scale sts loki-write -n monitoring --replicas=0
```

Wait for pods to terminate:
```bash
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/component=backend --timeout=120s
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/component=write --timeout=120s
```

- [ ] **Step 2: Force-detach all Loki volumes from Longhorn**

```bash
for vol in pvc-bf205761 pvc-44ae22f7 pvc-bb62900a \
           pvc-3b68fc51 pvc-b1c90ba5 pvc-84f49065; do
  kubectl -n storageclass-system patch volume $vol --type=merge \
    -p '{"spec":{"nodeID":""}}'
done
```

Wait for detach (check `kubectl -n storageclass-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.state}{"\n"}{end}' | sort | uniq -c`).

- [ ] **Step 3: Delete Loki PVCs and their PVs**

```bash
for pvc in data-loki-backend-0 data-loki-backend-1 data-loki-backend-2 \
           data-loki-write-0 data-loki-write-1 data-loki-write-2; do
  kubectl delete pvc $pvc -n monitoring --force --grace-period=0 --timeout=10s 2>/dev/null || true
done
```

If any PVCs get stuck in Terminating, remove finalizers:
```bash
for pvc in data-loki-backend-0 data-loki-backend-1 data-loki-backend-2 \
           data-loki-write-0 data-loki-write-1 data-loki-write-2; do
  kubectl patch pvc $pvc -n monitoring --type=merge \
    -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
done
```

- [ ] **Step 4: Delete orphaned Longhorn PVs**

```bash
kubectl get pv | grep Released | grep -E 'pvc-bf205761|pvc-44ae22f7|pvc-bb62900a|pvc-3b68fc51|pvc-b1c90ba5|pvc-84f49065' | awk '{print $1}' | xargs -r kubectl delete pv
```

If stuck, remove finalizers:
```bash
kubectl get pv | grep Released | awk '{print $1}' | xargs -I{} kubectl patch pv {} --type=merge -p '{"metadata":{"finalizers":[]}}'
```

- [ ] **Step 5: Scale Loki StatefulSets back up**

```bash
kubectl scale sts loki-backend -n monitoring --replicas=3
kubectl scale sts loki-write -n monitoring --replicas=3
```

Wait for pods:
```bash
sleep 30
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki -o wide
```

- [ ] **Step 6: Verify new PVCs use synology-iscsi-storage**

```bash
kubectl get pvc -n monitoring -o custom-columns='NAME:.metadata.name,STORAGECLASS:.spec.storageClassName' | grep loki
```

Expected: All 6 Loki PVCs show `synology-iscsi-storage`.

- [ ] **Step 7: Verify all Loki pods are Running**

```bash
kubectl get pods -n monitoring | grep -E 'loki-backend|loki-write' | grep -c Running
```

Expected: `6` (3 backend + 3 write, all Running).

---

### Task 4: Migrate Harbor Volumes (2 PVCs, Non-Critical)

**Files:** None (operational task)

**Interfaces:**
- Consumes: Values files updated (Task 2)
- Produces: 2 new Harbor PVCs on synology-iscsi-storage

**Strategy:** Harbor trivy cache is a vulnerability scanner database that auto-rebuilds. Harbor jobservice logs are disposable. Delete old PVCs, let Helm recreate them.

- [ ] **Step 1: Delete Harbor ArgoCD app to prevent selfHeal interference**

Trigger a sync disable temporarily, or just scale down the deployments manually:

```bash
kubectl scale deploy harbor-jobservice -n administrator-apps --replicas=0
kubectl scale sts harbor-trivy -n administrator-apps --replicas=0
```

Wait:
```bash
kubectl wait --for=delete pod -n administrator-apps -l component=trivy --timeout=60s
kubectl wait --for=delete pod -n administrator-apps -l component=jobservice --timeout=60s
```

- [ ] **Step 2: Detach and delete Harbor PVCs**

```bash
# Detach from Longhorn
kubectl -n storageclass-system patch volume pvc-b197311a --type=merge -p '{"spec":{"nodeID":""}}'
kubectl -n storageclass-system patch volume pvc-65b9cd95 --type=merge -p '{"spec":{"nodeID":""}}'

# Delete PVCs
kubectl delete pvc data-harbor-trivy-0 -n administrator-apps
kubectl delete pvc harbor-jobservice -n administrator-apps
```

Remove finalizers if stuck (same pattern as Task 4 Step 3).

- [ ] **Step 3: Clean up orphaned Longhorn PVs**

```bash
kubectl get pv | grep Released | awk '{print $1}' | xargs -I{} kubectl patch pv {} --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl get pv | grep Released | awk '{print $1}' | xargs -r kubectl delete pv
```

- [ ] **Step 4: Scale Harbor back up**

```bash
kubectl scale deploy harbor-jobservice -n administrator-apps --replicas=1
kubectl scale sts harbor-trivy -n administrator-apps --replicas=1
```

- [ ] **Step 5: Verify new PVCs**

```bash
kubectl get pvc -n administrator-apps -o custom-columns='NAME:.metadata.name,STORAGECLASS:.spec.storageClassName'
```

Expected: `synology-iscsi-storage` for trivy and jobservice PVCs.

- [ ] **Step 6: Verify Harbor pods are Running**

```bash
kubectl get pods -n administrator-apps | grep -E 'harbor-trivy|harbor-jobservice'
```

---

### Task 5: Migrate Grafana Volume (1 PVC, Critical)

**Files:** Modify: `k8s/kube-prometheus-stack/values/values.yaml`

**Interfaces:**
- Consumes: Values file storageClassName change (Task 2), kubectl access
- Produces: Grafana data migrated to synology-iscsi-storage via `existingClaim`

**Strategy:** Copy data from old Longhorn PVC to a new synology PVC, then use `persistence.existingClaim` so Helm references the migrated PVC instead of creating a new one.

- [ ] **Step 1: Scale down Grafana**

```bash
kubectl scale deploy kube-prometheus-stack-grafana -n monitoring --replicas=0
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=grafana --timeout=60s
```

- [ ] **Step 2: Create destination PVC on synology-iscsi-storage**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data-migrated
  namespace: monitoring
  labels:
    app.kubernetes.io/instance: kube-prometheus-stack
    app.kubernetes.io/name: grafana
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: synology-iscsi-storage
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/grafana-data-migrated -n monitoring --timeout=60s
```

- [ ] **Step 3: Copy data from old Longhorn PVC to new synology PVC**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: grafana-data-copier
  namespace: monitoring
spec:
  nodeSelector:
    node-role.kubernetes.io/storage: "true"
  containers:
  - name: copier
    image: docker.io/library/ubuntu:24.04
    command: ["bash", "-c", "apt-get update -qq && apt-get install -y -qq rsync >/dev/null 2>&1 && rsync -avH --delete /source/ /target/ 2>&1 && echo COPY_OK && sleep 600"]
    volumeMounts:
    - name: source
      mountPath: /source
    - name: target
      mountPath: /target
  volumes:
  - name: source
    persistentVolumeClaim:
      claimName: kube-prometheus-stack-grafana
  - name: target
    persistentVolumeClaim:
      claimName: grafana-data-migrated
  restartPolicy: Never
EOF
```

Wait for copy to complete:
```bash
sleep 90
kubectl logs grafana-data-copier -n monitoring | tail -3
```

Expected: "COPY_OK".

- [ ] **Step 4: Delete old Longhorn PVC and cleanup**

```bash
kubectl delete pod grafana-data-copier -n monitoring --force --grace-period=0
kubectl delete pvc kube-prometheus-stack-grafana -n monitoring
```

If PVC gets stuck in Terminating:
```bash
kubectl patch pvc kube-prometheus-stack-grafana -n monitoring --type=merge \
  -p '{"metadata":{"finalizers":[]}}' 2>/dev/null
```

Clean up orphaned PV:
```bash
kubectl get pv | grep Released | awk '{print $1}' | xargs -I{} kubectl patch pv {} --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl get pv | grep Released | awk '{print $1}' | xargs -r kubectl delete pv
```

- [ ] **Step 5: Update Grafana values to use existingClaim**

Edit `k8s/kube-prometheus-stack/values/values.yaml` at the Grafana persistence block (around line 1470). Replace the storageClassName line with existingClaim:

```yaml
  persistence:
    enabled: true
    existingClaim: grafana-data-migrated
    size: 20Gi
```

- [ ] **Step 6: Commit and push**

```bash
git add k8s/kube-prometheus-stack/values/values.yaml
git commit -m "fix(grafana): use existingClaim with migrated synology volume"
git push origin develop
```

- [ ] **Step 7: Scale up Grafana**

```bash
kubectl scale deploy kube-prometheus-stack-grafana -n monitoring --replicas=1
kubectl wait --for=condition=available deploy/kube-prometheus-stack-grafana -n monitoring --timeout=120s
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
```

Expected: 1/1 Running.

- [ ] **Step 8: Verify Grafana health**

```bash
curl -sk https://grafana.ingress.internal/api/health
```

Expected: `{"database": "ok", ...}`.

---

### Task 6: Final Verification and Cleanup

**Files:** None (operational task)

- [ ] **Step 1: Verify all PVCs use synology-iscsi-storage**

```bash
kubectl get pvc --all-namespaces -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STORAGECLASS:.spec.storageClassName' | grep -v longhorn
```

Expected: No PVC with storageClass "longhorn".

- [ ] **Step 2: Verify all pods are Running**

```bash
kubectl get pods --all-namespaces --no-headers | grep -v Running | grep -v Completed
```

Expected: No output (all pods Running).

- [ ] **Step 3: Verify Longhorn volumes are all deleted**

```bash
kubectl -n storageclass-system get volumes.longhorn.io
```

Expected: No volumes (or only volumes from Longhorn system itself).

- [ ] **Step 4: Check ArgoCD sync status for all affected apps**

```bash
source ~/.bashrc
for app in kube-prometheus-stack harbor; do
  curl -sk -H "Authorization: Bearer $ARGOCD_TOKEN" \
    "https://argocd.ingress.internal/api/v1/applications/$app" 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); print(f'{a[\"metadata\"][\"name\"]}: sync={a[\"status\"][\"sync\"][\"status\"]}, health={a[\"status\"][\"health\"][\"status\"]}')"
done
```

Expected: Both `Synced` and `Healthy`.

- [ ] **Step 5: Verify PVC metrics in Synology DSM**

Ask user to verify volumes appear in Synology DSM under SAN Manager → iSCSI targets. This should show 9 new LUNs (1 Grafana + 2 Harbor + 6 Loki).

- [ ] **Step 6: Commit the Grafana existingClaim change**

```bash
git add k8s/kube-prometheus-stack/values/values.yaml
git commit -m "fix(grafana): use existingClaim for migrated synology volume"
git push origin develop
```

- [ ] **Step 7: Final commit with cleanup summary**

```bash
git add docs/superpowers/plans/2026-07-26-longhorn-to-synology-csi-migration.md
git commit -m "docs: finalize Longhorn-to-Synology CSI migration plan"
```

---

### Post-Migration: Cleanup Longhorn

After verifying everything works for 24-48 hours, optionally remove Longhorn:

- [ ] Delete Longhorn ArgoCD application (or keep if still needed for on-cloud cluster)
- [ ] Delete Longhorn CRDs: `kubectl get crd | grep longhorn | awk '{print $1}' | xargs kubectl delete crd`
- [ ] Delete `storageclass-system` namespace (if no other resources): `kubectl delete ns storageclass-system`
- [ ] Remove Longhorn labels from nodes: `kubectl label node talos-00 talos-01 talos-02 node-role.kubernetes.io/storage-`
- [ ] Remove Longhorn dev path: `rm -rf /dev/longhorn-v2-block` (on each node, via SSH)
