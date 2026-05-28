# Homelab Runbooks

Operational runbooks for diagnosing and fixing common homelab issues. Created 2026-05-28.

## Runbooks

| File | Covers |
|------|--------|
| [nut-ups-shutdown.md](nut-ups-shutdown.md) | NUT UPS shutdown chain, 40% threshold, battery test script, nut-dw plugin persistence |
| [network-bonding-wol.md](network-bonding-wol.md) | NIC bonding (active-backup), fail_over_mac modes, Wake-on-LAN, ASUS router ARP binding |
| [longhorn-maintenance.md](longhorn-maintenance.md) | Longhorn orphan cleanup, DiskPressure / Unschedulable node recovery, orphaned PVCs |
| [patroni-postgres-pgbouncer.md](patroni-postgres-pgbouncer.md) | Patroni timeline mismatch, reinitialize, PostgreSQL 18 config, PgBouncer, vault-agent |
| [disk-management.md](disk-management.md) | LVM extension (Proxmox VM resize), log cleanup, journal tuning |

## Quick Reference

### SSH Access

```bash
sshpass -p "$(cat $HOME/ssh-keys/.unraid-password.txt)" ssh root@192.168.1.40   # tower.local
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.10    # proxmox-00
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.11  # talos-00
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.12  # talos-01
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.13  # talos-02
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.7     # vault-agent
```

### kubectl on Nodes

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

### Key Namespaces

| Namespace | Contents |
|-----------|----------|
| `storageclass-system` | Longhorn |
| `administrator-apps` | ArgoCD |
| `databases` | Dragonfly, Postgres-related apps |
| `kube-system` | Cleanup CronJobs |
