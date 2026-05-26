# UPS Battery Exercise Script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `scripts/bi-weekly-ups-battery-test.sh`, a self-contained Bash script that exercises a NUT-managed UPS battery on a bi-weekly schedule by sending NUT instant commands, monitoring discharge, and stopping safely at a configurable charge threshold.

**Architecture:** A single Bash script with no external dependencies beyond the NUT tools (`upsc`, `upscmd`). Built around a `log()`/`die()`/`send_cmd()`/`get_var()` helper layer, six sequential stages, a `trap cleanup EXIT` safety net, and a `--dry-run` flag that skips all destructive operations while still exercising NUT connectivity. A state file records the last successful run epoch to enforce the bi-weekly gate.

**Tech Stack:** Bash (no version guard required — unRAID ships Bash 5+), NUT (`upsc`, `upscmd`), `shellcheck` for linting

**Spec:** `docs/superpowers/specs/2026-05-26-ups-battery-test-design.md`

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `scripts/bi-weekly-ups-battery-test.sh` | Create | Complete script — all logic in one file |
| `/boot/config/plugins/user.scripts/scripts/<name>/script` | Deploy | Live copy on unRAID with real credentials |
| `/etc/nut/upsd.users` | Configure (on host) | NUT user must have `instcmds = ALL` |

---

## Task 1: Script skeleton — shebang, config block, internal vars, helpers

**Files:**
- Create: `scripts/bi-weekly-ups-battery-test.sh`

- [ ] **Step 1: Create the file with shebang, header comment, config block, and helpers**

```bash
cat > scripts/bi-weekly-ups-battery-test.sh << 'EOF'
#!/bin/bash
# =============================================================================
#  ups_battery_sim.sh
#  Bi-weekly UPS battery exercise simulation via NUT (Network UPS Tools)
#
#  Strategy
#  --------
#  Uses the native NUT instant commands:
#    • test.battery.start.deep  – starts a full deep discharge test
#    • test.battery.stop        – stops the test and returns to normal
#
#  The script monitors battery.charge via `upsc` during the test and
#  automatically calls test.battery.stop once charge reaches STOP_PCT (30%).
#  The UPS then resumes charging on its own (OL + CHRG status).
#
#  Simulation flow
#  ---------------
#    Stage 0 – Pre-flight safety checks & bi-weekly gate
#    Stage 1 – Start deep battery test  (test.battery.start.deep)
#    Stage 2 – Poll battery.charge every POLL_INTERVAL seconds
#              until charge ≤ STOP_PCT or TIMEOUT_SECS exceeded
#    Stage 3 – Stop test  (test.battery.stop)
#    Stage 4 – Wait for UPS to return to OL (charging) status
#    Stage 5 – Log result and update state file
#
#  Cron (bi-weekly example — 1st and 15th at 03:00)
#  --------------------------------------------------
#    0 3 1,15 * *   root   /boot/config/plugins/nut/ups_battery_sim.sh
#
#  NUT upsd.users requirement
#  --------------------------
#  The NUT user needs:
#    actions   = SET
#    instcmds  = ALL          (or at minimum: test.battery.start.deep test.battery.stop)
#
#  Dry-run mode
#  ------------
#  Pass --dry-run to validate pre-flight checks without sending any upscmd commands.
#  All send_cmd calls are logged but not executed; exit on permission errors is skipped.
# =============================================================================

# ---------------------------------------------------------------------------
# USER CONFIGURATION  –  edit this block only
# ---------------------------------------------------------------------------

UPS_NAME="<upsc -l>"                  # NUT UPS name  (verify with: upsc -l)
UPS_HOST="<host>"                     # NUT server host
NUT_USER="<user>"                     # upsd user — MUST have instcmds = ALL in upsd.users
                                      # NOTE: upsmon-only users (e.g. monuser/slaveuser) lack
                                      #       instcmds permission and will fail at Stage 1
NUT_PASS="<password>"                 # upsd password  (chmod 700 this file!)

STOP_PCT=30                           # Stop the deep test when charge reaches this %
POLL_INTERVAL=60                      # Seconds between each battery.charge poll
TIMEOUT_SECS=7200                     # Hard timeout (2 h) — stops test if STOP_PCT never reached
ONLINE_WAIT_SECS=300                  # Max seconds to wait for OL status after stopping test

SAFETY_THRESHOLD=80                   # Abort if current charge is already below this %

LOGFILE="/var/log/ups_battery_sim.log"
STATEFILE="/tmp/ups_battery_sim.last" # Stores epoch of last successful run

# ---------------------------------------------------------------------------
# INTERNAL VARS
# ---------------------------------------------------------------------------

DRY_RUN=false
UPS="${UPS_NAME}@${UPS_HOST}"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

log() {
    local level="$1"; shift
    printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" \
        | tee -a "${LOGFILE}"
}

die() {
    log "ERROR" "$*"
    exit 1
}

get_var() {
    upsc "${UPS}" "$1" 2>/dev/null
}

send_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would run: upscmd -u ${NUT_USER} ${UPS} $1"
        return 0
    fi
    upscmd -u "${NUT_USER}" -p "${NUT_PASS}" "${UPS}" "$1" 2>/dev/null
}

has_cmd() {
    upscmd -l "${UPS}" 2>/dev/null | grep -q "^$1"
}
EOF
chmod 700 scripts/bi-weekly-ups-battery-test.sh
```

