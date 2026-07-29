#!/usr/bin/env bash
# bmc_sensor_test.sh — long-duration out-of-band BMC sensor soak test
#
# Polls `ipmitool sensor list` over the network at a fixed interval,
# records every reading, and flags anything that changes:
#   - sensor status transitions (ok -> nc/cr/nr/ns, discrete state flips)
#   - sensors appearing in / disappearing from the listing
#   - SEL (System Event Log) entry-count changes
#   - IPMI communication failures (retried; the run never aborts mid-way)
#
# Verdict logic is baseline-relative: the first successful poll defines
# the expected sensor set and per-sensor status. Sensors that are already
# non-ok at start (e.g. unpopulated fan headers reporting `nr`) do not
# fail the run; only *changes* during the run do.
#
# Unlike the DUT-side tests (disk_test.sh, net_test.sh, ...), this script
# runs on the control node / any workstation that can reach the BMC. It
# is deliberately standalone: no config.sh / function.sh dependency.
#
# Canonical artefacts (FWK028), written to <outdir>/bmc_sensor_<session>/:
#   samples.csv                          every reading of every sensor
#   bmc_sensor_<session>.result.json     summary + verdict (LOG015)
#   events.log                           timestamped anomaly/event log
#   raw.log                              verbatim ipmitool output per cycle
#   sel_new.log                          SEL entries that appeared mid-run
#   ipmitool_stderr.log                  stderr from all ipmitool calls
#
# Usage:
#   export IPMI_PASSWORD='...'           # preferred over -P (hidden from ps)
#   ./bmc_sensor_test.sh -H <bmc-ip> -U <user> [-i 60] [-d 60] [-n 0] [-o ./logs]
#
# Options:
#   -H host      BMC IP / hostname (required)
#   -U user      IPMI user (required)
#   -P pass      IPMI password (visible in `ps`; prefer IPMI_PASSWORD env)
#   -i seconds   poll interval                                 (default 60)
#   -d hours     stop after this many hours; 0 = until stopped (default 0)
#   -n cycles    stop after this many cycles; 0 = unlimited    (default 0)
#   -o dir       base output directory                         (default ./logs)
#   -h           this help
#
# Tunables (environment):
#   IPMI_IFACE=lanplus   IPMI_RETRIES=3   IPMI_RETRY_DELAY=5   IPMI_TIMEOUT=60
#   MAX_COMM_FAIL_PCT=1  CONSEC_ALERT=10  HEARTBEAT_CYCLES=60
#   IPMITOOL_BIN=ipmitool                 (override for testing with a mock)
#
# PASS requires: >=1 successful poll, zero status transitions, zero
# sensor-set changes, zero SEL changes, comm-failure rate <= MAX_COMM_FAIL_PCT.
#
# Exit codes: 0 PASS, 1 FAIL, 2 usage / pre-flight error
#
# Changelog:
#   v00.00.01  Initial version

# No `set -e`: a transient failure must never abort a multi-day run.
# All error paths are handled explicitly.
set -u -o pipefail

export _bmc_sensor_test_version
: "${_bmc_sensor_test_version:="00.00.01"}"
VERSION="${_bmc_sensor_test_version}"

# ---------- Defaults & tunables ----------
BMC_HOST=""
BMC_USER=""
INTERVAL=60
DURATION_HOURS=0
MAX_CYCLES=0
OUT_BASE="./logs"

