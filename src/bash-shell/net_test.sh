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
: "${_requires_function_api:=00.00.05}"
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
trap 'test_heartbeat_stop; iperf3_del; netns_del; fix_log_permissions "${_log_dir:-}" deep' EXIT

# ---------- Tools ----------
prepare_net_tools
ethtool_install
iperf3_install
jq_install   # required for result.json emission (LOG015) and per-pair JSON tmp files

# ---------- Log folder ----------
log_dir "" 1
log_root="${_session_log_dir}"

# FWK038: liveness heartbeat — periodic proof the run has not hung.
test_heartbeat_start "net_test"


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
    # FWK037: record the configuration this run was measured on.
    collect_system_info
    echo ""
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
  local _png="ping"; [[ "$v6" == "1" ]] && _png="ping6 -6"

  # Prime the neighbour cache before measuring (BUG0060).
  #
  # A link-speed change takes the carrier down, which clears the ARP/ND entry for
  # the peer. The FIRST packet afterwards is then consumed resolving the address,
  # and ping counts it as lost -- 4 transmitted, 3 received, 25% loss -- so a
  # perfectly healthy link failed the "0% packet loss" check. The remaining three
  # replies arriving at 0.3 ms, and 44 Gbit/s of TCP immediately afterwards, are
  # what show it was never a connectivity fault.
  #
  # Only IPv4 showed it, which looked like an IPv4-specific bug and is not: IPv6
  # runs second, by which time the neighbour is already resolved. Priming makes
  # the two symmetric and measures steady-state reachability, which is the thing
  # this check is actually about.
  # shellcheck disable=SC2086
  echo "${_pwd}" | sudo -S ip netns exec "${ns}" ${_png} -c 1 -W 2 "${addr}" \
    >/dev/null 2>&1 || true
  # `|| true`: ping exits 1 on packet loss, and with `set -o pipefail` that makes
  # the whole pipeline fail. But a failed ping is the ANSWER here, not an error --
  # the verdict is decided by the grep below, from the output we just captured.
  # Without this the ERR trap fired on a completely handled path and reported a
  # crash for every unreachable link (BUG0048).
  # shellcheck disable=SC2086
  echo "${_pwd}" | sudo -S ip netns exec "${ns}" ${_png} -c 4 "${addr}" \
    | tee "${tmpf}" >> "${logfile}" || true
  grep -q " 0% packet loss" "${tmpf}" && echo "PASS" || echo "FAIL"
  rm -f "${tmpf}"
}