- [ ] **Step 2: Verify shellcheck is clean**

```bash
shellcheck scripts/bi-weekly-ups-battery-test.sh
```

Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: add ups battery test skeleton with config block and helpers"
```

---

## Task 2: Stage 0 — Pre-flight checks

**Files:**
- Modify: `scripts/bi-weekly-ups-battery-test.sh`

- [ ] **Step 1: Add the `preflight()` function**

Append to the script (before `main`):

```bash
# ---------------------------------------------------------------------------
# STAGE 0 – PRE-FLIGHT
# ---------------------------------------------------------------------------

preflight() {
    log "INFO" "========================================================"
    log "INFO" " UPS Battery Exercise Simulation — START"
    log "INFO" "========================================================"
    log "INFO" "UPS        : ${UPS}"
    log "INFO" "Stop at    : ${STOP_PCT}%"
    log "INFO" "Poll every : ${POLL_INTERVAL}s  |  Timeout: ${TIMEOUT_SECS}s"

    # NUT tools must be present
    for tool in upsc upscmd; do
        command -v "${tool}" &>/dev/null \
            || die "'${tool}' not found — is the NUT plugin installed?"
    done

    # UPS must be reachable
    upsc "${UPS}" &>/dev/null \
        || die "Cannot reach UPS '${UPS}'. Check that upsd is running."

    # Verify the required instant commands are actually supported
    for cmd in test.battery.start.deep test.battery.stop; do
        has_cmd "${cmd}" \
            || die "Instant command '${cmd}' is NOT supported by this driver/UPS. Aborting."
    done
    log "INFO" "Confirmed: test.battery.start.deep and test.battery.stop are available."

    # Current UPS status check
    local status
    status=$(get_var "ups.status")
    log "INFO" "Current ups.status     : ${status}"

    echo "${status}" | grep -qw "OB"  && die "UPS is already On Battery (OB). Aborting."
    echo "${status}" | grep -qw "LB"  && die "UPS reports Low Battery (LB). Aborting."
    echo "${status}" | grep -qw "FSD" && die "UPS has Forced Shutdown flag (FSD). Aborting."
    echo "${status}" | grep -qw "OL"  || die "UPS is not On Line (OL). Current status: ${status}. Aborting."

    # Charge safety check
    local cur_charge
    cur_charge=$(get_var "battery.charge")
    log "INFO" "Current battery.charge : ${cur_charge}%"
    [[ -z "${cur_charge}" ]] && die "Could not read battery.charge from UPS."
    (( cur_charge < SAFETY_THRESHOLD )) \
        && die "Battery charge (${cur_charge}%) is below safety threshold (${SAFETY_THRESHOLD}%). Aborting."

    # Bi-weekly gate: refuse if last run was < 10 days ago
    if [[ -f "${STATEFILE}" ]]; then
        local last_run now_ts diff_days
        last_run=$(cat "${STATEFILE}")
        now_ts=$(date +%s)
        diff_days=$(( (now_ts - last_run) / 86400 ))
        if (( diff_days < 10 )); then
            die "Last successful run was ${diff_days} day(s) ago (< 10 days). Bi-weekly gate active."
        fi
        log "INFO" "Last run was ${diff_days} day(s) ago — OK to proceed."
    else
        log "INFO" "No previous run state found — first execution."
    fi

    log "INFO" "Pre-flight passed ✓"
}
```

- [ ] **Step 2: Verify shellcheck clean**

```bash
shellcheck scripts/bi-weekly-ups-battery-test.sh
```

Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: add ups battery test stage 0 pre-flight checks"
```

