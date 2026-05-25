#!/usr/bin/env bash
# slp_test.sh — ACPI sleep mode (S3/S4/S5) functionality & stability test
#
# Usage:
#   ./slp_test.sh [loops]
#
# Behaviour:
#   - SLP001: Detects which of S3/S4/S5 the system supports.
#   - Runs _LOOPS cycles for each supported mode (default: _sleep_loops=4).
#   - S3/S4: all loops complete within one invocation.
#   - S5 (power-off + RTC wake): one cycle per invocation.
#     Re-run the script after each reboot to continue S5 loops.
#   - SLP004: post-wake health check (ping 127.0.0.1) for S3 and S4.
#   - SLP005: 4-bit state field written atomically around each suspend.
#
# S5 resume across reboots (sticky session):
#   Before rtcwake -m off, slp_s5_pending is written with the current loop#.
#   On the next invocation the file is detected, the loop is marked PASS
#   (system clearly came back), and execution continues with the next cycle.
#
# Changelog:
#   v00.00.01  Initial version

# ---------- Self-elevate to root (FWK025) ----------
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

export _slp_test_version
: "${_slp_test_version:="00.00.01"}"
echo "[INFO] running slp_test.sh v${_slp_test_version}."

# ---------- Locate & source companions ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "${_entry}")" && pwd)"

find_and_source() {
  local _name="$1"
  local search_dirs=( "${_entry_dir}" "/home/${USER}/Downloads" )
  for _dir in "${search_dirs[@]}"; do
    [[ -f "${_dir}/${_name}" ]] && { . "${_dir}/${_name}"; return 0; }
  done
  echo "FATAL: cannot find ${_name} in search directories:" >&2
  printf "  %s\n" "${search_dirs[@]}" >&2
  exit 1
}

find_and_source "config.sh"
find_and_source "function.sh"

# ---------- API version check ----------
: "${_requires_config_api:=00.00.01}"
: "${_requires_function_api:=00.00.02}"
check_api_versions "slp_test.sh" "${_requires_config_api}" "${_requires_function_api}"

# ---------- Parse CLI ----------
parse_common_cli "$@"
set -- "${REM_ARGS[@]}"

# ---------- Cleanup on exit (FWK026) ----------
trap 'fix_log_permissions "${_log_dir:-}" deep' EXIT

# ---------- Tools ----------
ensure_tools rtcwake ping || true
jq_install

# ---------- Parameters from config ----------
_LOOPS="${_target_loop:-${_sleep_loops:-4}}"
_BOOT_WAIT="${_sleep_delay_after_boot:-30}"
_SLEEP_DUR="${_sleep_wake_after_sec:-60}"

# ---------- Log folder (sticky session enables S5 resume across reboots) ----------
log_dir "" 1
log_root="${_session_log_dir}"

# ---------- S5 state file (persists across reboots within the same sticky session) ----------
# Written with the current loop# BEFORE rtcwake -m off.
# Presence on next boot is proof the system returned (loop = PASS).
_S5_PENDING="${_session_state_dir}/slp_s5_pending"

# ---------- S5 counter (separate from S3/S4 because S5 spans reboots) ----------
_S5_DONE_FILE="${_session_state_dir}/slp_s5.count"
_s5_done()   { [[ -f "${_S5_DONE_FILE}" ]] && cat "${_S5_DONE_FILE}" || echo 0; }
_s5_mark_done() { printf '%d\n' "$(( $(_s5_done) + 1 ))" > "${_S5_DONE_FILE}"; }

# ---------- Resolve S5 pending from previous invocation ----------
# This must happen before setup_session so we can tick the counter before
# checking whether there is any work left to do.
_s5_pending_loop=0
if [[ -f "${_S5_PENDING}" ]]; then
  _s5_pending_loop="$(cat "${_S5_PENDING}" 2>/dev/null || echo 0)"
  echo "[INFO] slp_s5_pending found — system returned from S5 (loop ${_s5_pending_loop} PASS)."
  rm -f "${_S5_PENDING}"
  _s5_mark_done   # count this loop as complete
