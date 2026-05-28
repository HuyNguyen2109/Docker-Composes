# NIC Bonding & Wake-on-LAN — Architecture & Troubleshooting

*Date: 2026-05-28 | Applies to: proxmox-00, talos-01, talos-02, tower.local*

---

## Architecture

All nodes use **active-backup bonding** with a 2.5G USB NIC (CyberPower RTL8156/r8152) as the primary interface for the 2.5G LAN network.

> ⚠️ **Critical requirement**: The USB NIC (`enxc84d44233e3:xx`) MUST remain the primary active interface on ALL nodes. Never change this to the onboard NIC.

### Node Inventory

| Node | Bond | Onboard NIC | USB NIC (Primary) | Bond MAC | IP |
|------|------|-------------|-------------------|----------|----|
| proxmox-00 | bond0 | eno1 (1G) | enxc84d44233e49 (2.5G) | (USB NIC MAC) | 192.168.1.10 |
| talos-01 | bond0 | enp0s31f6 | enxc84d44233e3a (2.5G) | `8a:c0:fc:36:31:75` | 192.168.1.12 |
| talos-02 | bond0 | (onboard) | enxc84d44233e4a (2.5G) | (USB NIC MAC) | 192.168.1.13 |
| tower.local | bond0 | eth1 (1G) | eth0/enxc84d44233e3c (2.5G) | (USB NIC MAC) | 192.168.1.40 |

---

## fail_over_mac Modes (Critical for WOL)

> This is a source of subtle bugs. Understand this before changing bonding config.

### `fail_over_mac=none` (default, used on talos-01)

- Bond driver **overwrites both slave NICs' active MAC registers** with the bond MAC
- On shutdown, NICs retain the bond MAC (`8a:c0:fc:36:31:75`)
- **WOL targets the bond MAC** — not the burned-in hardware MACs
- The hardware/permanent MACs (`6c:4b:90:3b:d6:1b`, `c8:4d:44:23:3e:3a`) are IGNORED by WOL

### `fail_over_mac=active`

- Each slave NIC keeps its own hardware MAC
- Bond takes the MAC of the currently active slave
- **WOL targets the active slave's hardware MAC** at time of shutdown
- If failover occurs before shutdown, WOL MAC may differ from what's in the script

### talos-01 Current Config (`fail_over_mac=none`)

```yaml
# /etc/netplan/50-cloud-init.yaml
bonds:
  bond0:
    interfaces: [enp0s31f6, enxc84d44233e3a]
    macaddress: 8a:c0:fc:36:31:75   # explicit MAC lock — REQUIRED
    parameters:
      mode: active-backup
      primary: enxc84d44233e3a       # USB NIC as primary
      mii-monitor-interval: 100
```

> The explicit `macaddress: 8a:c0:fc:36:31:75` locks the bond to the MAC the ASUS router recognizes. Without it, removing `fail-over-mac-policy: active` causes the router's static ARP binding to break internet access.

---

## Wake-on-LAN (WOL)

### Script Location

- **Repo:** `scripts/homelab-wakeup.sh`
- **Live (tower.local):** `/boot/config/plugins/user.scripts/scripts/kubernetes-node-startup/script`

### WOL MAC Reference

| Node | WOL MAC | Why |
|------|---------|-----|
| talos-00 | `6c:4b:90:3b:d6:1b` | Onboard NIC (single NIC VM) |
| talos-01 | `8a:c0:fc:36:31:75` | Bond MAC (`fail_over_mac=none` overwrites slave NICs) |
| talos-02 | (check `/etc/netplan/`) | Bond MAC or USB NIC hardware MAC |

### Sending WOL Packets

```bash
# From tower.local (br0 is the LAN bridge)
etherwake -i br0 8a:c0:fc:36:31:75   # talos-01
```

### Verifying WOL MAC After Changes

If bonding config changes (mode, fail_over_mac, or slave list), verify the MAC that's programmed into the NIC WOL register:

```bash
# Check current active MAC on slaves:
cat /sys/class/net/enxc84d44233e3a/address   # what the NIC currently uses
# On shutdown, this is what WOL will listen for
```

---

## Troubleshooting

### Symptom: No internet after netplan change (talos-01 / similar)

Root cause pattern: Changing `fail-over-mac-policy` changes the bond MAC. ASUS router has a **persistent static ARP binding** (via ARP Binding feature) that ignores gratuitous ARP updates.

**Diagnosis:**
```bash
# Run with -e to show ethernet headers:
sudo tcpdump -i bond0 -n -e icmp
# If ICMP replies arrive but are addressed to a DIFFERENT MAC than bond0:
# → router has a stale/static ARP binding
```

**Fix options:**
1. **Preferred — restore the original MAC:**
   ```bash
   # In /etc/netplan/50-cloud-init.yaml, add:
   macaddress: <original-bond-mac>
   # Remove fail-over-mac-policy if present
   ```
   Then apply with a live bond rebuild script (netplan apply alone won't move live bond MAC):
   ```bash
   # Safely rebuild bond live:
   IFACE=enxc84d44233e3a
   ip link set bond0 nomaster  # remove slaves
   # wait, then re-enslave
   ip link set $IFACE master bond0
   echo $IFACE > /sys/class/net/bond0/bonding/primary
   ```

2. **Alternative — log into ASUS router admin:**
   - Go to LAN → ARP Binding (or Wireless → Professional)
   - Update the MAC entry for the node's IP

### Symptom: WOL not waking talos-01

1. Check the WOL MAC in the script matches the bond MAC:
   ```bash
   cat /sys/class/net/bond0/bonding/active_slave
   # then check that slave's address:
   cat /sys/class/net/enxc84d44233e3a/address
   ```
2. Update `HOSTS` entry in `scripts/homelab-wakeup.sh` if different
3. Deploy updated script to tower.local:
   ```bash
   sshpass -p "$(cat $HOME/ssh-keys/.unraid-password.txt)" \
     scp scripts/homelab-wakeup.sh \
     root@192.168.1.40:/boot/config/plugins/user.scripts/scripts/kubernetes-node-startup/script
   ```

### Symptom: proxmox-00 USB NIC loses bond primary

The r8152 (RTL8156) driver performs periodic USB firmware resets. Pre-existing infrastructure handles this automatically:

```bash
# Check if hotplug handler is present:
ls /etc/udev/rules.d/99-usb-autosuspend.rules   # udev rule
ls /usr/local/sbin/usb-nic-bond-readd            # re-enslave script
ls /etc/network/if-up.d/usb-bond-fix             # if-up hook

# Monitor USB resets:
dmesg | grep -i r8152
# Verify current bond primary:
cat /sys/class/net/bond0/bonding/active_slave
```

---

## proxmox-00 Bond Configuration

proxmox-00 uses a bridge (`vmbr0`) over the bond (not directly on bond0):
```
vmbr0 (bridge, IP 192.168.1.10)
  └─ bond0 (active-backup)
       ├─ eno1 (1G Intel i350)
       └─ enxc84d44233e49 (2.5G USB r8152, PRIMARY)
```

Bond parameters in `/etc/network/interfaces`:
```
bond-slaves eno1 enxc84d44233e49
bond-mode active-backup
bond-primary enxc84d44233e49   # USB NIC MUST be primary
bond-miimon 100
bond-primary-reselect always
```