---

## Task 3: Stages 1–3 — Start, monitor, stop

**Files:**
- Modify: `scripts/bi-weekly-ups-battery-test.sh`

- [ ] **Step 1: Add `stage_start_test()`**

```bash
# ---------------------------------------------------------------------------
# STAGE 1 – START DEEP BATTERY TEST
# ---------------------------------------------------------------------------

stage_start_test() {
    log "INFO" "--------------------------------------------------------"
    log "INFO" "Stage 1 — Sending: test.battery.start.deep"
    log "INFO" "--------------------------------------------------------"

    if send_cmd "test.battery.start.deep"; then
        log "INFO" "Deep battery test started successfully."
        log "INFO" "UPS is now discharging under load (OB mode)."
    else
        die "Failed to send test.battery.start.deep. Check NUT user permissions (instcmds = ALL)."
    fi

    sleep 5

    local status charge
    status=$(get_var "ups.status")
    charge=$(get_var "battery.charge")
    log "INFO" "Post-start  ups.status     : ${status}"
    log "INFO" "Post-start  battery.charge : ${charge}%"
}
```

- [ ] **Step 2: Add `stage_monitor()`**

```bash
# ---------------------------------------------------------------------------
# STAGE 2 – MONITOR DISCHARGE UNTIL STOP_PCT
# ---------------------------------------------------------------------------

stage_monitor() {
    log "INFO" "--------------------------------------------------------"
    log "INFO" "Stage 2 — Monitoring discharge to ${STOP_PCT}%"
    log "INFO" "--------------------------------------------------------"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Skipping discharge monitoring loop."
        return 0
    fi

    local elapsed=0
    local charge status runtime

    while true; do
        charge=$(get_var "battery.charge")
        status=$(get_var "ups.status")
        runtime=$(get_var "battery.runtime")

        local rt_display="N/A"
        if [[ -n "${runtime}" ]]; then
            rt_display="${runtime}s (~$(( runtime / 60 ))m)"
        fi

        log "INFO" "charge=${charge}%  status=${status}  runtime_left=${rt_display}  elapsed=${elapsed}s"

        if [[ -n "${charge}" ]] && (( charge <= STOP_PCT )); then
            log "INFO" "Target reached: battery.charge (${charge}%) ≤ STOP_PCT (${STOP_PCT}%)."
            break
        fi

        if (( elapsed >= TIMEOUT_SECS )); then
            log "WARN" "Timeout of ${TIMEOUT_SECS}s reached before charge hit ${STOP_PCT}%."
            log "WARN" "Current charge: ${charge}%. Stopping test now."
            break
        fi

        if echo "${status}" | grep -qw "FSD"; then
            log "ERROR" "UPS flagged Forced Shutdown (FSD) during test! Stopping immediately."
            break
        fi

        sleep "${POLL_INTERVAL}"
        elapsed=$(( elapsed + POLL_INTERVAL ))
    done

    log "INFO" "Monitoring complete. Final charge: $(get_var battery.charge)%"
}
```

- [ ] **Step 3: Add `stage_stop_test()`**