: "${IPMI_IFACE:=lanplus}"
: "${IPMI_RETRIES:=3}"
: "${IPMI_RETRY_DELAY:=5}"
: "${IPMI_TIMEOUT:=60}"          # hard cap per ipmitool invocation (seconds)
: "${MAX_COMM_FAIL_PCT:=1}"      # PASS threshold for failed-cycle percentage
: "${CONSEC_ALERT:=10}"          # CRITICAL event after this many failures in a row
: "${HEARTBEAT_CYCLES:=60}"      # INFO heartbeat every N cycles
: "${IPMITOOL_BIN:=ipmitool}"

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------- Argument parsing ----------
while getopts ":H:U:P:i:d:n:o:h" opt; do
  case "${opt}" in
    H) BMC_HOST="${OPTARG}" ;;
    U) BMC_USER="${OPTARG}" ;;
    P) export IPMI_PASSWORD="${OPTARG}"
       echo "[WARN] -P puts the password in the process list; prefer the IPMI_PASSWORD environment variable." >&2 ;;
    i) INTERVAL="${OPTARG}" ;;
    d) DURATION_HOURS="${OPTARG}" ;;
    n) MAX_CYCLES="${OPTARG}" ;;
    o) OUT_BASE="${OPTARG}" ;;
    h) usage; exit 0 ;;
    :) echo "[FATAL] option -${OPTARG} requires an argument" >&2; exit 2 ;;
    *) echo "[FATAL] unknown option -${OPTARG}" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "${BMC_HOST}" || -z "${BMC_USER}" ]] && { echo "[FATAL] -H and -U are required" >&2; usage >&2; exit 2; }
