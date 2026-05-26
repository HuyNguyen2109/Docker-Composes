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
#  Place the script in /boot/config/plugins/nut/ so it survives reboots.
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
UPS_HOST="<host>"            # NUT server host
NUT_USER="<user>"                # upsd user — MUST have instcmds = ALL in upsd.users
                                  # NOTE: upsmon-only users (e.g. monuser/slaveuser) lack
                                  #       instcmds permission and will fail at Stage 1
NUT_PASS="<password>"               # upsd password  (chmod 700 this file!)

STOP_PCT=30                     # Stop the deep test when charge reaches this %
POLL_INTERVAL=60                # Seconds between each battery.charge poll
TIMEOUT_SECS=7200               # Hard timeout (2 h) — stops test if STOP_PCT never reached
ONLINE_WAIT_SECS=300            # Max seconds to wait for OL status after stopping test

SAFETY_THRESHOLD=80             # Abort if current charge is already below this %

LOGFILE="/var/log/ups_battery_sim.log"
STATEFILE="/tmp/ups_battery_sim.last"   # Stores epoch of last successful run

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
    # Usage: get_var <ups_variable>
    upsc "${UPS}" "$1" 2>/dev/null
}

send_cmd() {
    # Usage: send_cmd <instant_command>
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "INFO" "[DRY-RUN] Would run: upscmd -u ${NUT_USER} ${UPS} $1"
        return 0
    fi
    upscmd -u "${NUT_USER}" -p "${NUT_PASS}" "${UPS}" "$1" 2>/dev/null
}

has_cmd() {
    # Returns 0 if the instant command is listed by the driver
    upscmd -l "${UPS}" 2>/dev/null | grep -q "^$1"
}

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

    # Brief settle — give the UPS a moment to update its status
    sleep 5

    local status charge
    status=$(get_var "ups.status")
    charge=$(get_var "battery.charge")
    log "INFO" "Post-start  ups.status     : ${status}"
    log "INFO" "Post-start  battery.charge : ${charge}%"
}

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

        # Normalise runtime display
        local rt_display="N/A"
        if [[ -n "${runtime}" ]]; then
            rt_display="${runtime}s (~$(( runtime / 60 ))m)"
        fi

        log "INFO" "charge=${charge}%  status=${status}  runtime_left=${rt_display}  elapsed=${elapsed}s"

        # Target reached
        if [[ -n "${charge}" ]] && (( charge <= STOP_PCT )); then
            log "INFO" "Target reached: battery.charge (${charge}%) ≤ STOP_PCT (${STOP_PCT}%)."
            break
        fi

        # Hard timeout safety net
        if (( elapsed >= TIMEOUT_SECS )); then
            log "WARN" "Timeout of ${TIMEOUT_SECS}s reached before charge hit ${STOP_PCT}%."
            log "WARN" "Current charge: ${charge}%. Stopping test now."
            break
        fi

        # UPS unexpectedly went fully offline or flagged FSD — abort
        if echo "${status}" | grep -qw "FSD"; then
            log "ERROR" "UPS flagged Forced Shutdown (FSD) during test! Stopping immediately."
            break
        fi

        sleep "${POLL_INTERVAL}"
        elapsed=$(( elapsed + POLL_INTERVAL ))
    done

    log "INFO" "Monitoring complete. Final charge: $(get_var battery.charge)%"
}

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

        # OL without OB flag = back on mains and (re)charging
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

    # Record successful run timestamp (for bi-weekly gate)
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