```bash
# ---------------------------------------------------------------------------
# STAGE 3 – STOP DEEP BATTERY TEST
# ---------------------------------------------------------------------------

stage_stop_test() {
    log "INFO" "--------------------------------------------------------"
    log "INFO" "Stage 3 — Sending: test.battery.stop"
    log "INFO" "--------------------------------------------------------"

    if send_cmd "test.battery.stop"; then
        log "INFO" "Battery test stopped. UPS will now return to mains power."
    else
        log "WARN" "test.battery.stop command returned non-zero."
        log "WARN" "The UPS may have already ended the test naturally — monitoring status..."
    fi

    sleep 5
    local status charge
    status=$(get_var "ups.status")
    charge=$(get_var "battery.charge")
    log "INFO" "Post-stop   ups.status     : ${status}"
    log "INFO" "Post-stop   battery.charge : ${charge}%"
}
```

- [ ] **Step 4: Verify shellcheck clean**

```bash
shellcheck scripts/bi-weekly-ups-battery-test.sh
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: add ups battery test stages 1-3 (start, monitor, stop)"
```

---

## Task 4: Stages 4–5 — Wait for online, finalise

**Files:**
- Modify: `scripts/bi-weekly-ups-battery-test.sh`

- [ ] **Step 1: Add `stage_wait_online()`**

```bash
# ---------------------------------------------------------------------------
# STAGE 4 – WAIT FOR OL (ONLINE / CHARGING) STATUS
# ---------------------------------------------------------------------------

stage_wait_online() {
    log "INFO" "--------------------------------------------------------"
    log "INFO" "Stage 4 — Waiting for UPS to return to Online (OL) status"
    log "INFO" "--------------------------------------------------------"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Skipping OL wait loop."
        return 0
    fi

    local waited=0
    local status charge

    while (( waited < ONLINE_WAIT_SECS )); do
        status=$(get_var "ups.status")
        charge=$(get_var "battery.charge")
        log "INFO" "ups.status=${status}  battery.charge=${charge}%  waited=${waited}s"

        if echo "${status}" | grep -qw "OL" && ! echo "${status}" | grep -qw "OB"; then
            log "INFO" "UPS is back Online (OL). Charging resumed."
            return 0
        fi

        sleep 15
        waited=$(( waited + 15 ))
    done

    log "WARN" "UPS did not return to OL within ${ONLINE_WAIT_SECS}s."
    log "WARN" "Current status: $(get_var ups.status). Please check UPS manually."
    return 1
}
```

- [ ] **Step 2: Add `stage_finalise()`**

```bash
# ---------------------------------------------------------------------------
# STAGE 5 – FINALISE
# ---------------------------------------------------------------------------

stage_finalise() {
    log "INFO" "--------------------------------------------------------"
    log "INFO" "Stage 5 — Finalising"
    log "INFO" "--------------------------------------------------------"

    local final_charge final_status
    final_charge=$(get_var "battery.charge")
    final_status=$(get_var "ups.status")

    log "INFO" "Final battery.charge : ${final_charge}%"
    log "INFO" "Final ups.status     : ${final_status}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would update state file: ${STATEFILE}"
    else
        date +%s > "${STATEFILE}"
        log "INFO" "State file updated   : ${STATEFILE}"
    fi

    log "INFO" "========================================================"
    log "INFO" " UPS Battery Exercise Simulation — COMPLETE"
    log "INFO" " Log: ${LOGFILE}"
    log "INFO" "========================================================"
}
```

- [ ] **Step 3: Verify shellcheck clean**

```bash
shellcheck scripts/bi-weekly-ups-battery-test.sh
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: add ups battery test stages 4-5 (wait online, finalise)"
```

---

## Task 5: Cleanup trap and main entrypoint

**Files:**
- Modify: `scripts/bi-weekly-ups-battery-test.sh`

- [ ] **Step 1: Add cleanup trap and `main()`**

