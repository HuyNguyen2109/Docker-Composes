# Homelab Power Scripts — Design Document

**Date:** 2026-05-26
**Author:** HuyNguyen2109
**Status:** Approved

---

## Overview

Two self-contained Bash scripts that run on **tower.local** (unRAID 7.3.0, 192.168.1.40) via the **User Scripts plugin**. One gracefully shuts down three homelab hosts; the other sends Wake-on-LAN magic packets to power them back on.

Because unRAID runs its root filesystem entirely in RAM (rebuilt from USB on every boot), both scripts are self-contained single files — no shared library dependencies. Each script is stored at:
- Repo: `scripts/homelab-shutdown.sh` and `scripts/homelab-wakeup.sh`
- Deployed to: `/boot/config/plugins/user.scripts/scripts/<name>/script` (persistent on USB)

---

## Host Inventory

| Name | IP | SSH User | Builtin NIC MAC (WOL) | USB Adapter MAC |
|---|---|---|---|---|
| proxmox-00 | 192.168.1.10 | root | `14:02:ec:49:37:30` | `c8:4d:44:23:3e:49` |
| talos-01 | 192.168.1.12 | ubuntu | `6c:4b:90:3b:d6:1b` | `c8:4d:44:23:3e:3a` |
| talos-02 | 192.168.1.13 | ubuntu | `6c:4b:90:5e:c3:9e` | `c8:4d:44:23:3e:4a` |

**Topology note:** talos-00 runs as a VM on proxmox-00. Proxmox handles graceful VM/LXC shutdown automatically when the host shuts down — no special sequencing required. talos-01 and talos-02 are dedicated bare-metal machines.

---

## Runtime Environment (tower.local)

- `etherwake` present at `/usr/sbin/etherwake` (part of unRAID base image, persistent)
- `ssh` present (part of unRAID base image, persistent)
- SSH private key: `~/.ssh/homelab-linux`
- LAN bridge interface: `br0`
- `/etc/hosts` is regenerated on boot; scripts append entries at runtime

---

## Script 1 — `homelab-shutdown.sh`

### Behaviour

1. **Dependency check**: verify `ssh` is available; exit with error if not
2. **`/etc/hosts` update**: append `proxmox-00`, `talos-01`, `talos-02` entries (idempotent — skip if already present)
3. **Parallel shutdown**: fire SSH shutdown commands to all three hosts simultaneously (background jobs):
   - `talos-01` and `talos-02`: `sudo shutdown -h now` (SSH as `ubuntu`)
   - `proxmox-00`: `shutdown -h now` (SSH as `root`; Proxmox handles all VMs/LXCs)
4. **Wait** for all SSH jobs to complete (captures per-host exit codes)
5. **Summary**: print ✓/✗ per host with color output

### SSH Invocation

```bash
ssh -i ~/.ssh/homelab-linux \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    <user>@<ip> "<command>"
```

### Error Handling

- A non-zero SSH exit code is reported per host but does not abort other shutdowns
- A host that is already down (connection refused/timeout) is reported as a warning, not failure

---

## Script 2 — `homelab-wakeup.sh`

### Behaviour

1. **Dependency check**: verify `etherwake` is available; if missing, install from Slackware repo via `upgradepkg --install-new` and copy `.txz` to `/boot/extra/` for persistence
2. **`/etc/hosts` update**: same as shutdown script
3. **Send WOL packets** (fire-and-forget):
   - proxmox-00: both builtin (`14:02:ec:49:37:30`) and USB (`c8:4d:44:23:3e:49`) NICs via `br0`
   - talos-01: both builtin (`6c:4b:90:3b:d6:1b`) and USB (`c8:4d:44:23:3e:3a`) NICs
   - talos-02: both builtin (`6c:4b:90:5e:c3:9e`) and USB (`c8:4d:44:23:3e:4a`) NICs
4. **Print result**: ✓ sent per host, exit

### WOL Invocation

```bash
etherwake -i br0 <MAC>
```

Both builtin and USB adapter MACs are targeted per host as a resilience measure (WOL works on whichever NIC the BIOS responds to).

---

## Package Installation Pattern (if needed)

```bash
# Find and download package (sub-agent queries slackware repo)
TXZ_FILE="<package>-<ver>-x86_64-1.txz"
upgradepkg --install-new "${TXZ_FILE}"
cp "${TXZ_FILE}" /boot/extra/   # persist across reboots
rm -f "${TXZ_FILE}"
```

---

## Self-Check (pre-save validation)

Before saving to `scripts/`, the scripts are validated from the development machine:

1. `bash -n <script>` — syntax check
2. SSH connectivity test to each host using `$HOME/ssh-keys/homelab-linux`, running `hostname` instead of `shutdown`
3. `etherwake` syntax validated with a dry invocation check

---

## Script Conventions

- `set -uo pipefail` (consistent with `vm-setup.sh`)
- Color output guarded by `[[ -t 1 ]]` TTY check
- Config block at the top of each script (names, IPs, MACs, users) as the single source of truth per file
- Symbols: `✓` (success), `✗` (failure), `⚠` (warning) — consistent with `vm-setup.sh`
