#!/usr/bin/env bash
# net_test.sh — IPv4/IPv6 connectivity + throughput, parallel pair execution
#
# Usage:
#   ./net_test.sh [loops] [--skip <nic>[,<nic>...]] \
#                 [--include-mac <mac>[,<mac>...]] [--exclude-mac <mac>[,<mac>...]]
#
#   --skip / --exclude   Comma-separated or repeated flag.  Named NICs are
#                        excluded from namespace creation and testing.
#                        Example: ./net_test.sh 3 --skip enp3s0,enp4s0
#
#   --include-mac        NET019 whitelist: when given, ONLY NICs whose MAC matches
#                        are tested; all others become SKIPPED.  Comma/space
#                        separated, repeatable; ':' or '-' separators, any case.
#   --exclude-mac        NET019 blacklist: NICs whose MAC matches are never tested
#                        (e.g. the management / SSH-lifeline NIC).  Exclude wins
#                        over include.  Both override _net_include_macs /
#                        _net_exclude_macs from config for this run.
#                        Example: ./net_test.sh 3 --exclude-mac 00-E0-4C-68-00-56
#
# Parallel design:
#   - All pairs start simultaneously (background &)
#   - Each pair runs all its speeds independently
#   - Each pair writes to its own log: net_test_pair<N>_*.log
#   - Main log records pair START/DONE events only
#   - iperf3 server per pair is tracked by PID and killed after that pair finishes
#   - Summary is assembled after all pairs complete (wait)
#
# Changelog:
#   v00.00.18  BUG0037 root cause: _nic_err_snapshot (and __move_back_to_root in
#              function.sh) declared `local ifn=$2 b=...${ifn}...` in ONE local
#              statement — ${ifn} is expanded before ifn is assigned, so under
#              `set -u` it aborted with "ifn: unbound variable", silently killing
#              every pair worker at the NET016 snapshot before iperf3 ever ran.
#              Split the declarations so the referenced var is assigned first.
#   v00.00.17  No silent pair failure: an unhandled error in a backgrounded pair
#              worker (which runs under set -Eeuo pipefail) used to exit the
#              subshell with no trace, so the pair vanished from the summary and
#              rendered as NOT_TESTED — taking that speed's ICMP result with it.
#              Add an ERR trap (_pair_abort) that records an ERROR entry with the
#              failing line+command into result.json and the summary, and harden
#              the optional NET016 counter snapshots so they can never abort the
#              essential throughput test.
#   v00.00.16  NET019 fix: tolerate surrounding/embedded quotes in _net_nic_name_regex
#              and the MAC lists. The `: "${var:='value'}"` config idiom keeps the
#              inner quotes as literal characters, which silently broke matching
#              (pattern became "'^enp'"); values are now quote-stripped defensively
#              and the shipped defaults/examples use the bare form.
#   v00.00.15  NET019: configurable NIC name discovery (_net_nic_name_regex, default
#              '^enp') so USB (enx*) / other NICs can be tested; diagnostic message
#              when filtering leaves <2 NICs (lists pattern, MAC lists, and the
#              actual excluded NICs + reasons).
#   v00.00.14  NET019: MAC-based NIC include/exclude (--include-mac / --exclude-mac
#              and _net_include_macs / _net_exclude_macs); SKIPPED rows now carry
#              the specific exclusion reason. Brings MAC-based exclude to the Bash
#              side (previously PowerShell-only) per FWK036.
#   v00.00.13  Per-loop init/recover (kill leftover iperf3 for this pair's
#              subnet before/after each loop) and per-loop port rotation
#              (5201/5202 .. wrapping after 10 loops) so a stale server/socket
#              from a previous loop can never shadow the current one; pairlog
#              now appends across loops instead of being overwritten; iperf3
#              servers now log to their own *_server.log for diagnostics.
#   v00.00.12  Revert v00.00.11's broad iperf3 pkill (it was the Windows port's
#              counterpart to a change that endangered the management NIC); the
#              readiness probe + per-direction retry from v00.00.10 already cover
#              the stale-server case safely via PID-tracked cleanup.
#   v00.00.11  (reverted) kill leftover iperf3 in the pair's netns before each
#              speed's iperf block and after the bidirectional pass.
#   v00.00.10  NET017 robustness: probe iperf3 server readiness (TCP control
#              port) instead of a blind sleep, and retry a direction up to 3x if
#              it returns no data -- removes spurious UNKNOWN from a server-start
#              race after a link change.
#   v00.00.09  NET018: distinguish PASS/FAIL-FRAG/FAIL/SKIP for jumbo DF-ping
#              (SKIP when the NIC rejects the jumbo MTU outright, instead of a
#              misleading FAIL); jumbo report cell shows SKIP as N/A, not FAIL.
#   v00.00.08  NET008 reason field; NET009 per-speed-tier thresholds; NET015 max
#              link speed; NET016 NIC error-counter deltas; NET017 iperf3 quality
#              metrics + simultaneous full-duplex pass; NET018 jumbo-frame check
#   v00.00.07  Fix ethtool pipeline crash when NIC has no link (grep exits 1 → set -e)
#   v00.00.06  NET009: TCP >= 95% link speed verdict; show all NICs (excluded as SKIPPED)
#   v00.00.05  NET011: --skip / --exclude CLI flag to exclude specific NICs
#   v00.00.04  result.json emission (LOG015); per-pair JSON tmp files
#   v00.00.03  Parallel pair execution; per-pair log; PID-tracked iperf3 cleanup
#   v00.00.02  Odd NIC skip + N/A summary row (skipped_ethArray)
#   v00.00.01  Initial version
# ---------- Self-elevate to root (FWK025) ----------
# This test creates network namespaces and runs iperf3 inside them,
# both requiring root. If invoked as a non-root user, re-execute under
# sudo, preserving environment (-E) and arguments ("$@"). Output
# ownership is restored via fix_log_permissions on EXIT.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

export _net_test_version
: "${_net_test_version:="00.00.18"}"

echo "[INFO] running net_test.sh v${_net_test_version}."

# ---------- Locate & source companions ----------
_entry="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
_entry_dir="$(cd "$(dirname "${_entry}")" && pwd)"

find_and_source() {
  local _name="$1"
  local search_dirs=(
    "${_entry_dir}"
    "/home/${USER}/Downloads"
  )
  for _dir in "${search_dirs[@]}"; do
    if [[ -f "${_dir}/${_name}" ]]; then
      . "${_dir}/${_name}"
      return 0
    fi
  done
  echo "FATAL: cannot find ${_name} in any of the search directories." >&2
  printf " - %s\n" "${search_dirs[@]}" >&2
  exit 1
}

find_and_source "config.sh"
find_and_source "function.sh"

# ---- API version check ----
: "${_requires_config_api:=00.00.01}"
: "${_requires_function_api:=00.00.03}"
check_api_versions "net_test.sh" "${_requires_config_api}" "${_requires_function_api}"

# ---------- Parse CLI ----------
parse_common_cli "$@"