[[ -z "${IPMI_PASSWORD:-}" ]] && { echo "[FATAL] no password: export IPMI_PASSWORD or pass -P" >&2; exit 2; }
[[ "${INTERVAL}" =~ ^[0-9]+$ && "${INTERVAL}" -ge 1 ]] || { echo "[FATAL] -i must be a positive integer (seconds)" >&2; exit 2; }
[[ "${DURATION_HOURS}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "[FATAL] -d must be a non-negative number (hours)" >&2; exit 2; }
[[ "${MAX_CYCLES}" =~ ^[0-9]+$ ]] || { echo "[FATAL] -n must be a non-negative integer" >&2; exit 2; }
command -v "${IPMITOOL_BIN}" >/dev/null 2>&1 || { echo "[FATAL] ${IPMITOOL_BIN} not found (apt install ipmitool)" >&2; exit 2; }
export IPMI_PASSWORD   # consumed by ipmitool -E; never on the command line

DURATION_S="$(awk -v h="${DURATION_HOURS}" 'BEGIN{ printf "%d", h*3600 }')"

# ---------- Session artefacts ----------
SESSION_TS="$(date +%Y%m%dT%H%M%S)"
SESSION_DIR="${OUT_BASE}/bmc_sensor_${SESSION_TS}"
mkdir -p "${SESSION_DIR}" || { echo "[FATAL] cannot create ${SESSION_DIR}" >&2; exit 2; }

SAMPLES_CSV="${SESSION_DIR}/samples.csv"
EVENTS_LOG="${SESSION_DIR}/events.log"
RAW_LOG="${SESSION_DIR}/raw.log"
SEL_NEW_LOG="${SESSION_DIR}/sel_new.log"
ERR_LOG="${SESSION_DIR}/ipmitool_stderr.log"
RESULT_JSON="${SESSION_DIR}/bmc_sensor_${SESSION_TS}.result.json"
ATTEMPTS_FILE="${SESSION_DIR}/.last_attempts"

echo "timestamp,cycle,sensor,value,unit,status" > "${SAMPLES_CSV}"

# ---------- State ----------
CYCLE=0
OK_CYCLES=0
FAIL_CYCLES=0
CONSEC_FAILS=0
MAX_CONSEC_FAILS=0
TRANSITION_EVENTS=0
SET_EVENTS=0
SEL_EVENTS=0
RETRIED_READS=0
PARSED_COUNT=0
BASELINE_DONE=0
BASELINE_COUNT=0
BASELINE_NONOK_JSON=""
SEL_CHECKED=false
SEL_START=""
SEL_LAST=""
STOP=0
FINALIZED=0
EXIT_CODE=1
SLEEP_PID=""
START_EPOCH="$(date +%s)"
START_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
BMC_FIRMWARE="unknown"          # BMC firmware revision, read once at startup

declare -A prev_state=()                  # sensor -> comparable state string
declare -A curr_state=() curr_value=() curr_unit=() curr_status=()
CURR_KEYS=()                              # sensor names in SDR order, this cycle

# ---------- Helpers ----------
log_event() {  # $1=level $2=message
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" | tee -a "${EVENTS_LOG}"
}

trim() {  # trim leading/trailing whitespace of the named variable, in place
  local -n _v="$1"
  _v="${_v#"${_v%%[![:space:]]*}"}"
  _v="${_v%"${_v##*[![:space:]]}"}"
}

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "${s}"; }

# Run one ipmitool command with timeout + retries. Output on stdout,
# stderr collected in ERR_LOG, attempt count left in ATTEMPTS_FILE
# (this function runs in a $() subshell, so it cannot set globals).
ipmi_call() {
  local attempt rc=1 out
  for (( attempt = 1; attempt <= IPMI_RETRIES; attempt++ )); do
    out="$(timeout "${IPMI_TIMEOUT}" "${IPMITOOL_BIN}" -I "${IPMI_IFACE}" \
           -H "${BMC_HOST}" -U "${BMC_USER}" -E "$@" 2>>"${ERR_LOG}")"
    rc=$?
    if (( rc == 0 )) && [[ -n "${out}" ]]; then
      echo "${attempt}" > "${ATTEMPTS_FILE}"
      printf '%s\n' "${out}"
      return 0
    fi
    (( attempt < IPMI_RETRIES )) && sleep "${IPMI_RETRY_DELAY}"
  done
  echo "${IPMI_RETRIES}" > "${ATTEMPTS_FILE}"
  return "${rc}"
}

# Parse one `sensor list` sample: append CSV rows, compare against the
# previous cycle, emit transition / set-change events. $1=output $2=timestamp
process_sample() {
  local output="$1" ts="$2"
  local f1 f2 f3 f4 _rest name value unit status state csv_buf="" malformed=0
  CURR_KEYS=(); curr_state=(); curr_value=(); curr_unit=(); curr_status=()
  PARSED_COUNT=0

  while IFS='|' read -r f1 f2 f3 f4 _rest; do
    name="${f1-}"; value="${f2-}"; unit="${f3-}"; status="${f4-}"
    trim name; trim value; trim unit; trim status
    [[ -z "${name}" && -z "${status}" ]] && continue            # blank line
    if [[ -z "${name}" || -z "${status}" ]]; then
      (( malformed += 1 )); continue
    fi
    name="${name//,/_}"                                          # keep CSV one-comma-per-field
    # Discrete sensors encode their state in value+status; threshold
    # sensors fluctuate in value by nature, so only status is compared.
    if [[ "${unit}" == "discrete" ]]; then
      state="${value}/${status}"
    else
      state="${status}"
    fi
    CURR_KEYS+=("${name}")
    curr_state["${name}"]="${state}"
    curr_value["${name}"]="${value}"
    curr_unit["${name}"]="${unit}"
    curr_status["${name}"]="${status}"
    csv_buf+="${ts},${CYCLE},${name},${value},${unit},${status}"$'\n'
    (( PARSED_COUNT += 1 ))
  done <<< "${output}"

  (( PARSED_COUNT == 0 )) && return 0
  printf '%s' "${csv_buf}" >> "${SAMPLES_CSV}"
  (( malformed > 0 )) && log_event WARN "cycle ${CYCLE}: ${malformed} unparsable line(s) in sensor list"

  if (( BASELINE_DONE == 0 )); then
    local nonok=() parts="" e
    for name in "${CURR_KEYS[@]}"; do
      if [[ "${curr_unit[${name}]}" != "discrete" && "${curr_status[${name}]}" != "ok" ]]; then
        nonok+=("${name}=${curr_status[${name}]}")
      fi
    done
    for e in "${nonok[@]}"; do parts+="${parts:+, }$(json_str "${e}")"; done
    BASELINE_NONOK_JSON="${parts}"
    BASELINE_COUNT="${PARSED_COUNT}"
    BASELINE_DONE=1
    log_event INFO "baseline: ${BASELINE_COUNT} sensors; non-ok at start: ${nonok[*]:-none}"
  else
    for name in "${CURR_KEYS[@]}"; do
      if [[ -z "${prev_state[${name}]+x}" ]]; then
        (( SET_EVENTS += 1 ))
        log_event WARN "cycle ${CYCLE}: sensor appeared: ${name} (state=${curr_state[${name}]})"
      elif [[ "${prev_state[${name}]}" != "${curr_state[${name}]}" ]]; then
        (( TRANSITION_EVENTS += 1 ))
        log_event WARN "cycle ${CYCLE}: status change: ${name}: ${prev_state[${name}]} -> ${curr_state[${name}]} (value=${curr_value[${name}]})"
      fi
    done
    for name in "${!prev_state[@]}"; do
      if [[ -z "${curr_state[${name}]+x}" ]]; then
        (( SET_EVENTS += 1 ))
        log_event WARN "cycle ${CYCLE}: sensor disappeared: ${name} (was ${prev_state[${name}]})"
      fi
    done
  fi

  prev_state=()
  for name in "${!curr_state[@]}"; do prev_state["${name}"]="${curr_state[${name}]}"; done
}

# Watch the SEL entry count; new entries during a soak run are a failure
# signal even when every sensor still reads ok.
check_sel() {
  local out entries
  out="$(ipmi_call sel info)" || { log_event WARN "cycle ${CYCLE}: SEL info read failed"; return 0; }
  entries="$(printf '%s\n' "${out}" | awk -F':' '/^Entries/ { gsub(/[^0-9]/, "", $2); print $2; exit }')"
  [[ -z "${entries}" ]] && { log_event WARN "cycle ${CYCLE}: cannot parse SEL entry count"; return 0; }
  if [[ -z "${SEL_START}" ]]; then
    SEL_START="${entries}"; SEL_LAST="${entries}"; SEL_CHECKED=true
    log_event INFO "SEL baseline: ${entries} entries"
    return 0
  fi
  if [[ "${entries}" != "${SEL_LAST}" ]]; then
    (( SEL_EVENTS += 1 ))
    log_event WARN "cycle ${CYCLE}: SEL entry count changed ${SEL_LAST} -> ${entries}"
    if (( entries > SEL_LAST )); then
      {
        printf '=== cycle %d %s: new SEL entries ===\n' "${CYCLE}" "$(date +%Y-%m-%dT%H:%M:%S%z)"
        ipmi_call sel list | tail -n "$(( entries - SEL_LAST ))"
      } >> "${SEL_NEW_LOG}" || true
    fi
    SEL_LAST="${entries}"
  fi
}

handle_fail() {  # $1 = reason
  (( FAIL_CYCLES += 1 ))
  (( CONSEC_FAILS += 1 ))
  (( CONSEC_FAILS > MAX_CONSEC_FAILS )) && MAX_CONSEC_FAILS="${CONSEC_FAILS}"
  log_event ERROR "cycle ${CYCLE}: $1 (consecutive failed cycles: ${CONSEC_FAILS})"
  (( CONSEC_FAILS == CONSEC_ALERT )) && log_event CRITICAL "BMC unreachable for ${CONSEC_ALERT} consecutive cycles — still retrying"
}

# Per-sensor min/max/avg/last computed from the canonical CSV in one awk
# pass; emitted as the "sensors" JSON object (POSIX awk, no gawk-isms).
emit_sensor_stats() {
  awk -F',' '
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    NR == 1 { next }
    {
      name = $3; val = $4; unit = $5; status = $6
      if (!(name in seen)) { seen[name] = 1; order[++nsensors] = name }
      unitOf[name] = unit; lastVal[name] = val; lastSt[name] = status; cnt[name]++
      if (val ~ /^-?[0-9]+(\.[0-9]+)?$/) {
        v = val + 0; ncnt[name]++; sum[name] += v
        if (ncnt[name] == 1 || v < minv[name]) minv[name] = v
        if (ncnt[name] == 1 || v > maxv[name]) maxv[name] = v
      }
    }
    END {
      printf "{"
      for (i = 1; i <= nsensors; i++) {
        name = order[i]
        printf "%s\n    \"%s\": {\"unit\": \"%s\", \"samples\": %d, \"last\": \"%s\", \"last_status\": \"%s\"", \
          (i > 1 ? "," : ""), jesc(name), jesc(unitOf[name]), cnt[name], jesc(lastVal[name]), jesc(lastSt[name])
        if (ncnt[name] > 0)
          printf ", \"min\": %.3f, \"max\": %.3f, \"avg\": %.3f", minv[name], maxv[name], sum[name] / ncnt[name]
        printf "}"
      }
      printf "\n  }"
    }
  ' "${SAMPLES_CSV}"
}

write_result() {  # $1 = running|final, $2 = verdict
  local running="$1" verdict="$2"
  local tmp="${RESULT_JSON}.tmp" now_iso fail_pct
  now_iso="$(date +%Y-%m-%dT%H:%M:%S%z)"
  fail_pct="$(awk -v f="${FAIL_CYCLES}" -v t="${CYCLE}" 'BEGIN{ if (t > 0) printf "%.2f", f*100/t; else printf "0.00" }')"
  {
    printf '{\n'
    printf '  "test": "bmc_sensor_soak",\n'
    printf '  "script_version": "%s",\n' "${VERSION}"
    printf '  "session": "%s",\n' "${SESSION_TS}"
    printf '  "bmc_host": %s,\n' "$(json_str "${BMC_HOST}")"
    printf '  "bmc_firmware": %s,\n' "$(json_str "${BMC_FIRMWARE}")"
    printf '  "ipmi_interface": %s,\n' "$(json_str "${IPMI_IFACE}")"
    printf '  "started": "%s",\n' "${START_ISO}"
    printf '  "updated": "%s",\n' "${now_iso}"
    printf '  "interval_s": %d,\n' "${INTERVAL}"
    printf '  "planned_hours": %s,\n' "${DURATION_HOURS}"
    printf '  "planned_cycles": %d,\n' "${MAX_CYCLES}"
    printf '  "running": %s,\n' "$([[ "${running}" == "running" ]] && echo true || echo false)"
    printf '  "cycles": {"total": %d, "ok": %d, "comm_fail": %d, "comm_fail_pct": %s, "max_consecutive_fail": %d},\n' \
      "${CYCLE}" "${OK_CYCLES}" "${FAIL_CYCLES}" "${fail_pct}" "${MAX_CONSEC_FAILS}"
    printf '  "baseline": {"sensor_count": %d, "non_ok_at_start": [%s]},\n' \
      "${BASELINE_COUNT}" "${BASELINE_NONOK_JSON}"
    printf '  "events": {"status_transitions": %d, "sensor_set_changes": %d, "sel_changes": %d, "retried_reads": %d},\n' \
      "${TRANSITION_EVENTS}" "${SET_EVENTS}" "${SEL_EVENTS}" "${RETRIED_READS}"
    printf '  "sel": {"checked": %s, "entries_start": %s, "entries_last": %s},\n' \
      "${SEL_CHECKED}" "${SEL_START:-null}" "${SEL_LAST:-null}"
    if [[ "${running}" == "final" ]]; then
      printf '  "verdict": "%s",\n' "${verdict}"
      printf '  "sensors": '
      emit_sensor_stats
      printf '\n'
    else
      printf '  "verdict": "RUNNING"\n'
    fi
    printf '}\n'
  } > "${tmp}" && mv -f "${tmp}" "${RESULT_JSON}"
}

compute_verdict() {
  if (( OK_CYCLES == 0 )); then echo "FAIL"; return; fi
  if (( TRANSITION_EVENTS > 0 || SET_EVENTS > 0 || SEL_EVENTS > 0 )); then echo "FAIL"; return; fi
  local comm_ok
  comm_ok="$(awk -v f="${FAIL_CYCLES}" -v t="${CYCLE}" -v m="${MAX_COMM_FAIL_PCT}" \
             'BEGIN{ print (t > 0 && f*100/t <= m) ? 1 : 0 }')"
  if [[ "${comm_ok}" == "1" ]]; then echo "PASS"; else echo "FAIL"; fi
}

finalize() {
  (( FINALIZED )) && return
  FINALIZED=1
  local verdict
  verdict="$(compute_verdict)"
  write_result final "${verdict}"
  log_event INFO "run finished: verdict=${verdict} cycles=${CYCLE} ok=${OK_CYCLES} comm_fail=${FAIL_CYCLES} transitions=${TRANSITION_EVENTS} set_changes=${SET_EVENTS} sel_changes=${SEL_EVENTS}"
  log_event INFO "result: ${RESULT_JSON}"
  [[ "${verdict}" == "PASS" ]] && EXIT_CODE=0 || EXIT_CODE=1
}

on_signal() {
  STOP=1
  [[ -n "${SLEEP_PID}" ]] && kill "${SLEEP_PID}" 2>/dev/null
}

interruptible_sleep() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "${SLEEP_PID}" 2>/dev/null || true
  SLEEP_PID=""
}

# ---------- Main ----------
trap on_signal INT TERM
trap finalize EXIT

log_event INFO "bmc_sensor_test.sh v${VERSION} starting"
log_event INFO "target: ${BMC_USER}@${BMC_HOST} via ${IPMI_IFACE}; interval ${INTERVAL}s"
if (( DURATION_S > 0 )); then
  log_event INFO "planned duration: ${DURATION_HOURS}h (until $(date -d "@$(( START_EPOCH + DURATION_S ))" '+%Y-%m-%d %H:%M:%S'))"
else
  log_event INFO "planned duration: until stopped (SIGINT/SIGTERM)$( (( MAX_CYCLES > 0 )) && echo " or ${MAX_CYCLES} cycles" )"
fi
log_event INFO "artefacts: ${SESSION_DIR}/"

# Record the BMC firmware version once, so the result.json says which
# firmware this soak ran against (traceability).
BMC_FIRMWARE="$(ipmi_call mc info 2>/dev/null | awk -F: '/[Ff]irmware Revision/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
: "${BMC_FIRMWARE:=unknown}"
log_event INFO "BMC firmware revision: ${BMC_FIRMWARE}"

while :; do
  (( CYCLE += 1 ))
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"

  if raw="$(ipmi_call sensor list)"; then
    attempts="$(cat "${ATTEMPTS_FILE}" 2>/dev/null || echo 1)"
    if (( attempts > 1 )); then
      (( RETRIED_READS += 1 ))
      log_event WARN "cycle ${CYCLE}: sensor read needed ${attempts} attempts"
    fi
    {
      printf '=== cycle %d %s ===\n' "${CYCLE}" "${ts}"
      printf '%s\n' "${raw}"
    } >> "${RAW_LOG}"
    process_sample "${raw}" "${ts}"
    if (( PARSED_COUNT == 0 )); then
      handle_fail "sensor list returned no parsable rows"
    else
      (( OK_CYCLES += 1 ))
      if (( CONSEC_FAILS > 0 )); then
        log_event INFO "cycle ${CYCLE}: recovered after ${CONSEC_FAILS} failed cycle(s)"
        CONSEC_FAILS=0
      fi
      check_sel
    fi
  else
    handle_fail "ipmitool failed after ${IPMI_RETRIES} attempts"
  fi

  # An unattended weekend run must not start against a dead target.
  if (( CYCLE == 1 && OK_CYCLES == 0 )); then
    log_event CRITICAL "first poll failed — refusing to start unattended run (check host/user/password/network)"
    finalize
    exit 2
  fi

  (( CYCLE % HEARTBEAT_CYCLES == 0 )) && \
    log_event INFO "heartbeat: cycle ${CYCLE}, ok ${OK_CYCLES}, comm_fail ${FAIL_CYCLES}, transitions ${TRANSITION_EVENTS}, set_changes ${SET_EVENTS}, sel_changes ${SEL_EVENTS}"

  write_result running RUNNING

  (( STOP )) && { log_event INFO "stop signal received"; break; }
  (( MAX_CYCLES > 0 && CYCLE >= MAX_CYCLES )) && { log_event INFO "reached planned cycle count (${MAX_CYCLES})"; break; }
  if (( DURATION_S > 0 )) && (( $(date +%s) - START_EPOCH >= DURATION_S )); then
    log_event INFO "reached planned duration (${DURATION_HOURS}h)"
    break
  fi

  # Drift-corrected wait: cycle N starts at START + N*INTERVAL even if a
  # poll ran long (retries); skipped instead of bunched when we overrun.
  next_epoch=$(( START_EPOCH + CYCLE * INTERVAL ))
  wait_s=$(( next_epoch - $(date +%s) ))
  (( wait_s > 0 )) && interruptible_sleep "${wait_s}"
  (( STOP )) && { log_event INFO "stop signal received"; break; }
done

finalize
exit "${EXIT_CODE}"
