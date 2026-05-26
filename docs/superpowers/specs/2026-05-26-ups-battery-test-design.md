# UPS Battery Exercise Script — Design Document

**Date:** 2026-05-26  
**Author:** HuyNguyen2109  
**Status:** Implemented

---

## Overview

`scripts/bi-weekly-ups-battery-test.sh` automates a bi-weekly deep battery exercise for a UPS managed by NUT (Network UPS Tools). The script sends the `test.battery.start.deep` instant command via `upscmd`, monitors `battery.charge` via `upsc` until it reaches a configurable threshold (default 30%), then stops the test with `test.battery.stop` and waits for the UPS to return to Online (OL) status.

A bi-weekly gate enforces a minimum 10-day gap between runs so aging batteries are not over-stressed. A `--dry-run` flag validates the pre-flight checks and NUT connectivity without touching the UPS.

Deployed to unRAID tower.local as a User Scripts plugin entry:
```
/boot/config/plugins/user.scripts/scripts/<name>/script
```

---

## 1. NUT Requirements

The NUT user referenced by `NUT_USER` **must** have `instcmds` permission in `/etc/nut/upsd.users`. `upsmon`-only users (e.g. `monuser`, `slaveuser`) lack this permission and will fail silently at the `upscmd -l` (list) check — but fail loudly at Stage 1 when the command is actually sent.

Required `upsd.users` entry:
```ini
[admin]
  password = <password>
  actions  = SET
  instcmds = ALL
```

UPS instant commands required:
- `test.battery.start.deep` — starts a full deep discharge test
- `test.battery.stop` — stops the test and returns to normal

Verify the UPS supports both:
```bash
upscmd -l <ups_name>@<host>
```

---

## 2. Configuration

All user-facing configuration lives in a single block at the top of the script (edit this block only):

| Variable | Default | Purpose |
|---|---|---|
| `UPS_NAME` | `<upsc -l>` | NUT UPS name (find with `upsc -l`) |
| `UPS_HOST` | `<host>` | NUT server host (e.g. `127.0.0.1`) |
| `NUT_USER` | `<user>` | upsd user — **MUST** have `instcmds = ALL` |
| `NUT_PASS` | `<password>` | upsd user password |
| `STOP_PCT` | `30` | Battery % at which to stop the deep test |
| `POLL_INTERVAL` | `60` | Seconds between `battery.charge` polls during test |
| `TIMEOUT_SECS` | `7200` | Hard 2-hour cap — stops test if `STOP_PCT` never reached |
| `ONLINE_WAIT_SECS` | `300` | Max seconds to wait for OL after stopping test |
| `SAFETY_THRESHOLD` | `80` | Abort if charge is already below this % before starting |
| `LOGFILE` | `/var/log/ups_battery_sim.log` | Append-only log |
| `STATEFILE` | `/tmp/ups_battery_sim.last` | Epoch of last successful run (governs bi-weekly gate) |

---

## 3. Script Architecture

```
bi-weekly-ups-battery-test.sh
├── USER CONFIGURATION BLOCK  (only edit block)
│
├── INTERNAL VARS
│     DRY_RUN=false
│     UPS="${UPS_NAME}@${UPS_HOST}"
│
├── HELPERS
│     log()       → timestamped tee to LOGFILE
│                   format: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
│     die()       → log ERROR + exit 1
│     get_var()   → upsc ${UPS} <variable>   (stderr suppressed)
│     send_cmd()  → upscmd -u/p ...           (no-op + log in dry-run)
│     has_cmd()   → upscmd -l | grep "^<cmd>" (no auth needed)
│
├── STAGE 0 – preflight()       hard-abort on every failure
│     • NUT tools in PATH: upsc, upscmd
│     • UPS reachable: upsc ${UPS}
│     • Required instant commands listed: has_cmd × 2
│     • UPS status: OL present, OB/LB/FSD absent
│     • battery.charge ≥ SAFETY_THRESHOLD
│     • Bi-weekly gate: diff_days ≥ 10  (or no STATEFILE)
│
├── STAGE 1 – stage_start_test()
│     • send_cmd test.battery.start.deep  (fatal on failure)
│     • sleep 5 — settle time
│     • Log post-start ups.status + battery.charge
│
├── STAGE 2 – stage_monitor()
│     • Loop every POLL_INTERVAL seconds:
│         get_var battery.charge / ups.status / battery.runtime
│         log all three values + elapsed
│     • Break conditions:
│         charge ≤ STOP_PCT       → normal target reached
│         elapsed ≥ TIMEOUT_SECS  → hard timeout safety net
│         ups.status has FSD       → emergency abort
│     • DRY_RUN: skip entirely
│
├── STAGE 3 – stage_stop_test()
│     • send_cmd test.battery.stop  (non-fatal: WARN if fails)
│     • sleep 5 — settle time
│     • Log post-stop ups.status + battery.charge
│
├── STAGE 4 – stage_wait_online()
│     • Poll every 15s: OL present AND OB absent = success
│     • Max ONLINE_WAIT_SECS; WARN if exceeded
│     • DRY_RUN: skip entirely
│
├── STAGE 5 – stage_finalise()
│     • Log final battery.charge + ups.status
│     • Write date +%s → STATEFILE  (DRY_RUN: skip)
│
├── CLEANUP TRAP  (trap cleanup EXIT)
│     • On non-zero exit: send_cmd test.battery.stop as safety net
│     • Prevents test running indefinitely if script dies mid-run
│
└── MAIN
      • getopts-style while loop: --dry-run flag
      • Execute Stage 0 → 5 in order
```