fi

# ---------- S3/S4 counter ----------
counter_init "slp_s3s4" "${_LOOPS}"
_s3s4_remain=$(counter_loops_this_run)

# ---------- Check if everything is already done ----------
_s5_remain=$(( _LOOPS - $(_s5_done) ))
if [[ "${_s3s4_remain}" -le 0 && "${_s5_remain}" -le 0 ]]; then
  echo "[INFO] slp_test already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

setup_session
run_time || true

# ---------- Log files ----------
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_slplog="${log_root}/slp_test_${_run_ts}.log"
_slpsum="${log_root}/slp_summary_${_run_ts}.log"

# ---------- SLP001: detect supported ACPI sleep states ----------
_detect_states() {
  # S3: kernel lists "deep" or "mem" in /sys/power/mem_sleep
  if [[ -f /sys/power/mem_sleep ]] && \
     grep -qE '\bdeep\b|\bmem\b' /sys/power/mem_sleep 2>/dev/null; then
    echo S3
  fi
  # S4: kernel lists "platform" or "shutdown" in /sys/power/disk
  if [[ -f /sys/power/disk ]] && \
     grep -qE '\bplatform\b|\bshutdown\b' /sys/power/disk 2>/dev/null; then
    echo S4
  fi
  # S5: available whenever rtcwake is present
  if command -v rtcwake >/dev/null 2>&1; then
    echo S5
  fi
}

mapfile -t _MODES < <(_detect_states)

# ---------- SLP005: 4-bit sleep-state field (FWK014) ----------
# bit3=in-testing, bits[2:0]: S3=3(011) S4=4(100) S5=5(101)
_STATE_FILE="${log_root}/slp_state.txt"
_state_set()   { local b; case "$1" in S3)b=3;;S4)b=4;;S5)b=5;;*)b=0;;esac
                 printf '%d\n' "$(( (${2:-0}<<3)|b ))" > "${_STATE_FILE}"; }
_state_clear() { rm -f "${_STATE_FILE}"; }

# ---------- SLP004: post-wake health check (S3/S4) ----------
_verify_wake() { ping -c1 -W3 127.0.0.1 >/dev/null 2>&1; }

# ---------- Run one S3 or S4 cycle ----------
_run_s3s4_cycle() {
  local mode="$1" n="$2" total="$3"
  local rtc_mode rc=0 result
  [[ "$mode" == S3 ]] && rtc_mode=mem || rtc_mode=disk

  local f; f="${log_root}/slp_${mode}_${n}_of_${total}_$(now_ts).log"
  {
    printf '[%s] [INFO] === %s cycle %d/%d ===\n' "$(date '+%F %T')" "$mode" "$n" "$total"
    printf '[%s] [INFO] Waiting %ds before entering %s...\n' "$(date '+%F %T')" "$_BOOT_WAIT" "$mode"
  } | tee -a "${_slplog}" > "${f}"

  sleep "${_BOOT_WAIT}"
  _state_set "$mode" 1

  printf '[%s] [INFO] rtcwake -m %s -s %d\n' \
    "$(date '+%F %T')" "$rtc_mode" "$_SLEEP_DUR" | tee -a "${_slplog}" >> "${f}"
  rtcwake -m "$rtc_mode" -s "$_SLEEP_DUR" >> "${f}" 2>&1 && rc=0 || rc=$?

  _state_set "$mode" 0

  if [[ $rc -eq 0 ]] && _verify_wake; then result=PASS; else result=FAIL; fi

  printf '[%s] [INFO] %s %d/%d → %s (rc=%d)\n' \
    "$(date '+%F %T')" "$mode" "$n" "$total" "$result" "$rc" \
    | tee -a "${_slplog}" >> "${f}"
  printf '%d | %-4s | %s\n' "$n" "$mode" "$result" >> "${_slpsum}"

  [[ "$result" == PASS ]]
}

