# Longhorn Maintenance — Orphan Cleanup & Disk Pressure

*Date: 2026-05-28 | Applies to: Kubernetes cluster (storageclass-system namespace)*

---

## Key Facts

- Longhorn namespace: **`storageclass-system`** (not the standard `longhorn-system`)
- Storage driver: **v2 block device** (driver: `aio`)
- Block device per node: `/dev/longhorn-v2-block`
- `storageMinimalAvailablePercentage`: **25%** — with 100GB block devices, minimum free = **24.9GB**
- kubectl access on nodes: `sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl ...`

---

## Orphaned Replicas — Root Cause & Impact

Longhorn v2 block device engine tracks orphaned replica data via `orphans.longhorn.io` CRDs. Orphans accumulate silently when volumes are deleted but replica cleanup doesn't complete.

**Impact:**
- `storageScheduled` stays high even when underlying volumes are gone
- Orphaned data occupies the block device, reducing `storageAvailable`
- When available space drops below `storageMinimalAvailablePercentage`, the node becomes **Unschedulable**
- Degraded volumes on other nodes won't self-heal until the affected node is schedulable again

**Example (May 2026):** 55 orphans (31 on talos-01, 23 on talos-02, 1 on talos-00) consumed ~53GB on talos-01's block device. Available space: 12.2GB (below 24.9GB minimum) → talos-01 marked Unschedulable.

---

## Diagnosis

### Check node schedulability
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes.longhorn.io -n storageclass-system
```

Look for `Schedulable: false` and `storageAvailable` below 25% of total.

### Count orphans per node
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get orphans.longhorn.io -n storageclass-system
```

### Check volume health
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get volumes.longhorn.io -n storageclass-system
```
Healthy volumes show `Attached`, `degraded/fault` volumes need investigation.

---

## Cleanup

### Delete all orphaned replicas
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl delete orphans.longhorn.io --all -n storageclass-system
```

Space is reclaimed within ~20 seconds. Verify:
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes.longhorn.io -n storageclass-system
# storageAvailable should jump significantly
```

### Automated Cleanup (CronJob)

A daily CronJob at 02:00 UTC handles orphan cleanup automatically:
- **`cleanup-orphaned-resources`** (daily): Longhorn orphans, Released PVs, orphaned PVCs, stuck Terminating namespaces, old orphaned Jobs
- **`cleanup-failed-pods`** (hourly): Failed/Evicted/Error/OOMKilled/Succeeded standalone pods

Manifest: `k8s/cleanup-failed-resources/manifests/manifests.yaml`

Check CronJob status:
```bash
kubectl get cronjobs -n kube-system
kubectl get jobs -n kube-system
kubectl logs -n kube-system job/cleanup-orphaned-resources-<timestamp>
```

---

## Orphaned PVCs (App Moved Namespace)

When an app moves to a different namespace, the old PVC may remain detached in the original namespace.

**Detection:**
```bash
kubectl get pvc -A | grep -v Bound
# Look for Terminating or no status
kubectl get volumes.longhorn.io -n storageclass-system | grep -v Attached
```

**Verification before deletion:**
1. Confirm no pod in ANY namespace mounts the PVC
2. Confirm no ArgoCD app owns the PVC
3. Confirm no StatefulSet in the PVC's namespace references it

**Delete orphaned PVC:**
```bash
kubectl delete pvc <name> -n <namespace>
# Longhorn volume is cleaned up automatically
```

---

## Longhorn Volume States Reference

| State | Meaning | Action |
|-------|---------|--------|
| `attached/healthy` | Normal | None |
| `attached/degraded` | Missing replica(s) | Wait for self-heal once space available |
| `detached/unknown` | No node has it mounted | Check if still needed; may be orphaned |
| `Faulted` | Replica failures | Check node disk health |

---

## Preventing Re-accumulation

The `cleanup-orphaned-resources` CronJob prevents orphan buildup. If it's not running:

```bash
# Manually trigger:
kubectl create job --from=cronjob/cleanup-orphaned-resources manual-cleanup-$(date +%s) -n kube-system
```

To skip cleanup for a specific PVC (e.g., during maintenance):
```bash
kubectl label pvc <name> cleanup.skip=true -n <namespace>
```