---

## 4. Execution Stages

### Stage 0 — Pre-flight
All checks call `die()` on failure — the test never starts if any check fails.

| Check | Abort condition |
|---|---|
| NUT tools | `upsc` or `upscmd` missing from PATH |
| UPS reachable | `upsc $UPS` returns non-zero |
| Instant commands | `test.battery.start.deep` or `test.battery.stop` not listed by driver |
| UPS status | Has `OB`, `LB`, or `FSD`; or is missing `OL` |
| Battery charge | `battery.charge` < `SAFETY_THRESHOLD` (80%) |
| Bi-weekly gate | Last run < 10 days ago per STATEFILE |

### Stage 1 — Start Test
Sends `test.battery.start.deep`. Fatal if it fails — the most common cause is using a NUT user without `instcmds` permission (e.g. `monuser`). Logs post-start status after a 5-second settle.

### Stage 2 — Monitor Discharge
Polls `battery.charge` every `POLL_INTERVAL` seconds. Three exit conditions:

| Condition | Outcome |
|---|---|
| `charge ≤ STOP_PCT` | Normal — target reached |
| `elapsed ≥ TIMEOUT_SECS` | Hard timeout safety net — stops test regardless |
| `ups.status` contains `FSD` | Emergency abort |

### Stage 3 — Stop Test
Sends `test.battery.stop`. Non-fatal: if the command fails (UPS may have ended the test naturally), a WARN is logged and the script continues. Logs post-stop status after 5-second settle.

### Stage 4 — Wait for Online
Polls `ups.status` every 15 seconds until `OL` appears without `OB`. Warns and returns 1 if `ONLINE_WAIT_SECS` is exceeded (human inspection needed).

### Stage 5 — Finalise
Logs final charge and status. Writes Unix epoch to `STATEFILE` to arm the bi-weekly gate for the next run.

---

## 5. Safety Mechanisms

| Mechanism | Purpose |
|---|---|
| `SAFETY_THRESHOLD=80` | Never start the test below 80% charge |
| `STOP_PCT=30` | Never drain below 30% |
| `TIMEOUT_SECS=7200` | Hard 2-hour cap regardless of charge level |
| FSD detection in monitor loop | Emergency stop if UPS signals forced shutdown |
| OB/LB/FSD pre-flight abort | Don't start if UPS is already under stress |
| `trap cleanup EXIT` | Always sends `test.battery.stop` on unexpected script exit |
| Bi-weekly gate (10 days) | Prevents back-to-back runs that stress aging batteries |

---

## 6. Dry-Run Mode

Invoked with `--dry-run`. All real NUT connectivity checks run; only destructive/state-changing operations are skipped.

| Runs for real | Skipped |
|---|---|
| NUT tool presence check | All `upscmd` send calls (logged as `[DRY-RUN] Would run: ...`) |
| UPS reachability (`upsc`) | Stage 2 discharge monitoring loop |
| Instant command listing (`upscmd -l`) | Stage 4 OL wait loop |
| All pre-flight status/charge checks | `STATEFILE` write |
| 5s settle sleeps in Stage 1 and 3 | — |

Use this in unRAID User Scripts' "Test" button to verify NUT config without risking a live battery drain.

---

## 7. Logging

All output is dual-written: stdout and `LOGFILE` via `tee -a`. Format:
```
[2026-05-26 09:35:59] [INFO ] Deep battery test started successfully.
[2026-05-26 09:36:04] [WARN ] Timeout of 7200s reached before charge hit 30%.
[2026-05-26 09:36:04] [ERROR] Failed to send test.battery.start.deep. Check NUT user permissions (instcmds = ALL).
```

Log levels: `INFO`, `WARN`, `ERROR`. Each level is left-padded to 5 chars for alignment.

---

## 8. Bi-Weekly Gate

`STATEFILE` stores a Unix epoch timestamp. On each run:
```bash
diff_days=$(( (now_ts - last_run) / 86400 ))
[[ diff_days < 10 ]] → die "Last run was N day(s) ago. Bi-weekly gate active."
```

> **⚠ unRAID note:** `/tmp` is ephemeral and cleared on reboot. If the server reboots between scheduled runs, the gate resets. To preserve state across reboots, change `STATEFILE` to a persistent path:
> ```bash
> STATEFILE="/boot/config/ups_battery_sim.last"
> ```

---

## 9. Scheduling on unRAID

Live script location:
```
/boot/config/plugins/user.scripts/scripts/<name>/script
```

Recommended User Scripts cron schedule (1st and 15th of each month at 03:00):
```
0 3 1,15 * *
```

File permission: `chmod 700` to protect embedded credentials.

---

## 10. Files

| Path | Purpose |
|---|---|
| `scripts/bi-weekly-ups-battery-test.sh` | Template with placeholder credentials (version-controlled) |
| `/boot/config/plugins/user.scripts/scripts/<name>/script` | Live copy on unRAID with real credentials |
| `/var/log/ups_battery_sim.log` | Append-only runtime log |
| `/tmp/ups_battery_sim.last` | Epoch of last successful run (ephemeral — see § 8) |
| `/etc/nut/upsd.users` | NUT user config — must contain `instcmds = ALL` for the script user |