_extract_rate() {
  local f="$1"
  local line
  line="$(awk '/receiver$/{ln=$0} END{print ln}' "$f")"
  # `|| true`: no match is a valid, expected answer. An iperf3 client that could
  # not connect writes no rate line at all, and every caller handles the empty
  # string one line later ("N/A", or 0 in _extract_mbps_num). grep's exit 1 for
  # "no match" must not look like a command failure to the ERR trap (BUG0048) --
  # the sibling extractors below are awk-only and already return 0 for no match.
  printf "%s\n" "$line" | grep -oE '[0-9.]+\s+[KMG]?bits/sec' | tail -n1 || true
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
  # A failing DF ping is the ANSWER here, not an error -- rc is inspected on the
  # very next lines to tell FAIL-FRAG from FAIL. But the bare assignment made the
  # command substitution's non-zero status trip the ERR trap, so every link that
  # could not carry a 9000-MTU frame also produced a phantom "unhandled command
  # failure at line 374" record (BUG0054). Same defect BUG0048 fixed in
  # _ping_check and _extract_rate; this site was missed.
  # `&& rc=0 || rc=$?` keeps the real exit status while making the whole thing a
  # compound command, which the ERR trap does not fire on.
  out="$(echo "${_pwd}" | sudo -S ip netns exec "${ns}" \
        ping -M do -s "${payload}" -c 2 -W 2 "${dst}" 2>&1)" && rc=0 || rc=$?
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

# Wait until a NIC reports carrier at the speed it was just set to (BUG0056).
#
# ethtool -s returns as soon as the driver accepts the request; bringing the link
# up is asynchronous and, on a high-speed DAC link with RS-FEC, takes far longer
# than the blind `sleep 4` this replaces. When the wait was too short every probe
# that followed failed, and the run reported "IPv4 ICMP FAIL" -- true, but it
# named a symptom three layers above the cause and looked identical to a real
# connectivity fault.
#
# Prints the negotiated speed on success. Returns 1 if carrier never came up
# within the timeout, 2 if it came up at a DIFFERENT speed than requested --
# which is not a link fault but does mean the row cannot be judged against the
# speed it claims to be testing.
_wait_link_up() {
  local ns="$1" ifn="$2" want="$3" timeout="${4:-${_net_link_up_timeout_sec:-30}}"
  local i out link spd
  for (( i=0; i<timeout; i++ )); do
    out="$(echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool "${ifn}" 2>/dev/null || true)"
    link="$(grep -i 'Link detected:' <<<"${out}" | awk '{print $NF}')"
    if [[ "${link}" == "yes" ]]; then
      spd="$(grep -iE '^[[:space:]]*Speed:' <<<"${out}" | sed -E 's/.*Speed:[[:space:]]*([0-9]+).*/\1/')"
      printf '%s\n' "${spd:-unknown}"
      [[ "${spd}" == "${want}" ]] && return 0
      return 2
    fi
    sleep 1
  done
  printf '%s\n' "down"
  return 1
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
# List a NIC's supported full-duplex link speeds in Mbps, ascending, deduplicated.
#
# ethtool names a mode as <speed>base<medium><lanes>, e.g. 100000baseCR4/Full.
# The speed is the digits BEFORE "base"; the trailing digit is the lane count.
# Stripping every non-digit -- `sed 's/[^0-9]//g'`, what this used to do --
# concatenates the two: 100000baseCR4 became "1000004", a nonexistent 1 Tb/s
# speed the test then tried to set and measure (BUG0051). On a NIC offering the
# same speed over different lane counts it also produced apparent duplicates
# (50000baseCR and 50000baseCR2 -> 50000 and 500002) while the genuine 200000
# and 400000 speeds, which this NIC only offers as CR2/CR4, were never tested at
# their real value at all.
#
# Usage: _supported_speeds <netns> <ifname>
_supported_speeds() {
  local ns="$1" ifn="$2"
  echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool "${ifn}" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+base[^/]*/Full$' \
    | sed -E 's/^([0-9]+)base.*$/\1/' \
    | sort -n -u
}

# Maximum TCP goodput achievable on an Ethernet link, as a fraction of line rate.
#
# NET009 used to compare iperf3's number directly against the nominal link speed,
# but they measure different things: the link speed is the WIRE rate, while
# iperf3 reports TCP payload (goodput). Every frame also carries preamble+SFD (8),
# Ethernet header (14), FCS (4) and the inter-frame gap (12) -- 38 bytes that
# never appear in goodput -- plus IP and TCP headers inside the MTU.
#
# At MTU 1500 with Linux's default TCP timestamps that ceiling is 94.15%, so a
# 95% threshold was ABOVE the physical maximum and could not be met by any
# hardware (BUG0061). A NIC measured at 94.2% was running at 100% of what the
# wire allows and was reported as a failure.
#
# Prints the fraction with 4 decimals. Usage: _goodput_efficiency <mtu>
_goodput_efficiency() {
  local mtu="${1:-1500}"
  local ovh="${_net_frame_overhead_bytes:-38}"
  local hdr="${_net_l3l4_overhead_bytes:-52}"    # IP 20 + TCP 20 + timestamps 12
  awk -v m="${mtu}" -v o="${ovh}" -v h="${hdr}" \
      'BEGIN{ if (m <= h) { print "1.0000"; exit } printf "%.4f", (m - h) / (m + o) }'
}

# Report how a link is actually running: lane count and active FEC encoding.
#
# This is the evidence that distinguishes "the NIC cannot do this speed" from
# "the cable is bad" (BUG0062), and until now it existed only in dmesg, which
# needs root and is not part of any artefact. A 200G link that comes up as
# 4 lanes with RS(544,514) is running 50G per lane; 400GBASE-CR4 needs 100G per
# lane, so the same port failing at 400G is a signalling-rate limit, not a fault.
#
# Prints "lanes=<n> fec=<encoding>", with "?" for anything unavailable.
_link_detail() {
  local ns="$1" ifn="$2" out fec lanes
  out="$(echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool "${ifn}" 2>/dev/null || true)"
  lanes="$(grep -iE '^[[:space:]]*Lanes:' <<<"${out}" | awk '{print $NF}')"
  fec="$(echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool --show-fec "${ifn}" 2>/dev/null \
         | grep -i 'Active FEC' | sed -E 's/.*:[[:space:]]*//')"
  printf 'lanes=%s fec=%s\n' "${lanes:-?}" "${fec:-?}"
}

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
# _iperf_omit/_iperf_wall/pairlog (all locals of the calling _run_pair).
# Usage: _iperf_run_dir <progress_label> <logfile> <extra_client_args>
_iperf_run_dir() {
  local label="$1" logfile="$2" extra="$3"
  local ip_cli="192.247.${pair_idx}.1" ip_srv="192.247.${pair_idx}.11"
  local attempt mbps _pp srvlog="${logfile%.log}_server.log"
  for attempt in 1 2 3; do
    _iperf3_progress "${label}" "${_iperf_wall}" &
    _pp=$!
    # shellcheck disable=SC2086
    echo "${_pwd}" | sudo -S ip netns exec "ns_${ev}" iperf3 \
        --bind "${ip_cli}" --client "${ip_srv}" --port "${_pair_port}" \
        --bitrate "${_netspd}M" --time "${_iperf_time}" --interval 3 --omit "${_iperf_omit}" \
        --parallel "${_net_iperf_parallel:-1}" ${extra} \
        --logfile "${logfile}" || true
    _progress_stop "${_pp}"
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

# Show a live progress line on the terminal while an iperf3 test runs.
#
# FWK038: this is the operator's liveness indicator, not decoration. It must keep
# moving for as long as the step it covers is running, so a healthy-but-slow DUT
# is never mistaken for a hung one.
#
# It therefore does NOT stop at `total`. A nominal 60 s transfer can run far
# longer than 60 s -- an iperf3 client that cannot reach the server blocks on the
# TCP connect timeout, roughly two minutes, with --time never coming into play.
# The bar used to end at 60 s and clear itself, leaving the console frozen for
# the remaining ~67 s of every failed attempt, three attempts per direction
# (BUG0050). Past `total` it keeps ticking and says so.
#
# The caller stops it with _progress_stop; the hard ceiling is only a backstop so
# an orphaned bar (worker killed mid-step) cannot spin forever.
#
# Usage: _iperf3_progress <label> <duration_sec> &
#        progress_pid=$!
#        ... run iperf3 ...
#        _progress_stop "${progress_pid}"
_iperf3_progress() {
  local label="$1"
  local total="$2"
  local elapsed=0
  local hard_stop=$(( total * 5 + 600 ))
  local bar
  # FWK038: claim the console while this bar is drawing, so the periodic
  # heartbeat holds off. Two writers on one terminal produce garbage, and while
  # the bar is up it is the better liveness indicator -- it updates every second
  # and names the step. Released however this subshell ends.
  if [[ -n "${_ADLINK_HB_BUSY_FILE:-}" ]]; then
    : > "${_ADLINK_HB_BUSY_FILE}" 2>/dev/null || true
    trap 'rm -f "${_ADLINK_HB_BUSY_FILE}" 2>/dev/null || true' EXIT
  fi
  while (( elapsed < hard_stop )); do
    # \033[K erases from the cursor to end of line. Without it a shorter label
    # leaves the tail of the previous, longer one on screen -- which is how a
    # redraw produced the fragment "np12s2 @10M" hanging off the end of the bar
    # (BUG0049). Padding to a fixed width cannot fix it: the terminal may be
    # narrower than the pad, and then the pad itself wraps.
    if (( elapsed < total )); then
      bar="$(printf '#%.0s' $(seq 1 $(( elapsed * 40 / total + 1 ))))"
      printf "\r  [%-40s] %3ds / %3ds  %s\033[K" \
        "${bar}" "${elapsed}" "${total}" "${label}" >&2
    else
      # Past the estimate the bar simply reads e.g. "88s / 68s", which already
      # says the step is taking longer than predicted and is not, by itself,
      # cause for concern -- the denominator is an estimate, and UDP teardown at
      # 400G is legitimately slower than any fixed allowance predicts.
      #
      # "(still running)" is the ALARM, and it is deliberately not the same
      # threshold (BUG0058). Sizing the bar and deciding something is wrong are
      # different questions: BUG0053 fixed the bar by making its denominator
      # honest, but left the alarm firing the instant the estimate was passed, so
      # any step a few seconds slow raised it. Only past the grace period does
      # this become the thing it was added for -- a client blocked on a connect
      # timeout, roughly two minutes, that would otherwise look like a hang.
      if (( elapsed > total + ${_net_iperf_overrun_grace_sec:-30} )); then
        printf "\r  [%-40s] %3ds / %3ds  %s  (still running)\033[K" \
          "$(printf '#%.0s' $(seq 1 40))" "${elapsed}" "${total}" "${label}" >&2
      else
        printf "\r  [%-40s] %3ds / %3ds  %s\033[K" \
          "$(printf '#%.0s' $(seq 1 40))" "${elapsed}" "${total}" "${label}" >&2
      fi
    fi
    sleep 1
    (( elapsed++ )) || true
  done
  printf "\r\033[K" >&2   # clear the progress line, whatever its width
}

# Stop a progress bar started by _iperf3_progress and leave the line clean.
# The bar no longer self-terminates (FWK038/BUG0050), so `wait` on it would block
# until the hard-stop backstop -- it must be killed once its step is done.
_progress_stop() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  printf "\r\033[K" >&2
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

  # At most ONE record per (iteration, speed) — BUG0048.
  #
  # `trap - ERR` above does not do what it looks like it does. Most failures
  # happen inside command substitutions, and with `set -E` each substitution
  # subshell inherits its own copy of the trap; disarming it there leaves the
  # worker's copy armed, and the subshell exits immediately afterwards anyway.
  # A single unreachable link therefore fired the handler 32 times and appended
  # 32 identical ERROR entries to one 10 Mbps iteration, so summary.total counted
  # trap firings rather than tests. The marker file is the only state that
  # survives a subshell, so dedupe through the filesystem.
  local _why="unhandled command failure (exit ${_rc}) at line ${_ln}: ${_cmd}"
  echo "[ERROR] Pair ${pair_idx:-?} (${pair:-?}) ${_why}" >> "${pairlog:-/dev/null}" 2>/dev/null || true
  _main_log "[Pair ${pair_idx:-?}] ERROR — ${_why}" 2>/dev/null || true

  # Record the failure as a NOTE for this (iteration, speed), not as its own
  # result row — BUG0048 (dedupe) and BUG0055 (duplication).
  #
  # `trap - ERR` above does not do what it looks like it does. Most failures
  # happen inside command substitutions, and with `set -E` each substitution
  # subshell inherits its own copy of the trap; disarming it there leaves the
  # worker's copy armed, and the subshell exits immediately afterwards anyway.
  # A marker file is the only state that survives a subshell, so dedupe through
  # the filesystem.
  #
  # It must not append to .speeds[] directly either: the speed usually goes on to
  # complete and write its real record, and the report then showed the SAME speed
  # twice, once ERROR and once with the actual result, inflating "speed tests
  # run". The note is instead folded into that real record's reason; a note left
  # unclaimed means the worker really did die mid-speed, and the parent turns it
  # into an ERROR row after the join.
  if [[ -n "${pair_json:-}" ]]; then
    local _marker="${pair_json}.err.${_k:-0}.${_netspd:-0}"
    [[ -e "${_marker}" ]] && return 0
    printf '%s\n' "${_why}" > "${_marker}" 2>/dev/null || true
  fi
}

# Claim any _pair_abort note for this (iteration, speed) and print it, so the
# speed's real record can carry it. Consuming the note is what distinguishes
# "the step recovered" from "the worker died here" (BUG0055).
_claim_abort_note() {
  local _marker="${pair_json:-}/dev/null"
  [[ -n "${pair_json:-}" ]] || return 0
  _marker="${pair_json}.err.${_k:-0}.${_netspd:-0}"
  [[ -e "${_marker}" ]] || return 0
  head -n1 "${_marker}" 2>/dev/null || true
  rm -f "${_marker}" 2>/dev/null || true
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

  # Highest speed whose link actually came up, for this pair. Declared here so it
  # cannot leak between pairs and so `set -u` has something to read (BUG0062).
  local _last_linked_spd=""

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
  _speed_list="$(_supported_speeds "ns_${ev}" "${ev}")" || true
  [[ -z "${_speed_list}" ]] && _speed_list="10 100 1000 2500"

  # NET015: the pair's maximum link speed = highest speed BOTH NICs support.
  # _speed_list (from the even NIC) is ascending; the odd NIC's list is gathered
  # too, and the pair max is the greatest value common to both.
  local _odd_speed_list _pair_max_mbps=0 _even_max_mbps=0 _odd_max_mbps=0
  _odd_speed_list="$(_supported_speeds "ns_${od}" "${od}")" || true
  [[ -z "${_odd_speed_list}" ]] && _odd_speed_list="${_speed_list}"
  local _sp
  for _sp in ${_speed_list}; do
    (( _sp > _even_max_mbps )) && _even_max_mbps="${_sp}" || true
    # grep -qx against the list: the previous test was `grep -q " ${_sp} "` over
    # `echo " ${list} "`, but the list is NEWLINE-separated, so only its first and
    # last entries ever had an adjacent space -- and neither had both. Nothing
    # matched, and pair_max_mbps was reported as 0 on every run (BUG0052).
    if grep -qxF -- "${_sp}" <<<"${_odd_speed_list}" && (( _sp > _pair_max_mbps )); then
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
    # Wait for carrier instead of guessing (BUG0056). _link_note is empty when
    # both ends came up at the requested speed; otherwise it says what actually
    # happened, and the speed's reason leads with that rather than with the ICMP
    # failure it causes.
    local _link_note="" _lk_ev _lk_od _lk_rc_ev=0 _lk_rc_od=0
    _lk_ev="$(_wait_link_up "ns_${ev}" "${ev}" "${_netspd}")" || _lk_rc_ev=$?
    _lk_od="$(_wait_link_up "ns_${od}" "${od}" "${_netspd}")" || _lk_rc_od=$?
    local _lk_detail_ev _lk_detail_od
    _lk_detail_ev="$(_link_detail "ns_${ev}" "${ev}")"
    _lk_detail_od="$(_link_detail "ns_${od}" "${od}")"
    if (( _lk_rc_ev == 1 || _lk_rc_od == 1 )); then
      # Name the highest speed that DID establish, so "cannot do 400G" is
      # separable from "cannot do anything" without re-reading the whole log.
      _link_note="link did not come up at ${_netspd}M within ${_net_link_up_timeout_sec:-30}s (${ev}=${_lk_ev}, ${od}=${_lk_od}); highest speed established so far this run: ${_last_linked_spd:-none}. ${ev}: ${_lk_detail_ev} | ${od}: ${_lk_detail_od}"
    elif (( _lk_rc_ev == 2 || _lk_rc_od == 2 )); then
      _link_note="link came up at a different speed than requested ${_netspd}M (${ev}=${_lk_ev}M, ${od}=${_lk_od}M)"
    fi
    if [[ -z "${_link_note}" ]]; then
      _last_linked_spd="${_netspd}"
      echo "[INFO] link up at ${_netspd}M -- ${ev}: ${_lk_detail_ev} | ${od}: ${_lk_detail_od}" >> "${pairlog}"
    else
      echo "[WARN] ${_link_note}" >> "${pairlog}"
    fi

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
    # What the step should take on the WALL CLOCK, which is not --time (BUG0053).
    # --time governs only the measured transfer; --omit runs an extra warm-up
    # period on top of it, and each direction also pays connection setup and a
    # closing statistics exchange. Showing --time as the denominator made every
    # healthy transfer overrun and print "(still running)" -- a marker whose
    # whole purpose is to flag the ABNORMAL case, so firing it every time
    # destroys the signal it was added to carry.
    local _iperf_wall=$(( _iperf_time + _iperf_omit + ${_net_iperf_overhead_sec:-5} ))
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
      _iperf3_progress "P${pair_idx} BIDIR ${ev}<->${od} @${_netspd}M" "${_iperf_wall}" &
      _prog_pid=$!
      wait "${_bi_pid_f}" 2>/dev/null || true
      wait "${_bi_pid_r}" 2>/dev/null || true
      _progress_stop "${_prog_pid}"
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
    local _pct _thr_mbps _eff
    _pct="$(_tcp_pass_pct_for "${_netspd}")"
    # BUG0061: the threshold is a percentage of what the wire can actually
    # deliver as TCP payload, not of the raw line rate. Without the efficiency
    # term a 95% target is unreachable at MTU 1500, where the ceiling is 94.15%.
    _eff="$(_goodput_efficiency "${_net_mtu_for_thr:-1500}")"
    _thr_mbps=$(awk -v s="${_netspd}" -v p="${_pct}" -v e="${_eff}" \
                    'BEGIN{printf "%g", s*e*p/100}')

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
        _reason="TCP fwd ${n_tcp_fwd}M and rev ${n_tcp_rev}M both >= ${_thr_mbps}M (${_pct}% of the ${_eff} goodput ceiling on ${_netspd}M at MTU ${_net_mtu_for_thr:-1500})"
      else
        speed_verdict="FAIL"
        local _c=""
        if awk -v f="${n_tcp_fwd}" -v t="${_thr_mbps}" 'BEGIN{exit (f<t)?0:1}'; then
          _c="TCP fwd ${n_tcp_fwd}M < ${_thr_mbps}M threshold"
        fi
        if awk -v r="${n_tcp_rev}" -v t="${_thr_mbps}" 'BEGIN{exit (r<t)?0:1}'; then
          _c="${_c:+${_c}; }TCP rev ${n_tcp_rev}M < ${_thr_mbps}M threshold"
        fi
        _reason="FAIL: ${_c} (threshold ${_thr_mbps}M = ${_pct}% of the ${_eff} TCP goodput ceiling at MTU ${_net_mtu_for_thr:-1500}, on a ${_netspd}M link)"
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
    # NET017: UDP datagram loss above the configured cap annotates the reason
    # and, when _net_udp_loss_fail=1, fails an otherwise-PASS speed.
    #
    # Reported but not judged by default, deliberately. iperf3 offers UDP at the
    # full link rate with no flow control, so the receiver dropping a share of it
    # is the expected outcome of the test as configured, not evidence of a faulty
    # link -- double-digit percentages at 100G are routine. Gating on it by
    # default would turn every healthy high-speed run red.
    local _loss_worst
    _loss_worst="$(awk -v a="${_loss_fwd:-}" -v b="${_loss_rev:-}" \
      'BEGIN{x=(a==""?-1:a+0); y=(b==""?-1:b+0); print (x>y?x:y)}')"
    if awk -v w="${_loss_worst}" -v c="${_net_udp_loss_max_pct:-1}" \
         'BEGIN{exit (w>=0 && w>c)?0:1}'; then
      if [[ "${_net_udp_loss_fail:-0}" == "1" && "${speed_verdict}" == "PASS" ]]; then
        speed_verdict="FAIL"
        _reason="FAIL: UDP datagram loss ${_loss_fwd:-?}%/${_loss_rev:-?}% (fwd/rev) exceeds the ${_net_udp_loss_max_pct:-1}% cap"
      else
        _reason="${_reason}  [warning: UDP loss ${_loss_fwd:-?}%/${_loss_rev:-?}% fwd/rev exceeds the ${_net_udp_loss_max_pct:-1}% cap]"
      fi
    fi

    # NET018: a failed jumbo test annotates the reason (informational); SKIP
    # (NIC/driver does not support the configured MTU) is not an error.
    if [[ "${_jumbo_res}" != "null" && "${_jumbo_res}" != "\"PASS\"" && "${_jumbo_res}" != "\"SKIP\"" ]]; then
      _reason="${_reason}  [jumbo MTU ${_net_jumbo_mtu:-9000}: $(echo "${_jumbo_res}" | tr -d '\"')]"
    fi

    # BUG0055: if the ERR trap fired during this speed, carry its note here
    # instead of letting it become a second row for the same speed.
    local _abort_note
    _abort_note="$(_claim_abort_note)"
    [[ -n "${_abort_note}" ]] && _reason="${_reason}  [${_abort_note}]"
    # BUG0056: a down link explains every probe that failed after it, so it leads
    # the reason. Without this the row said "IPv4 ICMP FAIL" and the operator had
    # no way to tell an unsupported speed from a broken cable.
    [[ -n "${_link_note}" ]] && _reason="LINK: ${_link_note}  |  ${_reason}"

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
      --argjson loss_cap "$(_jnum "${_net_udp_loss_max_pct:-}")" \
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
                   udp_fwd_lost_pct: $loss_f, udp_rev_lost_pct: $loss_r,
                   udp_loss_max_pct: $loss_cap },
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
  test_heartbeat_phase "iteration ${_k}/${_mm}"

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
  _tmp="" _jq_tmp=""
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
    # An unclaimed _pair_abort note means the worker died inside that speed and
    # never wrote its real record, so nothing else will report it. Turn it into
    # the ERROR row it deserves — but only now, after the join, when "unclaimed"
    # is finally knowable (BUG0055).
    # NOT `local`: this loop runs at top level, and `local` outside a function is
    # a fatal error under `set -e` -- which is exactly how BUG0059 destroyed a
    # completed run's report.
    for _mk in "${_tmp}".err.*; do
      [[ -e "${_mk}" ]] || continue
      _mspd="${_mk##*.}"
      if [[ -f "${_tmp}" ]]; then
        _jq_tmp=$(jq --argjson speed "${_mspd:-0}" --arg reason "$(head -n1 "${_mk}")" \
          '.speeds += [{ speed_mbps:$speed, ipv4_ping:"N/A", ipv6_ping:"N/A",
             throughput:{tcp_fwd_mbps:0,tcp_rev_mbps:0,udp_fwd_mbps:0,udp_rev_mbps:0},
             verdict:"ERROR", reason:$reason }]' "${_tmp}" 2>/dev/null) \
          && printf '%s\n' "${_jq_tmp}" > "${_tmp}"
      fi
      rm -f "${_mk}" 2>/dev/null || true
    done
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