# ---------- Parse --skip / --exclude (NET011) and --include-mac / --exclude-mac (NET019) ----------
# Supports: --skip enp3s0,enp4s0   or   --skip enp3s0 --skip enp4s0
#           --include-mac AA:BB:.. --exclude-mac CC-DD-..  (comma/space/; separated, repeatable)
# --skip removes NICs by name; --include-mac/--exclude-mac select by MAC (NET019),
# overriding _net_include_macs / _net_exclude_macs from config for this run.
declare -ga _net_test_skip_nics=()
_cli_inc_macs=""; _cli_exc_macs=""; _cli_inc_set=0; _cli_exc_set=0
_rem2=(); _ri=0
while [[ ${_ri} -lt ${#REM_ARGS[@]} ]]; do
  _ra="${REM_ARGS[${_ri}]}"
  case "${_ra}" in
    --skip=*|--exclude=*)
      IFS=',' read -ra _s <<< "${_ra#*=}"
      for _snic in "${_s[@]}"; do [[ -n "${_snic}" ]] && _net_test_skip_nics+=("${_snic}"); done
      ;;
    --skip|--exclude)
      (( _ri++ )) || true
      if [[ ${_ri} -lt ${#REM_ARGS[@]} ]]; then
        IFS=',' read -ra _s <<< "${REM_ARGS[${_ri}]}"
        for _snic in "${_s[@]}"; do [[ -n "${_snic}" ]] && _net_test_skip_nics+=("${_snic}"); done
      fi
      ;;
    --include-mac=*) _cli_inc_macs="${_cli_inc_macs} ${_ra#*=}"; _cli_inc_set=1 ;;
    --exclude-mac=*) _cli_exc_macs="${_cli_exc_macs} ${_ra#*=}"; _cli_exc_set=1 ;;
    --include-mac)
      (( _ri++ )) || true
      [[ ${_ri} -lt ${#REM_ARGS[@]} ]] && { _cli_inc_macs="${_cli_inc_macs} ${REM_ARGS[${_ri}]}"; _cli_inc_set=1; }
      ;;
    --exclude-mac)
      (( _ri++ )) || true
      [[ ${_ri} -lt ${#REM_ARGS[@]} ]] && { _cli_exc_macs="${_cli_exc_macs} ${REM_ARGS[${_ri}]}"; _cli_exc_set=1; }
      ;;
    *) _rem2+=("${_ra}") ;;
  esac
  (( _ri++ )) || true
done
REM_ARGS=("${_rem2[@]+"${_rem2[@]}"}")
if (( ${#_net_test_skip_nics[@]} > 0 )); then
  echo "[INFO] --skip list: ${_net_test_skip_nics[*]}"
fi
export _net_test_skip_nics
# CLI MAC lists override the config defaults for this run (NET019).
(( _cli_inc_set )) && _net_include_macs="${_cli_inc_macs# }"
(( _cli_exc_set )) && _net_exclude_macs="${_cli_exc_macs# }"
[[ -n "${_net_include_macs:-}" ]] && echo "[INFO] include-mac (NET019): ${_net_include_macs}"
[[ -n "${_net_exclude_macs:-}" ]] && echo "[INFO] exclude-mac (NET019): ${_net_exclude_macs}"

set -- "${REM_ARGS[@]}"

# ---------- Cleanup on exit ----------
# iperf3_del (from function.sh) kills all iperf3 processes system-wide.
# netns_del restores all namespaced NICs to root.
# fix_log_permissions ensures logs are readable by the login user even if
# the script is interrupted (Ctrl+C, crash, etc.) before generate_net_report runs.
trap 'iperf3_del; netns_del; fix_log_permissions "${_log_dir:-}" deep' EXIT

# ---------- Tools ----------
prepare_net_tools
ethtool_install
iperf3_install
jq_install   # required for result.json emission (LOG015) and per-pair JSON tmp files

# ---------- Log folder ----------
log_dir "" 1
log_root="${_session_log_dir}"

# ---------- Counter ----------
counter_init "net" "${_target_loop:-1}"

_loops_this_run=$(counter_loops_this_run)
if [[ "${_loops_this_run}" -le 0 ]]; then
  echo "[INFO] Already completed (${_n}/${_m}). Nothing to do."
  exit 0
fi

setup_session

# ---------- Timestamps ----------
: "${_session_ts:=$(now_ts)}"
_run_ts="${_session_ts}"
_netlog="${_session_log_dir}/net_test_${_run_ts}.log"
_netsum="${_session_log_dir}/net_summary_${_run_ts}.log"

run_time || true

# ---------- Main log header ----------
if [[ ! -f "${_netlog}" ]]; then
  {
    echo "============= Network Test (${_run_ts}) ============="
    echo "Host: $(hostname)   User: $(whoami)"
    echo "Mode: parallel pairs"
    echo "API: ${_function_api_version}   FeatureFlag: ${FEATURE_USE_NEW_NET_TOOLING:-0}"
    echo "===================================================="
  } > "${_netlog}"
fi

# ---------- Summary header ----------
: > "${_netsum}"
printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
  "Pair" "Speed(Mbps)" "IPv4" "IPv6" \
  "TCP Fwd (recv)" "TCP Rev (recv)" "UDP Fwd (recv)" "UDP Rev (recv)" >> "${_netsum}"

# ---------- Build topology ----------
netns_del
if ! netns_add; then
  echo "[FATAL] netns_add failed" | tee -a "${_netlog}"
  exit 65
fi

if (( ${#even_ethArray[@]} == 0 || ${#odd_ethArray[@]} == 0 )); then
  echo "[FATAL] No interface pairs were created." | tee -a "${_netlog}"
  exit 66
fi

# Warn about skipped NICs (odd count)
if (( ${#skipped_ethArray[@]} > 0 )); then
  for _sk in "${skipped_ethArray[@]}"; do
    echo "[WARN] NIC '${_sk}' has no pair (odd NIC count) — skipped. Will appear as N/A in summary." \
      | tee -a "${_netlog}"
  done
fi

# ---------- Helpers ----------

# Append a timestamped line to the main log.
# Using >> which is atomic for small writes on Linux, safe for parallel callers.
_main_log() { echo "[$(date '+%F %T')] $*" >> "${_netlog}"; }

_ping_check() {
  # usage: _ping_check <ns> <addr> <v6:0|1> <logfile>
  # Prints PASS or FAIL to stdout; detail goes to logfile.
  local ns="$1" addr="$2" v6="$3" logfile="$4"
  local tmpf; tmpf="$(mktemp)"
  if [[ "$v6" == "1" ]]; then
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping6 -6 -c 4 "${addr}" \
      | tee "${tmpf}" >> "${logfile}"
  else
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" ping -c 4 "${addr}" \
      | tee "${tmpf}" >> "${logfile}"
  fi
  grep -q " 0% packet loss" "${tmpf}" && echo "PASS" || echo "FAIL"
  rm -f "${tmpf}"
}

_extract_rate() {
  local f="$1"
  local line
  line="$(awk '/receiver$/{ln=$0} END{print ln}' "$f")"
  printf "%s\n" "$line" | grep -oE '[0-9.]+\s+[KMG]?bits/sec' | tail -n1
}

# Extract throughput as a plain number in Mbits/sec (canonical unit for JSON).
# Handles K/M/G prefixes by converting all to Mbits/sec.
# Returns 0 if no rate can be extracted (e.g. iperf3 client connection failed).
_extract_mbps_num() {
  local f="$1"
  local raw
  raw="$(_extract_rate "$f")"
  [[ -z "${raw}" ]] && { echo 0; return; }
  local num="${raw%% *}"
  case "${raw}" in
    *Kbits*) awk -v n="${num}" 'BEGIN{printf "%g", n/1000}' ;;
    *Mbits*) printf '%s\n' "${num}" ;;
    *Gbits*) awk -v n="${num}" 'BEGIN{printf "%g", n*1000}' ;;
    *)       echo 0 ;;
  esac
}

# Echo a number unchanged, or the JSON literal null when the value is empty.
# Used to feed jq --argjson for optional quality metrics.
_jnum() { [[ -n "$1" ]] && echo "$1" || echo null; }

# NET009: resolve the per-speed-tier TCP PASS percentage.  _net_tcp_pass_pct_tiers
# is "speedMbps:pct,..."; a speed not listed falls back to _net_tcp_pass_pct.
_tcp_pass_pct_for() {
  local mbps="$1" pair pct=""
  IFS=',' read -ra _tiers <<< "${_net_tcp_pass_pct_tiers:-}"
  for pair in "${_tiers[@]}"; do
    if [[ "${pair%%:*}" == "${mbps}" ]]; then pct="${pair##*:}"; break; fi
  done
  [[ -z "${pct}" ]] && pct="${_net_tcp_pass_pct:-95}"
  echo "${pct}"
}

# NET017: iperf3 quality metrics from a text log.  TCP retransmits come from the
# sender summary line; UDP jitter/loss from the receiver summary line.
_extract_retr() {   # TCP retransmit count, or empty
  awk '/sender$/{for(i=1;i<=NF;i++) if($i=="sender") print $(i-1)}' "$1" 2>/dev/null | tail -n1
}
_extract_udp_jitter() {  # jitter in ms, or empty
  awk '/receiver$/{for(i=1;i<=NF;i++) if($i=="ms") print $(i-1)}' "$1" 2>/dev/null | tail -n1
}
_extract_udp_loss() {    # loss percent (without %), or empty
  awk '/receiver$/{for(i=1;i<=NF;i++) if($i ~ /^\([0-9.]+%\)$/){g=$i; gsub(/[()%]/,"",g); print g}}' \
    "$1" 2>/dev/null | tail -n1
}

# NET016: snapshot rx/tx error + drop counters for an interface inside its
# namespace, driver-independently via /sys.  Prints "rxerr txerr rxdrop txdrop".
_nic_err_snapshot() {
  # NOTE: split the declaration — a single `local ns=$1 ifn=$2 b=...${ifn}...`
  # expands ${ifn} while building the `local` argument list, BEFORE ifn is
  # assigned, so under `set -u` it aborts with "ifn: unbound variable" (this was
  # silently killing every pair worker at the NET016 snapshot). Assign ifn first.
  local ns="$1" ifn="$2"
  local b="/sys/class/net/${ifn}/statistics" v
  local out=""
  for v in rx_errors tx_errors rx_dropped tx_dropped; do
    local n
    n="$(sudo ip netns exec "${ns}" cat "${b}/${v}" 2>/dev/null || echo 0)"
    [[ -z "${n}" ]] && n=0
    out="${out}${n} "
  done
  echo "${out}"   # "rxerr txerr rxdrop txdrop "
}

# NET018: verify a DF jumbo frame crosses the link unfragmented inside the ns.
# Returns PASS / FAIL-FRAG / FAIL.  payload = mtu - 28 (IPv4 + ICMP headers).
# FAIL-FRAG mirrors net_test.ps1: the kernel itself refused to send the DF
# packet because it exceeds the path MTU ("Message too long" / "Frag needed"),
# i.e. the MTU change did not actually take effect end-to-end.
_jumbo_ping() {
  local ns="$1" dst="$2" mtu="$3"
  local payload=$(( mtu - 28 )) out rc
  out="$(echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ping -M do -s "${payload}" -c 2 -W 2 "${dst}" 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    echo "PASS"
  elif echo "${out}" | grep -qiE 'message too long|frag needed|local error'; then
    echo "FAIL-FRAG"
  else
    echo "FAIL"
  fi
}

_set_speed() {
  local ns="$1" ifn="$2" spd="$3"
  if ! echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ethtool -s "${ifn}" speed "${spd}" duplex full autoneg off 2>/dev/null; then
    echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ethtool -s "${ifn}" speed "${spd}" 2>/dev/null || true
  fi
}

# Kill a specific iperf3 server by PID
_kill_iperf3_pid() {
  local pid="$1"
  [[ -z "${pid}" ]] && return 0
  sudo kill -TERM "${pid}" 2>/dev/null || true
  sleep 0.3
  sudo kill -KILL "${pid}" 2>/dev/null || true
}

# NET017 robustness: wait until an iperf3 server is actually accepting TCP
# connections on ${ip}:${port} inside ${ns}, instead of a blind fixed sleep.
# iperf3 always uses a TCP control channel (even for UDP tests), so a TCP
# connect probe confirms readiness for both.  Returns 0 once reachable, 1 on
# timeout (~5s).
_iperf_wait_ready() {
  local ns="$1" ip="$2" port="${3:-5201}" i
  for ((i=0; i<25; i++)); do
    if echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
         timeout 1 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# NET017 robustness: run one iperf3 direction against the shared odd-side server.
# If the run yields no data (server died / link not ready), restart the shared
# server and retry, up to 3 attempts, before giving up -- turning a transient
# race into a self-healing retry instead of a spurious UNKNOWN verdict (NET008).
# Relies on bash dynamic scope for ev/od/pair_idx/srv_pid/_netspd/_iperf_time/
# _iperf_omit/pairlog (all locals of the calling _run_pair).
# Usage: _iperf_run_dir <progress_label> <logfile> <extra_client_args>
_iperf_run_dir() {
  local label="$1" logfile="$2" extra="$3"
  local ip_cli="192.247.${pair_idx}.1" ip_srv="192.247.${pair_idx}.11"
  local attempt mbps _pp srvlog="${logfile%.log}_server.log"
  for attempt in 1 2 3; do
    _iperf3_progress "${label}" "${_iperf_time}" &
    _pp=$!
    # shellcheck disable=SC2086
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "${ip_cli}" --client "${ip_srv}" --port "${_pair_port}" \
        --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit "${_iperf_omit}" ${extra} \
        --logfile "${logfile}" || true
    wait "${_pp}" 2>/dev/null || true
    mbps="$(_extract_mbps_num "${logfile}")"
    [[ -n "${mbps}" && "${mbps}" != "0" ]] && return 0
    if (( attempt < 3 )); then
      echo "  [retry] iperf3 no data (attempt ${attempt}/3) -- restarting server and retrying" >> "${pairlog}"
      _kill_iperf3_pid "${srv_pid}"
      rm -f "${srvlog}"
      echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" \
        iperf3 --bind "${ip_srv}" --server --port "${_pair_port}" --daemon --logfile "${srvlog}" 2>/dev/null || true
      _iperf_wait_ready "ns_${od}" "${ip_srv}" "${_pair_port}" || true
      srv_pid="$(sudo ip netns exec "ns_${od}" \
        pgrep -f "iperf3.*192\.247\.${pair_idx}\.11.*${_pair_port}" 2>/dev/null | head -n1 || true)"
    fi
  done
  # Diagnostics: dump both client and server log tails so a connection-timeout
  # is root-causeable without opening every per-run log file.
  echo "  [diag] iperf3 returned 0 Mbps after 3 attempts; log tails:" >> "${pairlog}"
  for f in "${logfile}" "${srvlog}"; do
    [[ -f "${f}" ]] && echo "    $(basename "${f}"): $(tail -n 3 "${f}" | tr '\n' '|')" >> "${pairlog}"
  done
  return 0
}

# Show a progress line on the terminal while an iperf3 test runs.
# Runs in the background alongside the iperf3 client; caller must wait for it.
# Usage: _iperf3_progress <label> <duration_sec> &
#        progress_pid=$!
#        ... run iperf3 ...
#        wait ${progress_pid} 2>/dev/null || true
_iperf3_progress() {
  local label="$1"
  local total="$2"
  local elapsed=0
  while (( elapsed < total )); do
    printf "\r  [%-40s] %3ds / %3ds  %s" \
      "$(printf '#%.0s' $(seq 1 $(( elapsed * 40 / total + 1 ))))" \
      "${elapsed}" "${total}" "${label}" >&2
    sleep 1
    (( elapsed++ )) || true
  done
  printf "\r  %-78s\r" "" >&2   # clear the progress line
}

# Record a pair worker's abnormal termination instead of letting it vanish.
# Pair workers run backgrounded under `set -Eeuo pipefail`, so an unhandled
# failure exits the subshell with no trace and the pair renders as NOT_TESTED
# with no reason (and any ICMP result from the in-flight speed is lost, because
# results are only written at the END of each speed iteration). This ERR-trap
# handler captures the failing line+command and writes an ERROR entry to the
# pair's result JSON and summary so the failure is visible and diagnosable.
# Invoked from a trap set inside _run_pair; relies on bash dynamic scope (set -E)
# to see that pair's locals (pair_idx, pair, pairlog, pair_sum, pair_json,
# _netspd, v4_res, v6_res).
_pair_abort() {
  local _rc=$? _ln="${1:-?}" _cmd="${2:-?}"
  trap - ERR   # never recurse if a command below also fails
  local _why="worker aborted (exit ${_rc}) at line ${_ln}: ${_cmd}"
  echo "[ERROR] Pair ${pair_idx:-?} (${pair:-?}) ${_why}" >> "${pairlog:-/dev/null}" 2>/dev/null || true
  _main_log "[Pair ${pair_idx:-?}] ERROR — ${_why}" 2>/dev/null || true
  if [[ -n "${pair_json:-}" && -f "${pair_json:-}" ]]; then
    local _ej
    if _ej=$(jq --argjson speed "${_netspd:-0}" \
                --arg v4 "${v4_res:-N/A}" --arg v6 "${v6_res:-N/A}" \
                --arg reason "${_why}" \
                '.speeds += [{ speed_mbps:$speed, ipv4_ping:$v4, ipv6_ping:$v6,
                   throughput:{tcp_fwd_mbps:0,tcp_rev_mbps:0,udp_fwd_mbps:0,udp_rev_mbps:0},
                   verdict:"ERROR", reason:$reason }]' "${pair_json}" 2>/dev/null); then
      echo "${_ej}" > "${pair_json}"
    fi
  fi
  if [[ -n "${pair_sum:-}" ]]; then
    printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
      "${pair:-pair}(ERROR)" "${_netspd:-?}" "${v4_res:-N/A}" "${v6_res:-N/A}" "-" "-" "-" "-" \
      >> "${pair_sum}" 2>/dev/null || true
  fi
}

# ---------- Per-pair worker ----------
# Runs in a subshell (called with &).
# Each pair has its own detail log and a temp summary file.
# Temp summary files are merged into _netsum after all pairs finish.
_run_pair() {
  local pair_idx="$1"
  local ev="$2"
  local od="$3"
  local _k="$4"
  local _mm="$5"

  local pair="${ev}<->${od}"
  local pairlog="${log_root}/net_test_pair${pair_idx}_${_run_ts}.log"
  local pair_sum="${log_root}/.pair${pair_idx}_sum_${_run_ts}.tmp"
  # Per-pair JSON tmp (subshell-safe equivalent of pair_sum for structured data).
  # Written incrementally during the speed loop; merged after wait by parent.
  local pair_json="${log_root}/.pair${pair_idx}_data_${_run_ts}.json.tmp"
  jq -n --arg name "$pair" '{ name: $name, speeds: [] }' > "${pair_json}"

  # Surface (don't swallow) an unhandled failure anywhere in this worker.
  local _netspd="" v4_res="" v6_res=""   # so the handler can reference them safely
  trap '_pair_abort "${LINENO}" "${BASH_COMMAND}"' ERR

  {
    echo "============= Pair ${pair_idx}: ${pair} ============="
    echo "Start: $(date '+%Y-%m-%d %H:%M:%S')   Iteration: ${_k}/${_mm}"
    echo "====================================================="
  } >> "${pairlog}"

  # The iperf3 port rotates per loop (loop1: 5201/5202, loop2: 5203/5204, ...,
  # wrapping after 10 loops) so a loop can never collide with a socket the
  # previous loop left behind (TIME_WAIT, or a ghost server in the netns whose
  # bind IP was since removed/re-added).
  local _pair_port=$(( 5201 + ((( 10#${_k} - 1 ) % 10) * 2) ))

  # Per-loop init/recover: terminate any iperf3 process still bound to this
  # pair's test subnet in either namespace.  A leftover server from an aborted
  # run or an earlier loop silently holds its port while its socket is dead,
  # and every later connect to it times out.  Scoped to this pair's addresses,
  # so parallel pairs are untouched.
  _stop_pair_iperf() {
    local tag="$1" ns pid
    for ns in "ns_${ev}" "ns_${od}"; do
      for pid in $(sudo ip netns exec "${ns}" \
          pgrep -f "iperf3.*192\.247\.${pair_idx}\.(1|11)" 2>/dev/null || true); do
        sudo kill -KILL "${pid}" 2>/dev/null || true
        echo "  [${tag}] killed leftover iperf3 pid=${pid} in ${ns}" >> "${pairlog}"
      done
    done
  }
  _stop_pair_iperf init

  _main_log "[Pair ${pair_idx}] START  ${pair}"

  # Gather supported full-duplex speeds.
  # || true prevents set -e from aborting the subshell when grep finds no '/Full'
  # lines (NIC has no link / ethtool cannot read speed table).
  local _speed_list
  _speed_list="$(echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" ethtool "${ev}" 2>/dev/null \
    | tr ' ' '\n' | grep '/Full' | sed 's/[^0-9]//g' | sort -n | uniq)" || true
  [[ -z "${_speed_list}" ]] && _speed_list="10 100 1000 2500"

  # NET015: the pair's maximum link speed = highest speed BOTH NICs support.
  # _speed_list (from the even NIC) is ascending; the odd NIC's list is gathered
  # too, and the pair max is the greatest value common to both.
  local _odd_speed_list _pair_max_mbps=0 _even_max_mbps=0 _odd_max_mbps=0
  _odd_speed_list="$(echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" ethtool "${od}" 2>/dev/null \
    | tr ' ' '\n' | grep '/Full' | sed 's/[^0-9]//g' | sort -n | uniq)" || true
  [[ -z "${_odd_speed_list}" ]] && _odd_speed_list="${_speed_list}"
  local _sp
  for _sp in ${_speed_list}; do
    (( _sp > _even_max_mbps )) && _even_max_mbps="${_sp}" || true
    if echo " ${_odd_speed_list} " | grep -q " ${_sp} " && (( _sp > _pair_max_mbps )); then
      _pair_max_mbps="${_sp}"
    fi
  done
  for _sp in ${_odd_speed_list}; do (( _sp > _odd_max_mbps )) && _odd_max_mbps="${_sp}" || true; done
  # NET015: record the pair's and each NIC's maximum link speed on the pair object.
  jq --argjson em "${_even_max_mbps}" --argjson om "${_odd_max_mbps}" --argjson pm "${_pair_max_mbps}" \
     '. + { even_max_mbps:$em, odd_max_mbps:$om, pair_max_mbps:$pm }' \
     "${pair_json}" > "${pair_json}.tmp" && mv "${pair_json}.tmp" "${pair_json}"

  : > "${pair_sum}"

  for _netspd in ${_speed_list}; do
    {
      echo ""
      echo "### Speed = ${_netspd} Mbps"
      echo "----- Iteration ${_k} of ${_mm} -----"
      echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "${pairlog}"

    _set_speed "ns_${ev}" "${ev}" "${_netspd}"
    _set_speed "ns_${od}" "${od}" "${_netspd}"
    sleep 4

    # IPv4 ping
    echo "[IPv4 ICMP] ${ev} -> 192.247.${pair_idx}.11" >> "${pairlog}"
    local v4_res
    v4_res=$(_ping_check "ns_${ev}" "192.247.${pair_idx}.11" "0" "${pairlog}")

    echo "" >> "${pairlog}"

    # IPv6 ping
    echo "[IPv6 ICMP] ${ev} -> fd00:2470::${pair_idx}:11" >> "${pairlog}"
    local v6_res
    v6_res=$(_ping_check "ns_${ev}" "fd00:2470::${pair_idx}:11" "1" "${pairlog}")

    echo "" >> "${pairlog}"

    # NET016: snapshot error/drop counters on both NICs BEFORE the runs.
    local _err_before_ev="" _err_before_od=""
    if [[ "${_net_err_counter_check:-1}" == "1" ]]; then
      _err_before_ev="$(_nic_err_snapshot "ns_${ev}" "${ev}" || true)"
      _err_before_od="$(_nic_err_snapshot "ns_${od}" "${od}" || true)"
    fi

    # iperf3 log filenames include speed so parallel runs don't collide
    local tcp_fwd tcp_rev udp_fwd udp_rev srv_log
    tcp_fwd="${log_root}/iPerf3_${ev}_n_${od}_TCP_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    tcp_rev="${log_root}/iPerf3_${ev}_n_${od}_TCPRev_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    srv_log="${log_root}/iPerf3_${ev}_n_${od}_SRV_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"

    # Start iperf3 server on odd side (no --pidfile; use pgrep after start)
    rm -f "${srv_log}"
    echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" \
      iperf3 --bind "192.247.${pair_idx}.11" --server --port "${_pair_port}" --daemon --logfile "${srv_log}" 2>/dev/null || true
    # NET017 robustness: wait until the server actually accepts connections
    # rather than assuming 1s is enough.
    _iperf_wait_ready "ns_${od}" "192.247.${pair_idx}.11" "${_pair_port}" || true

    # Find the server PID: look for iperf3 listening on our bind address inside the ns
    local srv_pid=""
    srv_pid="$(sudo ip netns exec "ns_${od}" \
      pgrep -f "iperf3.*192\.247\.${pair_idx}\.11.*${_pair_port}" 2>/dev/null | head -n1 || true)"
    udp_fwd="${log_root}/iPerf3_${ev}_n_${od}_UDP_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
    udp_rev="${log_root}/iPerf3_${ev}_n_${od}_UDPRev_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"

    local _iperf_time="${_net_iperf_time_sec:-60}"
    local _iperf_omit="${_net_iperf_omit_sec:-3}"
    local _prog_pid

    echo "[TCP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf_run_dir "P${pair_idx} TCP Rev  ${ev}<-${od} @${_netspd}M" "${tcp_rev}" "--reverse"

    echo "[TCP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf_run_dir "P${pair_idx} TCP Fwd  ${ev}->${od} @${_netspd}M" "${tcp_fwd}" ""

    echo "[UDP Reverse] ${ev} <- ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf_run_dir "P${pair_idx} UDP Rev  ${ev}<-${od} @${_netspd}M" "${udp_rev}" "--udp --reverse"

    echo "[UDP Forward] ${ev} -> ${od} @ ${_netspd} Mbps" >> "${pairlog}"
    _iperf_run_dir "P${pair_idx} UDP Fwd  ${ev}->${od} @${_netspd}M" "${udp_fwd}" "--udp"

    # Kill iperf3 server for this speed now that all four tests are done
    _kill_iperf3_pid "${srv_pid}"

    # NET017: simultaneous bidirectional (full-duplex) TCP pass.  Two servers
    # (odd:5201 receives even->odd, even:5202 receives odd->even) and two clients
    # started at once so the link carries traffic both ways simultaneously.
    local _bidir_fwd="" _bidir_rev="" _bidir_sum=""
    if [[ "${_net_test_bidir:-1}" == "1" ]]; then
      echo "[Bidirectional full-duplex] ${ev} <-> ${od} @ ${_netspd} Mbps" >> "${pairlog}"
      local bi_fwd bi_rev
      bi_fwd="${log_root}/iPerf3_${ev}_n_${od}_BIDIRfwd_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
      bi_rev="${log_root}/iPerf3_${ev}_n_${od}_BIDIRrev_${_k}of${_mm}_spd${_netspd}_${_run_ts}.log"
      local _bi_port_a=${_pair_port} _bi_port_b=$((_pair_port + 1))
      echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" \
        iperf3 --bind "192.247.${pair_idx}.11" --server --port "${_bi_port_a}" --daemon 2>/dev/null || true
      echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" \
        iperf3 --bind "192.247.${pair_idx}.1"  --server --port "${_bi_port_b}" --daemon 2>/dev/null || true
      # NET017 robustness: wait until both bidir servers accept connections.
      _iperf_wait_ready "ns_${od}" "192.247.${pair_idx}.11" "${_bi_port_a}" || true
      _iperf_wait_ready "ns_${ev}" "192.247.${pair_idx}.1"  "${_bi_port_b}" || true
      # Track these two servers by PID so cleanup never touches OTHER parallel pairs
      # (iperf3_del would kill system-wide -- unsafe here).
      local _bi_srv_f _bi_srv_r
      _bi_srv_f="$(sudo ip netns exec "ns_${od}" pgrep -f "iperf3.*192\.247\.${pair_idx}\.11.*${_bi_port_a}" 2>/dev/null | head -n1 || true)"
      _bi_srv_r="$(sudo ip netns exec "ns_${ev}" pgrep -f "iperf3.*192\.247\.${pair_idx}\.1 .*${_bi_port_b}" 2>/dev/null | head -n1 || true)"
      echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
          --bind "192.247.${pair_idx}.1" --client "192.247.${pair_idx}.11" --port "${_bi_port_a}" \
          --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit "${_iperf_omit}" \
          --logfile "${bi_fwd}" &
      local _bi_pid_f=$!
      echo "${_pwd}" | sudo -S ip netns exec "ns_${od}" iperf3 \
          --bind "192.247.${pair_idx}.11" --client "192.247.${pair_idx}.1" --port "${_bi_port_b}" \
          --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit "${_iperf_omit}" \
          --logfile "${bi_rev}" &
      local _bi_pid_r=$!
      _iperf3_progress "P${pair_idx} BIDIR ${ev}<->${od} @${_netspd}M" "${_iperf_time}" &
      _prog_pid=$!
      wait "${_bi_pid_f}" 2>/dev/null || true
      wait "${_bi_pid_r}" 2>/dev/null || true
      wait "${_prog_pid}" 2>/dev/null || true
      _kill_iperf3_pid "${_bi_srv_f}"
      _kill_iperf3_pid "${_bi_srv_r}"
      _bidir_fwd="$(_extract_mbps_num "${bi_fwd}")"
      _bidir_rev="$(_extract_mbps_num "${bi_rev}")"
      _bidir_sum="$(awk -v f="${_bidir_fwd:-0}" -v r="${_bidir_rev:-0}" 'BEGIN{printf "%g", f+r}')"
      echo "  bidir fwd=${_bidir_fwd}M rev=${_bidir_rev}M sum=${_bidir_sum}M" >> "${pairlog}"
    fi

    # NET016: snapshot error/drop counters AFTER all iperf traffic and diff.
    local _err_total=0 _err_json="null"
    if [[ "${_net_err_counter_check:-1}" == "1" && -n "${_err_before_ev}" ]]; then
      local _eaft_ev _eaft_od
      _eaft_ev="$(_nic_err_snapshot "ns_${ev}" "${ev}" || true)"
      _eaft_od="$(_nic_err_snapshot "ns_${od}" "${od}" || true)"
      read -r _b_ev_rxe _b_ev_txe _b_ev_rxd _b_ev_txd <<< "${_err_before_ev}"
      read -r _b_od_rxe _b_od_txe _b_od_rxd _b_od_txd <<< "${_err_before_od}"
      read -r _a_ev_rxe _a_ev_txe _a_ev_rxd _a_ev_txd <<< "${_eaft_ev}"
      read -r _a_od_rxe _a_od_txe _a_od_rxd _a_od_txd <<< "${_eaft_od}"
      local _d_ev_rxe=$(( _a_ev_rxe - _b_ev_rxe )) _d_ev_txe=$(( _a_ev_txe - _b_ev_txe ))
      local _d_ev_rxd=$(( _a_ev_rxd - _b_ev_rxd )) _d_ev_txd=$(( _a_ev_txd - _b_ev_txd ))
      local _d_od_rxe=$(( _a_od_rxe - _b_od_rxe )) _d_od_txe=$(( _a_od_txe - _b_od_txe ))
      local _d_od_rxd=$(( _a_od_rxd - _b_od_rxd )) _d_od_txd=$(( _a_od_txd - _b_od_txd ))
      _err_total=$(( _d_ev_rxe + _d_ev_txe + _d_od_rxe + _d_od_txe ))
      _err_json=$(jq -n \
        --argjson erxe "${_d_ev_rxe}" --argjson etxe "${_d_ev_txe}" \
        --argjson erxd "${_d_ev_rxd}" --argjson etxd "${_d_ev_txd}" \
        --argjson orxe "${_d_od_rxe}" --argjson otxe "${_d_od_txe}" \
        --argjson orxd "${_d_od_rxd}" --argjson otxd "${_d_od_txd}" \
        '{ even_rx_errors:$erxe, even_tx_errors:$etxe, even_rx_discards:$erxd, even_tx_discards:$etxd,
           odd_rx_errors:$orxe, odd_tx_errors:$otxe, odd_rx_discards:$orxd, odd_tx_discards:$otxd }')
      echo "  [counters] even rx_err=${_d_ev_rxe} tx_err=${_d_ev_txe} | odd rx_err=${_d_od_rxe} tx_err=${_d_od_txe} | total_err=${_err_total}" >> "${pairlog}"
    fi

    # NET018: jumbo-frame (MTU) verification at >=1000M.  On Linux, `ip link set
    # mtu` controls the L2 frame size directly (unlike Windows, which splits IP
    # MTU from the NIC's '*JumboPacket' driver setting -- see net_test.ps1).  If
    # either NIC rejects the requested MTU (driver/hardware cap), skip the ping
    # rather than report a misleading FAIL.
    local _jumbo_res="null"
    if [[ "${_net_test_jumbo:-1}" == "1" ]] && (( _netspd >= 1000 )); then
      local _mtu="${_net_jumbo_mtu:-9000}"
      echo "  [jumbo] setting MTU ${_mtu} and testing DF ping..." >> "${pairlog}"
      local _mtu_ev_ok=1 _mtu_od_ok=1
      sudo ip netns exec "ns_${ev}" ip link set dev "${ev}" mtu "${_mtu}" 2>/dev/null || _mtu_ev_ok=0
      sudo ip netns exec "ns_${od}" ip link set dev "${od}" mtu "${_mtu}" 2>/dev/null || _mtu_od_ok=0
      if (( _mtu_ev_ok == 0 || _mtu_od_ok == 0 )); then
        _jumbo_res="\"SKIP\""
        echo "  [jumbo] MTU=${_mtu} result=SKIP (NIC rejected MTU ${_mtu})" >> "${pairlog}"
      else
        sleep 1
        _jumbo_res="\"$(_jumbo_ping "ns_${ev}" "192.247.${pair_idx}.11" "${_mtu}")\""
        echo "  [jumbo] MTU=${_mtu} result=${_jumbo_res}" >> "${pairlog}"
      fi
      sudo ip netns exec "ns_${ev}" ip link set dev "${ev}" mtu 1500 2>/dev/null || true
      sudo ip netns exec "ns_${od}" ip link set dev "${od}" mtu 1500 2>/dev/null || true
    fi

    # NET017: iperf3 quality metrics (TCP retransmits, UDP jitter/loss).
    local _retr_fwd _retr_rev _jit_fwd _jit_rev _loss_fwd _loss_rev
    _retr_fwd="$(_extract_retr "${tcp_fwd}")"; _retr_rev="$(_extract_retr "${tcp_rev}")"
    _jit_fwd="$(_extract_udp_jitter "${udp_fwd}")"; _jit_rev="$(_extract_udp_jitter "${udp_rev}")"
    _loss_fwd="$(_extract_udp_loss "${udp_fwd}")"; _loss_rev="$(_extract_udp_loss "${udp_rev}")"

    # Extract rates
    local rate_tcp_fwd rate_tcp_rev rate_udp_fwd rate_udp_rev
    rate_tcp_fwd="$(_extract_rate "${tcp_fwd}")"; [[ -z "${rate_tcp_fwd}" ]] && rate_tcp_fwd="N/A"
    rate_tcp_rev="$(_extract_rate "${tcp_rev}")"; [[ -z "${rate_tcp_rev}" ]] && rate_tcp_rev="N/A"
    rate_udp_fwd="$(_extract_rate "${udp_fwd}")"; [[ -z "${rate_udp_fwd}" ]] && rate_udp_fwd="N/A"
    rate_udp_rev="$(_extract_rate "${udp_rev}")"; [[ -z "${rate_udp_rev}" ]] && rate_udp_rev="N/A"

    printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
      "${pair}" "${_netspd}" "${v4_res}" "${v6_res}" \
      "${rate_tcp_fwd}" "${rate_tcp_rev}" "${rate_udp_fwd}" "${rate_udp_rev}" \
      >> "${pair_sum}"

    # Append structured speed entry to pair_json (for result.json).
    # Numeric throughputs in canonical Mbits/sec.
    local n_tcp_fwd n_tcp_rev n_udp_fwd n_udp_rev speed_verdict _reason
    n_tcp_fwd="$(_extract_mbps_num "${tcp_fwd}")"
    n_tcp_rev="$(_extract_mbps_num "${tcp_rev}")"
    n_udp_fwd="$(_extract_mbps_num "${udp_fwd}")"
    n_udp_rev="$(_extract_mbps_num "${udp_rev}")"

    # NET009: per-speed-tier TCP PASS threshold (not a flat 95%).
    local _pct _thr_mbps
    _pct="$(_tcp_pass_pct_for "${_netspd}")"
    _thr_mbps=$(awk -v s="${_netspd}" -v p="${_pct}" 'BEGIN{printf "%g", s*p/100}')

    if [[ "${v4_res}" != "PASS" || "${v6_res}" != "PASS" ]]; then
      speed_verdict="FAIL"
      local _c=""
      [[ "${v4_res}" != "PASS" ]] && _c="IPv4 ICMP ${v4_res}"
      [[ "${v6_res}" != "PASS" ]] && _c="${_c:+${_c}; }IPv6 ICMP ${v6_res}"
      _reason="FAIL: ${_c}"
    elif [[ "${n_tcp_fwd}" == "0" || "${n_tcp_rev}" == "0" ]]; then
      speed_verdict="UNKNOWN"
      _reason="iperf3 returned no data (0 Mbps) for one or both TCP directions -- connection timeout or link not ready"
    else
      # NET009: both TCP directions >= tier% of nominal link speed.
      if awk -v f="${n_tcp_fwd}" -v r="${n_tcp_rev}" -v t="${_thr_mbps}" \
            'BEGIN{exit (f>=t && r>=t) ? 0 : 1}'; then
        speed_verdict="PASS"
        _reason="TCP fwd ${n_tcp_fwd}M and rev ${n_tcp_rev}M both >= ${_thr_mbps}M (${_pct}% of ${_netspd}M)"
      else
        speed_verdict="FAIL"
        local _c=""
        if awk -v f="${n_tcp_fwd}" -v t="${_thr_mbps}" 'BEGIN{exit (f<t)?0:1}'; then
          _c="TCP fwd ${n_tcp_fwd}M < ${_thr_mbps}M threshold"
        fi
        if awk -v r="${n_tcp_rev}" -v t="${_thr_mbps}" 'BEGIN{exit (r<t)?0:1}'; then
          _c="${_c:+${_c}; }TCP rev ${n_tcp_rev}M < ${_thr_mbps}M threshold"
        fi
        _reason="FAIL: ${_c} (threshold ${_pct}% of ${_netspd}M = ${_thr_mbps}M)"
      fi
    fi

    # NET016: a non-zero rx/tx error delta annotates the reason and, when
    # _net_err_fail_on_delta=1, fails an otherwise-PASS speed.
    if (( _err_total > 0 )); then
      if [[ "${_net_err_fail_on_delta:-0}" == "1" && "${speed_verdict}" == "PASS" ]]; then
        speed_verdict="FAIL"
        _reason="FAIL: NIC error counters incremented (rx/tx errors total=${_err_total}) -- throughput met threshold but the link is erroring frames"
      else
        _reason="${_reason}  [warning: NIC rx/tx error counters +${_err_total} during run]"
      fi
    fi
    # NET018: a failed jumbo test annotates the reason (informational); SKIP
    # (NIC/driver does not support the configured MTU) is not an error.
    if [[ "${_jumbo_res}" != "null" && "${_jumbo_res}" != "\"PASS\"" && "${_jumbo_res}" != "\"SKIP\"" ]]; then
      _reason="${_reason}  [jumbo MTU ${_net_jumbo_mtu:-9000}: $(echo "${_jumbo_res}" | tr -d '\"')]"
    fi

    local _pair_json_new
    _pair_json_new=$(jq \
      --argjson speed   "${_netspd}" \
      --arg     v4      "${v4_res}" \
      --arg     v6      "${v6_res}" \
      --argjson tcp_fwd "${n_tcp_fwd:-0}" \
      --argjson tcp_rev "${n_tcp_rev:-0}" \
      --argjson udp_fwd "${n_udp_fwd:-0}" \
      --argjson udp_rev "${n_udp_rev:-0}" \
      --argjson bd_fwd  "$(_jnum "${_bidir_fwd}")" \
      --argjson bd_rev  "$(_jnum "${_bidir_rev}")" \
      --argjson bd_sum  "$(_jnum "${_bidir_sum}")" \
      --argjson retr_f  "$(_jnum "${_retr_fwd}")" \
      --argjson retr_r  "$(_jnum "${_retr_rev}")" \
      --argjson jit_f   "$(_jnum "${_jit_fwd}")" \
      --argjson jit_r   "$(_jnum "${_jit_rev}")" \
      --argjson loss_f  "$(_jnum "${_loss_fwd}")" \
      --argjson loss_r  "$(_jnum "${_loss_rev}")" \
      --argjson errc    "${_err_json}" \
      --argjson jumbo   "${_jumbo_res}" \
      --argjson pct     "${_pct}" \
      --argjson thr     "${_thr_mbps}" \
      --arg     verdict "${speed_verdict}" \
      --arg     reason  "${_reason}" \
      '.speeds += [{
        speed_mbps: $speed,
        ipv4_ping:  $v4,
        ipv6_ping:  $v6,
        throughput: {
          tcp_fwd_mbps: $tcp_fwd,
          tcp_rev_mbps: $tcp_rev,
          udp_fwd_mbps: $udp_fwd,
          udp_rev_mbps: $udp_rev
        },
        bidirectional: { fwd_mbps: $bd_fwd, rev_mbps: $bd_rev, sum_mbps: $bd_sum },
        quality: { tcp_fwd_retr: $retr_f, tcp_rev_retr: $retr_r,
                   udp_fwd_jitter_ms: $jit_f, udp_rev_jitter_ms: $jit_r,
                   udp_fwd_lost_pct: $loss_f, udp_rev_lost_pct: $loss_r },
        error_counters: $errc,
        jumbo: { mtu: ('"${_net_jumbo_mtu:-9000}"'|tonumber), result: $jumbo },
        tcp_pass_pct: $pct,
        tcp_pass_thr_mbps: $thr,
        verdict: $verdict,
        reason: $reason
      }]' "${pair_json}")
    echo "${_pair_json_new}" > "${pair_json}"

    echo "Verdict: ${speed_verdict}  ${_reason}" >> "${pairlog}"
    echo "[Speed ${_netspd} Mbps done]" >> "${pairlog}"
  done

  # Per-loop recover: reap any iperf3 process this pair left running so the
  # next loop (or the final teardown) starts from a clean slate.
  _stop_pair_iperf recover

  echo "End: $(date '+%Y-%m-%d %H:%M:%S')" >> "${pairlog}"
  _main_log "[Pair ${pair_idx}] DONE   ${pair}"
}

# ---------- Main test loop ----------
# Accumulate per-pair JSON for result.json (LOG015). Each _run_pair writes its own
# .pair${i}_data_${_run_ts}.json.tmp; we merge them into _jq_pairs after wait.
_jq_pairs='[]'

for (( loop_n=1; loop_n<=_loops_this_run; loop_n++ )); do
  echo "------------------------------------------------------------"
  echo "[$(counter_next_tag)] Network test... (parallel pairs)"
  _km="$(counter_next_tag)"
  _k="${_km%%/*}"
  _mm="${_km##*/}"
  test_progress_set "net_test" "${_k}" "${_mm}"

  _main_log "=== Iteration ${_k}/${_mm} START — ${#even_ethArray[@]} pair(s) launching in parallel ==="

  # Launch all pairs in background
  _pair_pids=()
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    _run_pair "${i}" "${even_ethArray[i]}" "${odd_ethArray[i]}" "${_k}" "${_mm}" &
    _pair_pids+=($!)
    echo "[INFO] Pair ${i} (${even_ethArray[i]}<->${odd_ethArray[i]}) launched (PID ${_pair_pids[-1]})"
  done

  # Wait for all pair workers to finish
  _failed=0
  for pid in "${_pair_pids[@]}"; do
    wait "${pid}" || { echo "[WARN] Pair worker PID ${pid} exited with error"; _failed=1; }
  done
  (( _failed )) && echo "[WARN] One or more pairs reported errors — check per-pair logs."

  _main_log "=== Iteration ${_k}/${_mm} DONE ==="

  # Merge per-pair temp summaries into main summary (ordered by pair index)
  _tmp=""
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    _tmp="${log_root}/.pair${i}_sum_${_run_ts}.tmp"
    if [[ -f "${_tmp}" ]]; then
      cat "${_tmp}" >> "${_netsum}"
      rm -f "${_tmp}"
    fi
  done

  # Merge per-pair JSON tmp files into _jq_pairs (ordered by pair index).
  # Each pair_json contains a {name, speeds[]} object built by _run_pair.
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    _tmp="${log_root}/.pair${i}_data_${_run_ts}.json.tmp"
    if [[ -f "${_tmp}" ]]; then
      _jq_pairs=$(jq --slurpfile add "${_tmp}" '. + $add' <<<"${_jq_pairs}")
      rm -f "${_tmp}"
    fi
  done

  # N/A rows for odd-count NICs (no pair)
  if (( ${#skipped_ethArray[@]} > 0 )); then
    for _sk in "${skipped_ethArray[@]}"; do
      printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
        "${_sk}(no pair)" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" >> "${_netsum}"
    done
  fi

  # SKIPPED rows for NICs excluded via --skip (NET011) or by MAC (NET019)
  if (( ${#excluded_ethArray[@]} > 0 )); then
    for _xi in "${!excluded_ethArray[@]}"; do
      _ex="${excluded_ethArray[_xi]}"
      case "${excluded_reasonArray[_xi]:-}" in
        *_exclude_macs*) _tag="excl-mac" ;;
        *_include_macs*) _tag="not-incl" ;;
        *)               _tag="--skip"   ;;
      esac
      printf "%-23s | %10s | %8s | %8s | %18s | %18s | %18s | %18s\n" \
        "${_ex}(${_tag})" "SKIPPED" "-" "-" "-" "-" "-" "-" >> "${_netsum}"
    done
  fi

  counter_tick
done

# ---------- Done ----------
elp_time | tee -a "${_netlog}"
echo "[INFO] Main log : ${_netlog}"
echo "[INFO] Summary  : ${_netsum}"
echo "[INFO] Pair logs: ${log_root}/net_test_pair*_${_run_ts}.log"

# Append SKIPPED entries for NICs excluded via --skip (NET011) or by MAC (NET019).
# Each excluded NIC gets one entry with verdict=SKIPPED and its specific reason so
# it appears in the HTML report and result.json, making it visible to reviewers.
if (( ${#excluded_ethArray[@]} > 0 )); then
  for _xi in "${!excluded_ethArray[@]}"; do
    _ex="${excluded_ethArray[_xi]}"
    _exr="${excluded_reasonArray[_xi]:---skip flag (NET011)}"
    _jq_pairs=$(jq \
      --arg name "${_ex}" \
      --arg reason "${_exr}" \
      '. + [{ name: $name, skip_reason: $reason,
              speeds: [{ speed_mbps: 0, ipv4_ping: "SKIPPED", ipv6_ping: "SKIPPED",
                throughput: { tcp_fwd_mbps: 0, tcp_rev_mbps: 0,
                              udp_fwd_mbps: 0, udp_rev_mbps: 0 },
                verdict: "SKIPPED" }] }]' \
      <<<"${_jq_pairs}")
  done
fi

# ---------- Emit result.json (LOG015 / LOG017 / LOG020) ----------
_resultjson="${log_root}/net_test_${_run_ts}.result.json"

# Counts by verdict, derived from _jq_pairs (each speed counts as one test item).
_total_count=$(  jq '[.[] | .speeds[]] | length'                                <<<"$_jq_pairs")
_pass_count=$(   jq '[.[] | .speeds[] | select(.verdict=="PASS")]    | length'  <<<"$_jq_pairs")
_fail_count=$(   jq '[.[] | .speeds[] | select(.verdict=="FAIL")]    | length'  <<<"$_jq_pairs")
_unknown_count=$(jq '[.[] | .speeds[] | select(.verdict=="UNKNOWN")] | length'  <<<"$_jq_pairs")
_skipped_count=$(jq '[.[] | .speeds[] | select(.verdict=="SKIPPED")] | length'  <<<"$_jq_pairs")
_error_count=$(  jq '[.[] | .speeds[] | select(.verdict=="ERROR")]   | length'  <<<"$_jq_pairs")

_summary_json=$(jq -n \
  --argjson total   "$_total_count" \
  --argjson passed  "$_pass_count" \
  --argjson failed  "$_fail_count" \
  --argjson unknown "$_unknown_count" \
  --argjson skipped "$_skipped_count" \
  --argjson error   "$_error_count" \
  '{ total: $total, passed: $passed, failed: $failed,
     unknown: $unknown, skipped: $skipped, error: $error }')

_details_json=$(jq -n --argjson pairs "$_jq_pairs" '{ pairs: $pairs }')

# Overall verdict roll-up (same logic as disk_test):
#   any ERROR → ERROR; any FAIL → FAIL;
#   all PASS (and total>0) → PASS; otherwise → UNKNOWN
if   (( _error_count > 0 )); then _verdict="ERROR"
elif (( _fail_count  > 0 )); then _verdict="FAIL"
elif (( _pass_count == _total_count && _total_count > 0 )); then _verdict="PASS"
else _verdict="UNKNOWN"
fi

emit_result_json \
  --test-name    net_test \
  --test-version "${_net_test_version:-unknown}" \
  --verdict      "$_verdict" \
  --summary-json "$_summary_json" \
  --details-json "$_details_json" \
  --output       "$_resultjson"

echo "[INFO] Result JSON: ${_resultjson}"

test_progress_clear "net_test completed. Safe to power off."
generate_net_report "${log_root}"
cd "${_tool_path}"