```bash
# ---------------------------------------------------------------------------
# CLEANUP TRAP — ensure test.battery.stop is always sent on unexpected exit
# ---------------------------------------------------------------------------

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        log "WARN" "Script exiting with code ${exit_code} — sending test.battery.stop as safety measure."
        if send_cmd "test.battery.stop"; then
            log "INFO" "test.battery.stop sent."
        else
            log "WARN" "test.battery.stop also failed. Check UPS manually."
        fi
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ; log "INFO" "*** DRY-RUN mode — no commands will be sent ***" ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done

    preflight
    stage_start_test
    stage_monitor
    stage_stop_test
    stage_wait_online
    stage_finalise
}

main "$@"
```

- [ ] **Step 2: Verify shellcheck clean**

```bash
shellcheck scripts/bi-weekly-ups-battery-test.sh
```

Expected: exit 0, no warnings.

- [ ] **Step 3: Commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: add ups battery test cleanup trap and main entrypoint"
```

---

## Task 6: Deploy to unRAID and verify with dry-run

**Files:**
- Deploy: `/boot/config/plugins/user.scripts/scripts/<name>/script` on tower.local

- [ ] **Step 1: Confirm the correct NUT user exists in `/etc/nut/upsd.users` on tower.local**

```bash
ssh root@192.168.1.40 "grep -A4 '^\[' /etc/nut/upsd.users"
```

Expected: a user entry with `instcmds = all` (or `instcmds = ALL`). If no such user exists, add one:
```ini
[admin]
  password = <choose-a-password>
  actions  = SET
  instcmds = ALL
```
Then restart NUT: `upsdrvctl stop && upsdrvctl start && upsd`

- [ ] **Step 2: Get the UPS name**

```bash
ssh root@192.168.1.40 "upsc -l"
```

Note the output — this is your `UPS_NAME`.

- [ ] **Step 3: Deploy the script with real credentials**

```bash
TOWER_PASS=$(cat "$HOME/ssh-keys/.unraid-password.txt")
sed \
  -e 's|UPS_NAME="<upsc -l>"|UPS_NAME="<output from step 2>"|' \
  -e 's|UPS_HOST="<host>"|UPS_HOST="127.0.0.1"|' \
  -e 's|NUT_USER="<user>"|NUT_USER="admin"|' \
  -e 's|NUT_PASS="<password>"|NUT_PASS="<your-admin-password>"|' \
  scripts/bi-weekly-ups-battery-test.sh \
  | sshpass -p "$TOWER_PASS" ssh root@192.168.1.40 \
    "cat > /boot/config/plugins/user.scripts/scripts/<name>/script && chmod 700 /boot/config/plugins/user.scripts/scripts/<name>/script && echo 'Deployed OK'"
```

- [ ] **Step 4: Run dry-run on tower.local — verify all 5 stages complete**

```bash
TOWER_PASS=$(cat "$HOME/ssh-keys/.unraid-password.txt")
sshpass -p "$TOWER_PASS" ssh root@192.168.1.40 \
  "bash /boot/config/plugins/user.scripts/scripts/<name>/script --dry-run"
```

Expected output (last few lines):
```
[...] [INFO ] Pre-flight passed ✓
[...] [INFO ] [DRY-RUN] Would run: upscmd -u admin <UPS>@127.0.0.1 test.battery.start.deep
[...] [INFO ] [DRY-RUN] Skipping discharge monitoring loop.
[...] [INFO ] [DRY-RUN] Would run: upscmd -u admin <UPS>@127.0.0.1 test.battery.stop
[...] [INFO ] [DRY-RUN] Skipping OL wait loop.
[...] [INFO ] [DRY-RUN] Would update state file: /tmp/ups_battery_sim.last
[...] [INFO ]  UPS Battery Exercise Simulation — COMPLETE
```

Exit code must be 0.

- [ ] **Step 5: Set the schedule in User Scripts UI**

In the unRAID web UI → Settings → User Scripts → find the script → set schedule to:
```
Custom: 0 3 1,15 * *
```

- [ ] **Step 6: Final commit**

```bash
git add scripts/bi-weekly-ups-battery-test.sh
git commit -m "scripts: ups battery test — deployment verified via dry-run on tower.local"
```