# ---------- Run one S5 cycle ----------
_run_s5_cycle() {
  local n="$1" total="$2" rc=0
  local f; f="${log_root}/slp_S5_${n}_of_${total}_$(now_ts).log"

  {
    printf '[%s] [INFO] === S5 cycle %d/%d ===\n' "$(date '+%F %T')" "$n" "$total"
    printf '[%s] [INFO] Waiting %ds before power-off...\n' "$(date '+%F %T')" "$_BOOT_WAIT"
  } | tee -a "${_slplog}" > "${f}"

  sleep "${_BOOT_WAIT}"
  _state_set S5 1

  # Write pending BEFORE issuing power-off — on next boot this file = PASS proof.
  printf '%d\n' "$n" > "${_S5_PENDING}"

  printf '[%s] [INFO] rtcwake -m off -s %d (system will power off)\n' \
    "$(date '+%F %T')" "$_SLEEP_DUR" | tee -a "${_slplog}" >> "${f}"

  rtcwake -m off -s "$_SLEEP_DUR" >> "${f}" 2>&1 && rc=0 || rc=$?

  # Only reachable if rtcwake failed to power off the system.
  _state_set S5 0
  rm -f "${_S5_PENDING}"
  printf '[%s] [WARN] S5 rtcwake returned without powering off (rc=%d) — FAIL.\n' \
    "$(date '+%F %T')" "$rc" | tee -a "${_slplog}" >> "${f}"
  printf '%d | S5   | FAIL\n' "$n" >> "${_slpsum}"

  return 1   # FAIL — power-off did not happen
}

# ---------- Main log header ----------
{
  printf '==== slp_test v%s ====\n' "${_slp_test_version}"
  printf 'Host     : %s\n' "$(hostname)"
  printf 'Kernel   : %s\n' "$(uname -r)"
  printf 'Session  : %s\n' "${_session_id:-unknown}"
  printf 'Date     : %s\n' "$(date '+%F %T')"
  printf 'Supported: %s\n' "${_MODES[*]:-none}"
  printf 'Loops    : %d  BootWait: %ds  SleepDur: %ds\n' "$_LOOPS" "$_BOOT_WAIT" "$_SLEEP_DUR"
  printf 'S3/S4 remaining: %d  S5 remaining: %d\n' "${_s3s4_remain}" "${_s5_remain}"
  printf '\n'
} | tee "${_slplog}"

