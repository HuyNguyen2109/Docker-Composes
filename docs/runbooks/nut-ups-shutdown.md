# NUT UPS Shutdown — Configuration & Troubleshooting

*Date: 2026-05-28 | Applies to: tower.local (master), proxmox-00, talos-01, talos-02*

---

## Architecture

```
UPS hardware (VP1200ELCD, USB)
  └─ usbhid-ups driver
       └─ upsd (tower.local:3493)
            ├─ upsmon master (tower.local) + nut-notify (40% poller)
            ├─ upsmon slave (proxmox-00) → SHUTDOWNCMD
            ├─ upsmon slave (talos-01)   → SHUTDOWNCMD
            └─ upsmon slave (talos-02)   → SHUTDOWNCMD
```

### 40% Shutdown Mechanism (unRAID nut-dw plugin)

The 40% threshold is **NOT** a native NUT feature. It is implemented by the `nut-dw` plugin:

1. `NOTIFYFLAG ONBATT SYSLOG+EXEC` triggers `/usr/sbin/nut-notify`
2. `nut-notify` polls `battery.charge` every second while on battery
3. At ≤40%, it runs `upsmon -c fsd` (Forced Shutdown Directive)
4. FSD propagates to all connected slaves → each runs `SHUTDOWNCMD`

The native NUT `LB` flag (`battery.charge.low`) is set to 40% as a second-line safety net via `override.battery.charge.low = 40` in `ups.conf`.

### Key Credentials

| User | Password | Role |
|------|----------|------|
| `admin` | `adminpass` | Full control (`instcmds = all`, `actions = set/fsd`) |
| `monuser` | `Master2109` | Master upsmon (tower.local) |
| `slaveuser` | `Master2109` | Slave upsmon (proxmox-00, talos-01, talos-02) |

UPS name: `VP1200ELCD`, driver: `usbhid-ups`, port: `auto`, host: `127.0.0.1`

---

## Configuration Files (tower.local)

### Persistence Model (unRAID nut-dw)

> ⚠️ `/etc/nut/` is ephemeral (initramfs). Changes MUST be made to **both** locations:
>
> | Live (ephemeral) | Persistent (flash) |
> |---|---|
> | `/etc/nut/<file>` | `/boot/config/plugins/nut-dw/ups/<file>` |
>
> On every boot: `doinst.sh` runs `cp -rf $BOOT/ups/* /etc/nut/`, then `write_config()` patches lines 1–8 of `ups.conf` and lines 1/3/8 of `upsmon.conf`. **Lines 9+ in both files survive reboots** and `write_config` patches.

### `/etc/nut/ups.conf` (lines 9+ survive reboots)
```ini
[VP1200ELCD]
driver = usbhid-ups
port = auto
# line 9 (persistent):
override.battery.charge.low = 40
```

Apply changes:
```bash
upsdrvctl stop VP1200ELCD && upsdrvctl start VP1200ELCD
# verify:
upsc VP1200ELCD battery.charge.low   # should return 40
```

### `/etc/nut/upsmon.conf` (lines 9+ survive reboots)
```
# lines 9–10 (persistent):
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
```

Apply changes: `upsmon -c reload`

### `/boot/config/plugins/nut-dw/nut-dw.cfg`
Source of truth for nut-dw GUI settings. Key relevant fields:
```
BATTERYLEVEL="40"
SHUTDOWN="batt_level"
SERVICE="enable"
MODE="netserver"
UPSKILL=disable
```
> Do NOT edit manually unless necessary.

---

## Slave Node Configuration

All slaves use the same upsmon configuration:
```
MONITOR VP1200ELCD@192.168.1.40 1 slaveuser Master2109 slave
SHUTDOWNCMD "/sbin/poweroff"
POLLFREQ 5
DEADTIME 15
FINALDELAY 5
NOCOMMWARNTIME 300
```

Check service status on slaves:
```bash
# proxmox-00
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.10 "systemctl status nut-monitor"
# talos-01/02
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.12 "sudo systemctl status nut-monitor"
```

> ⚠️ On talos nodes, `/etc/nut/upsmon.conf` is owned `root:nut 640` — unreadable by `ubuntu` user. Use `sudo cat`.

---

## Bi-Weekly Battery Test Script

**Location (tower.local):** `/boot/config/plugins/user.scripts/scripts/lxc-auto-backup/script`
*(folder misnamed; "name" file = "bi-weekly-ups-battery-check")*

**Repo template:** `scripts/bi-weekly-ups-battery-test.sh`

### Dry Run
```bash
bash script --dry-run
```

### Live Run Requirements
- `NUT_USER` must be `admin` (not `monuser`/`slaveuser` — those lack `instcmds`)
- UPS must be `OL` (on-line) at start
- Battery ≥85% at start
- Must not have run in the last 13 days (bi-weekly gate via statefile)

### Sending Commands
```bash
# Send battery test
upscmd -u admin -p adminpass VP1200ELCD@127.0.0.1 test.battery.start.deep
# Stop test early
upscmd -u admin -p adminpass VP1200ELCD@127.0.0.1 test.battery.stop
# Check status
upsc VP1200ELCD@127.0.0.1
```

### Statefile
Written to `/tmp/bi-weekly-ups-battery-test.state` after each successful run. Note: `/tmp` on unRAID is ephemeral (RAM); statefile is lost on reboot. The script uses the creation time of this file to enforce the 13-day gate.

---

## Troubleshooting

### Symptom: Slaves don't shut down at 40% battery

1. **Verify threshold is set:**
   ```bash
   upsc VP1200ELCD battery.charge.low  # should be 40
   ```
   If not: add `override.battery.charge.low = 40` to `ups.conf` (both paths).

2. **Verify nut-notify is running when on battery:**
   ```bash
   ps aux | grep nut-notify  # should appear when OB
   ```

3. **Verify FSD propagates to slaves:**
   ```bash
   # Simulate FSD (controlled test only!)
   upsmon -c fsd  # on tower.local
   # Monitor slave logs:
   ssh ubuntu@192.168.1.12 "sudo journalctl -u nut-monitor -f"
   ```

4. **Verify slave connectivity:**
   ```bash
   upsc VP1200ELCD@192.168.1.40  # from a slave node
   ```

### Symptom: "Failed to send test.battery.start.deep" permission error

The script is using `monuser` or `slaveuser`. Change `NUT_USER` to `admin`.
Verify: `grep 'instcmds' /etc/nut/upsd.users`

### Symptom: proxmox-00 shows periodic "No route to host" to tower.local

Root cause: USB NIC (`enxc84d44233e49`) r8152 driver periodically performs USB firmware resets.
The bond reselects the USB NIC as primary after each reset, causing brief TCP teardowns.

Mitigation: Existing infrastructure on proxmox-00 handles re-enslavement:
- `/etc/udev/rules.d/99-usb-autosuspend.rules` — disables autosuspend + triggers readd
- `/usr/local/sbin/usb-nic-bond-readd` — re-enslaves and sets USB NIC as primary after reconnect

Monitor USB resets: `dmesg | grep r8152`

---

## SSH Access Reference

```bash
# tower.local (password auth)
sshpass -p "$(cat $HOME/ssh-keys/.unraid-password.txt)" ssh root@192.168.1.40

# proxmox-00
ssh -i $HOME/ssh-keys/homelab-linux root@192.168.1.10

# talos-01
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.12

# talos-02
ssh -i $HOME/ssh-keys/homelab-linux ubuntu@192.168.1.13
```
