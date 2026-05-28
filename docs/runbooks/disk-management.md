# Disk Management — LVM, Log Cleanup & Storage

*Date: 2026-05-28 | Applies to: talos-00 (and any Proxmox-hosted VM)*

---

## talos-00 Disk Layout

talos-00 is a VM on proxmox-00 with a 256GB virtual disk.

```
/dev/sda (256GB virtual disk)
  └─ /dev/sda3 (252.9GB partition)
       └─ LVM PV (252.95GB)
            └─ ubuntu-vg (VG)
                 └─ ubuntu-lv (LV) → / filesystem
```

### Checking Disk Usage
```bash
df -h /                                # filesystem usage
sudo vgs                               # VG free space
sudo lvs                               # LV sizes
sudo pvs                               # PV size
```

---

## Expanding an LVM Logical Volume (VM Disk Resize)

When a Proxmox VM disk is resized, you typically need to:
1. Resize the partition (if needed) → `growpart`
2. Resize the PV → `pvresize`
3. Extend the LV → `lvextend`
4. Extend the filesystem → `resize2fs`

Steps 3 and 4 are **online-safe for ext4** — no unmount or reboot required.

### Check if VG has unallocated space
```bash
sudo vgs
# Look for "VFree" column — if non-zero, LV can be extended without partition changes
```

### Extend LV to use all free VG space
```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
# Verify:
df -h /
```

> **Root cause (talos-00, May 2026):** Proxmox disk was expanded 128GB→256GB and `pvresize` was run, but `lvextend` was never executed. The LV remained at 124.95GB despite 128GB free in the VG.

---

## Disk Space Quick Cleanup

When a node hits >90% disk usage, clean in this order:

### 1. systemd journal (often the largest)
```bash
# Check size:
sudo journalctl --disk-usage

# Vacuum to 500MB:
sudo journalctl --vacuum-size=500M

# Prevent recurrence — add to /etc/systemd/journald.conf:
[Journal]
SystemMaxUse=500M
MaxRetentionSec=2weeks

sudo systemctl restart systemd-journald
```

### 2. Kubernetes audit logs
```bash
ls -lh /var/log/kubernetes/audit/
# Keep 3 newest, delete rest:
ls -t /var/log/kubernetes/audit/*.log | tail -n +4 | xargs sudo rm -f
```

### 3. Syslog rotation backlog
```bash
sudo truncate -s 0 /var/log/syslog.1
sudo rm -f /var/log/syslog.{2,3,4}.gz /var/log/kern.log.{2,3,4}.gz
```

### 4. etcd backups (keep 2 newest)
```bash
ls -lt /var/backups/etcd-*/  # list by age
ls -td /var/backups/etcd-*/ | tail -n +3 | xargs sudo rm -rf
```

### 5. Container images (containerd)
```bash
sudo crictl rmi --prune  # removes unused images
```

### 6. Patroni/PostgreSQL data directory (if large)
```bash
du -sh /var/lib/postgresql/18/data
# If Patroni is in "start failed" loop, stop it to halt log spam
sudo systemctl stop patroni
# Fix the underlying issue (e.g., timeline mismatch → reinitialize)
# then restart
sudo systemctl start patroni
```

---

## Log Spam Prevention

### Patroni Start-Failed Loop
When Patroni cannot start Postgres (timeline mismatch, etc.), it retries every ~3 seconds, generating ~1GB+/day of syslog.

**Detection:**
```bash
grep -c "failed to start postgres" /var/log/syslog
```

**Fix:** Resolve the Patroni issue (see `patroni-postgres-pgbouncer.md`) or temporarily stop patroni service during diagnosis.

### pgBackRest Archive Log Verbosity
Default `info` level generates significant log volume on busy clusters.

In `/etc/pgbackrest/pgbackrest.conf`:
```ini
[global]
log-level-console = warn
log-level-file = warn
```

---

## Disk Usage Monitoring Queries

```bash
# Top 10 directories by size from root:
sudo du -x --max-depth=3 / 2>/dev/null | sort -rn | head -20

# Top 10 directories under /var:
sudo du -sh /var/*/ 2>/dev/null | sort -rh | head -10

# Find files > 100MB:
sudo find / -xdev -size +100M -not -path "*/proc/*" -ls 2>/dev/null | sort -k7 -rn | head -20
```

---

## Longhorn Block Device

Longhorn v2 uses `/dev/longhorn-v2-block` as a dedicated block device (separate from the OS LVM).

**Longhorn storage usage** is managed via Longhorn's own scheduler (see `longhorn-maintenance.md`), not via standard Linux disk tools. Do NOT use `lvextend` on the Longhorn block device.

To check available Longhorn storage:
```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf \
  kubectl get nodes.longhorn.io -n storageclass-system
```