if [[ ${#_MODES[@]} -eq 0 ]]; then
  printf '[%s] [FATAL] No S3/S4/S5 support detected — cannot run.\n' \
    "$(date '+%F %T')" | tee -a "${_slplog}"
  exit 1
fi

# ---------- Summary header ----------
: > "${_slpsum}"
printf '%-4s | %-4s | %s\n' "Loop" "Mode" "Result" >> "${_slpsum}"

# ---------- Log previously resolved S5 (from _s5_pending_loop at top) ----------
if (( _s5_pending_loop > 0 )); then
  printf '%d | S5   | PASS\n' "${_s5_pending_loop}" >> "${_slpsum}"
  printf '[%s] [INFO] S5 loop %d/%d PASS (system returned from power-off).\n' \
    "$(date '+%F %T')" "${_s5_pending_loop}" "${_LOOPS}" | tee -a "${_slplog}"
fi

# ---------- S3 / S4 loops ----------
_FAIL=0
if (( _s3s4_remain > 0 )); then
  _done_so_far=$(( _LOOPS - _s3s4_remain ))

  for (( i=1; i<=_s3s4_remain; i++ )); do
    _n_abs=$(( _done_so_far + i ))
    test_progress_set "slp_test" "${_n_abs}" "${_LOOPS}"
    printf '[%s] [INFO] S3/S4 round %d/%d\n' "$(date '+%F %T')" "${_n_abs}" "${_LOOPS}" \
      | tee -a "${_slplog}"

    if printf '%s\n' "${_MODES[@]}" | grep -q '^S3$'; then
      _run_s3s4_cycle S3 "${_n_abs}" "${_LOOPS}" || _FAIL=1
    fi
    if printf '%s\n' "${_MODES[@]}" | grep -q '^S4$'; then
      _run_s3s4_cycle S4 "${_n_abs}" "${_LOOPS}" || _FAIL=1
    fi

    counter_tick "slp_s3s4" || true
  done
fi

# ---------- S5: one cycle per invocation ----------
_s5_remain=$(( _LOOPS - $(_s5_done) ))   # recalculate after S3/S4 ran
if (( _s5_remain > 0 )) && printf '%s\n' "${_MODES[@]}" | grep -q '^S5$'; then
  _s5_n=$(( _LOOPS - _s5_remain + 1 ))
  printf '[%s] [INFO] S5 round %d/%d\n' "$(date '+%F %T')" "${_s5_n}" "${_LOOPS}" \
    | tee -a "${_slplog}"
  test_progress_set "slp_test" "${_s5_n}" "${_LOOPS}"

  if ! _run_s5_cycle "${_s5_n}" "${_LOOPS}"; then
    _FAIL=1
    _s5_mark_done   # rtcwake failed — count it as done (failed) and continue
  else
    # rtcwake succeeded → system is powering off; script will not reach here.
    # The line below is unreachable but kept for clarity.
    sleep infinity
  fi
fi

# ---------- Final result ----------
_state_clear

_s5_now_done=$(_s5_done)
if (( _s5_now_done < _LOOPS )) && printf '%s\n' "${_MODES[@]}" | grep -q '^S5$'; then
  printf '[%s] [INFO] S5 %d/%d done. Run script again after next reboot.\n' \
    "$(date '+%F %T')" "${_s5_now_done}" "${_LOOPS}" | tee -a "${_slplog}"
  exit 0   # Not yet done — no result.json until all loops complete
fi

# ---------- Emit result.json (all loops complete) ----------
_resultjson="${log_root}/slp_test_${_run_ts}.result.json"

_pass_count=0; _fail_count=0
while IFS='|' read -r _ _md _vd; do
  _vd="${_vd// /}"
  case "$_vd" in PASS) (( _pass_count++ )) ;; FAIL) (( _fail_count++ )) ;; esac
done < <(tail -n +2 "${_slpsum}")
_total_count=$(( _pass_count + _fail_count ))

if   (( _fail_count  > 0 )); then _verdict="FAIL"
elif (( _pass_count == _total_count && _total_count > 0 )); then _verdict="PASS"
else _verdict="UNKNOWN"
fi

_summary_json=$(jq -n \
  --argjson total  "${_total_count}" \
  --argjson passed "${_pass_count}" \
  --argjson failed "${_fail_count}" \
  '{ total: $total, passed: $passed, failed: $failed }')

_details_json=$(jq -n \
  --arg  modes     "${_MODES[*]}" \
  --argjson loops  "${_LOOPS}" \
  --argjson bwait  "${_BOOT_WAIT}" \
  --argjson sdur   "${_SLEEP_DUR}" \
  '{ modes: ($modes | split(" ")), loops: $loops,
     boot_wait_sec: $bwait, sleep_dur_sec: $sdur }')

emit_result_json \
  --test-name    slp_test \
  --test-version "${_slp_test_version}" \
  --verdict      "${_verdict}" \
  --summary-json "${_summary_json}" \
  --details-json "${_details_json}" \
  --output       "${_resultjson}"

echo "[INFO] Result JSON : ${_resultjson}"

# ---------- Done ----------
elp_time | tee -a "${_slplog}"
echo "[INFO] Main log : ${_slplog}"
echo "[INFO] Summary  : ${_slpsum}"

test_progress_clear "slp_test completed. Safe to power off."
cd "${_tool_path}" || true
