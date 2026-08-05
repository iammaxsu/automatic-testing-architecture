#!/usr/bin/env bash
# function.sh ??hardened netns helpers for enp* pairs
# - Sanitize interface names
# - Bring links down + flush before moving
# - Move-back down/flush then up
# - Kill weird leftover namespace "ns_" and any empty file /run/netns/ns_
# - Verbose debug
set -Eeuo pipefail

export _function_api_version
: "${_function_api_version:="00.00.05"}"

# ---------- API version utilities ----------
_version_ge() {
  local IFS='.'
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    local x=$(( 10#${a[$i]:-0} )) y=$(( 10#${b[$i]:-0} ))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

# check_api_versions <script_name> <min_config_ver> <min_function_ver>
check_api_versions() {
  local caller="${1:?}" req_cfg="${2:?}" req_fn="${3:?}" ok=1
  _version_ge "${_config_api_version:-0.0.0}" "${req_cfg}" || {
    echo "FATAL: ${caller} requires config.sh >= ${req_cfg}  (installed: ${_config_api_version:-unset})" >&2
    echo "       Please update config.sh." >&2
    ok=0; }
  _version_ge "${_function_api_version:-0.0.0}" "${req_fn}" || {
    echo "FATAL: ${caller} requires function.sh >= ${req_fn}  (installed: ${_function_api_version:-unset})" >&2
    echo "       Please update function.sh." >&2
    ok=0; }
  [[ ${ok} -eq 1 ]] || exit 63
}

# ---------- Logging & timing ----------
now_ts() {
  date +"${_log_timestamp_format}"
}

run_time() {
  export _RUN_T0="$(date +%s)"
  # Also seed _session_t0 if no setup_session() was called (e.g. disk_test).
  # emit_result_json reads _session_t0 for execution.start / elapsed_seconds.
  : "${_session_t0:=${_RUN_T0}}"
  export _session_t0
}

elp_time() {
  if [[ $# -ge 2 ]]; then
    local start="$1" end="$2" sec=$(( end - start ))
    (( sec < 0 )) && sec=0
    printf "%02d:%02d:%02d\n" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
  else
    local t0 now sec
    if [[ -n "${_RUN_T0:-}" ]]; then t0="${_RUN_T0}"
    elif [[ -n "${_session_t0:-}" ]]; then t0="${_session_t0}"
    else return 0; fi
    now="$(date +%s)"; sec=$(( now - t0 )); (( sec < 0 )) && sec=0
    printf "Elapsed: %02d:%02d:%02d\n" $((sec/3600)) $(((sec%3600)/60)) $((sec%60))
  fi
}

# ---------- General CLI parameters: call parse_common_cli "$@" after sourcing ----------
# Support:
#   sticky | --sticky     : SESSION_POLICY=sticky
#   auto   | --auto       : SESSION_POLICY=auto (default)
#   -n | --force-new      : SESSION_FORCE_NEW=1
#   --session-id=ID       : specific session ID
#   --prefix=STR          : session prefix (default "session")
#   <number>              : loops count (default 1)
#   others                : preseve in REM_ARGS[]
parse_common_cli() {
  declare -ga REM_ARGS=()
  unset _target_loop

  while [[ $# -gt 0 ]]; do
    case "$1" in
      #sticky|--sticky)       export _session_policy="sticky"  ;;
      #auto|--auto)           export _session_policy="auto"    ;;
      #-n|--force-new)        export _session_force_new=1      ;;
      #--session-id=*)        export _session_id="${1#*=}"     ;;
      #--prefix=*)            export _session_prefix="${1#*=}" ;;
      # 1st number is the count of loops
      ''|*[!0-9]*)           REM_ARGS+=("$1") ;;      # non-number
      *)
        if [[ -z "${_target_loop:-}" ]]; then
          _target_loop="$1"
        else
          REM_ARGS+=("$1")
        fi
        ;;
    esac
    shift
  done

  : "${_target_loop:=1}"      # default: 1 loop
  #: "${_session_policy:=auto}"      # default policy
}

# ---------- Session directory & ID ----------
# Policy:
#   _session_policy=auto      (Default) Generate a new session ID when running the script. No persistence.
#   _session_policy=sticky      Share to read/write in <logs>/session_state/session.id. Reuse if exists.
# Control:
#   SESSION_FORCE_NEW=1   撘瑕??寞活嚗??? session.id ???
ensure_session_id() {
  : "${_session_prefix:=session}"
  : "${_session_policy:=sticky}"      # option: auto|sticky
  
  # Locate or create session state directory
  local _base="${_session_log_dir:-${_log_dir:-${_tool_path:-$PWD}/logs}}"
  : "${_session_state_dir:=${_base}/session_state}"
  mkdir -p -- "${_session_state_dir}" || { echo "[FATAL] mkdir ${_session_state_dir} failed"; return 1; }
  local _sid_file="${_session_state_dir}/session.id"

  # 0) Force new session
  if [[ "${_session_force_new:-0}" == "1" ]]; then
    unset _session_id
    rm -f -- "${_sid_file}" 2>/dev/null || true
  fi 

  # 1) If have session ID
  if [[ -n "${_session_id:-}" ]]; then
    _session_id="${_session_id}"
    # sticky mode: write to file
    if [[ "${_session_policy}" == "sticky" ]]; then
      printf '%s\n' "${_session_id}" > "${_sid_file}"
    fi
    export _session_id
    return 0
  fi

  case "${_session_policy}" in
    auto)     # Generate new session each time
      if [[ -z "${_session_id:-}" ]]; then
        _session_id="${_session_prefix}_$(now_ts)_$$"
      fi
      export _session_id
      return 0
      ;;

    sticky)   # Reuse session if possible
      if [[ -s "${_sid_file}" ]]; then
        read -r _session_id < "${_sid_file}"
      else
        _session_id="${_session_prefix}_$(now_ts)_$$"
        printf '%s\n' "${_session_id}" > "${_sid_file}"
      fi
      export _session_id
      return 0
      ;;

    *)
      echo "[WARN] Unknown SESSION_POLICY='${_session_policy}', fallback to 'auto'." >&2
      if [[ -z "${_session_id:-}" ]]; then
        _session_id="${_session_prefix}_$(now_ts)_$$"
      fi
      export _session_id
      return 0
      ;;
  esac
}

clear_session_id() {
  # Remove session ID file unless sticky mode.
  if [[ "${_session_policy:-auto}" != "sticky" ]]; then
    rm -f -- "${_session_state_dir:-}/session.id" 2>/dev/null || true
  fi
  unset _session_id
}

log_dir() {
#  local caller="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
#  local base_dir
#  base_dir="$(cd "$(dirname "$(readlink -f "${caller}")")" && pwd)"
#  export _tool_path="${_tool_path:-${base_dir}}"
#  export _log_dir="${_tool_path}/logs"
#  mkdir -p "${_log_dir}"
#  cd "${_log_dir}" || return 1
  local _caller="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"      # 1st parameter: caller script (default: caller of log_dir)
  local _use_session_dir="${2:-${LOGS_USE_SESSION_SUBDIR:-1}}"      # 2nd paramter: Use session subdir or not (default: 1). 
  local _root_override="${3:-}"     # 3rd parameter: override root path (default: auto-detect)

  local _base_dir
  _base_dir="$(cd "$(dirname "$(readlink -f "${_caller}")")" && pwd)"

  if [[ -n "${_root_override}" ]]; then
    _tool_path="$(readlink -f -- "${_root_override}")"
  else
    : "${_tool_path:=${_base_dir}}"
  fi
  export _tool_path

  : "${_log_dir:=${_tool_path}/logs}"
  : "${_session_log_dir:=${_log_dir}}"
  if [[ "${_use_session_dir}" == "1" ]]; then
    _session_log_dir="${_log_dir}/${_session_id:-pending}"
  fi

  mkdir -p -- "${_log_dir}" || { echo "[FATAL] mkdir ${_log_dir} failed"; return 1; }

  ensure_session_id || return 1

  if [[ "${_use_session_dir}" == "1" && "${_session_log_dir##*/}" == "pending" ]]; then
    _session_log_dir="${_log_dir}/${_session_id}"
  fi

  mkdir -p -- "${_session_log_dir}" || { echo "[FATAL] mkdir ${_session_log_dir} failed"; return 1;}

  # Restore log dir ownership to the login user (handles sudo-invoked runs).
  # shallow mode: only top-level and session dir, to keep this call fast.
  fix_log_permissions "${_log_dir}" "shallow"

  export _log_dir _session_log_dir
  echo "[INFO] log dir: ${_log_dir}"
  echo "[INFO] session log dir: ${_session_log_dir}"
  export _now_timestamp="$(now_ts)"
  printf '%s\n' "${_log_dir}"
}

# ---------- Fix log ownership & permissions ----------
# When scripts are run via sudo, logs/ and its contents become root-owned,
# which prevents the login user from opening html reports in Firefox
# (due to AppArmor/snap sandboxing) or copying them to Windows via SMB.
# This helper restores ownership to the original invoking user (SUDO_USER)
# and ensures everyone can read the files.
#
# Two modes:
#   shallow: only chown/chmod the top-level dirs (fast, called per-session)
#   deep:    recursively fix the whole tree (called at exit via trap)
fix_log_permissions() {
  local _target_dir="${1:-${_log_dir}}"
  local _mode="${2:-deep}"          # "shallow" or "deep" (default)
  [[ -d "${_target_dir}" ]] || return 0

  # Identify the original invoking user. SUDO_USER is set by sudo.
  local _real_user="${SUDO_USER:-${USER}}"
  local _real_group
  _real_group="$(id -gn "${_real_user}" 2>/dev/null || echo "${_real_user}")"

  # chown requires root. Skip silently if we're not root or user is already root.
  if [[ "$(id -u)" -eq 0 && -n "${_real_user}" && "${_real_user}" != "root" ]]; then
    if [[ "${_mode}" == "shallow" ]]; then
      # Only touch the top-level log dir and current session dir
      chown "${_real_user}:${_real_group}" "${_target_dir}" 2>/dev/null || true
      [[ -n "${_session_log_dir:-}" && -d "${_session_log_dir}" ]] && \
        chown "${_real_user}:${_real_group}" "${_session_log_dir}" 2>/dev/null || true
    else
      chown -R "${_real_user}:${_real_group}" "${_target_dir}" 2>/dev/null || true
    fi
  fi

  # a+rX: everyone can read; X adds +x only to directories (so we can cd into them).
  # Existing executable files keep their +x; regular log files stay as 644.
  if [[ "${_mode}" == "shallow" ]]; then
    chmod a+rX "${_target_dir}" 2>/dev/null || true
    [[ -n "${_session_log_dir:-}" && -d "${_session_log_dir}" ]] && \
      chmod a+rX "${_session_log_dir}" 2>/dev/null || true
  else
    chmod -R a+rX "${_target_dir}" 2>/dev/null || true
  fi
}

# ---------- loops arguement ----------
#parse_loops_arg() {
#  local _target_loops="${1:-1}"
#  if ! [[ "${_target_loops}" =~ ^[0-9]+$ ]] || [[ "${_target_loops}" -lt 1 ]]; then
#    echo "[FATAL] Invalid loop count: '${_target_loops}'. Using default: 1"
#    _target_loops=1
#  fi
#  export _bLoops="${_target_loops}"
#  echo "[INFO] Running ${_target_loops} time(s)"
#}

# ---------- Installers ----------
__is_debian_like() { [[ -f /etc/debian_version ]]; }
__is_redhat_like() { [[ -f /etc/redhat-release ]]; }

__pkg_install() {
  # 用法：__pkg_install pkg1 [pkg2 ...]
  local pkgs=("$@")
  if __is_debian_like; then
    if [[ "${_APT_UPDATED:-0}" != "1" ]]; then
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      _APT_UPDATED=1
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif __is_redhat_like; then
    if command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y "${pkgs[@]}"
    else
      sudo yum install -y "${pkgs[@]}"
    fi
  else
    echo "[WARN] Unknown distro; please install: ${pkgs[*]}" >&2
    return 1
  fi
}

fio_install()       { command -v fio       >/dev/null 2>&1 && return 0; __pkg_install fio; }
ethtool_install()   { command -v ethtool   >/dev/null 2>&1 && return 0; __pkg_install ethtool; }
iperf3_install()    { command -v iperf3    >/dev/null 2>&1 && return 0; __pkg_install iperf3; }
smartctl_install()  { command -v smartctl  >/dev/null 2>&1 && return 0; __pkg_install smartmontools; }
hdparm_install()    { command -v hdparm    >/dev/null 2>&1 && return 0; __pkg_install hdparm; }
jq_install()        { command -v jq        >/dev/null 2>&1 && return 0; __pkg_install jq; }

ensure_tools() {
  # 用法：ensure_tools smartctl hdparm iperf3
  local t
  for t in "$@"; do
    case "$t" in
      smartctl) smartctl_install >/dev/null 2>&1 || true ;;
      hdparm)   hdparm_install   >/dev/null 2>&1 || true ;;
      iperf3)   iperf3_install   >/dev/null 2>&1 || true ;;
      fio)      fio_install      >/dev/null 2>&1 || true ;;
      ethtool)  ethtool_install  >/dev/null 2>&1 || true ;;
      jq)       jq_install       >/dev/null 2>&1 || true ;;
      *) : ;;
    esac
  done
}

# ---------- iperf3 control ----------
iperf3_is_running() { pgrep -f '(^|/| )iperf3( |$)' >/dev/null 2>&1; }
iperf3_stop_all() {
  if iperf3_is_running; then
    echo "[INFO] iperf3 running -> SIGTERM"; sudo pkill -TERM -f '(^|/| )iperf3( |$)' 2>/dev/null || true; sleep 0.4
  fi
  if iperf3_is_running; then
    echo "[WARN] iperf3 still running -> SIGKILL"; sudo pkill -KILL -f '(^|/| )iperf3( |$)' 2>/dev/null || true; sleep 0.2
  fi
  iperf3_is_running && { echo "[ERR] iperf3 still running"; return 1; }
  echo "[INFO] iperf3 stopped"
}
iperf3_del() { iperf3_stop_all "$@"; }

prepare_net_tools() {
  if [[ "${FEATURE_USE_NEW_NET_TOOLING:-0}" == "1" ]]; then
    echo "[INFO] FeatureFlag ON: ensure ethtool/iperf3 installed & stop running iperf3"
    ethtool_install || { echo "[ERR] ethtool install failed"; return 1; }
    iperf3_install  || { echo "[ERR] iperf3 install failed";  return 1; }
    iperf3_stop_all || { echo "[ERR] iperf3 stop failed";     return 1; }
  else
    echo "[INFO] FeatureFlag OFF: legacy net preparation"
  fi
}

# ---------- Netns (interface set via _net_nic_name_regex, default enp*) ----------
unset _ethArray even_ethArray odd_ethArray skipped_ethArray excluded_ethArray excluded_reasonArray
declare -ga _ethArray even_ethArray odd_ethArray skipped_ethArray excluded_ethArray excluded_reasonArray

# NET019: MAC helpers for include/exclude-by-MAC NIC selection.
# Strip a single pair of surrounding quotes from a value. The config idiom
# `: "${var:='value'}"` keeps the inner quotes as literal characters (they are
# inside the outer double quotes), so a user who writes '^enp' or '00-..-56'
# would otherwise get quote-contaminated values. Be tolerant: strip them.
__strip_quotes() {
  local _s="$1"
  _s="${_s#[\"\']}"
  _s="${_s%[\"\']}"
  echo "${_s}"
}

# Normalize a MAC to lowercase, colon-separated, no spaces or stray quotes.
__norm_mac() {
  local _m="${1,,}"
  _m="${_m//-/:}"
  _m="${_m//[\'\" ]/}"
  echo "${_m}"
}

# Read a NIC's MAC (normalized). Empty string if unavailable.
__nic_mac() {
  local _if="$1" _mac=""
  [[ -r "/sys/class/net/${_if}/address" ]] && _mac="$(cat "/sys/class/net/${_if}/address" 2>/dev/null)"
  __norm_mac "${_mac}"
}

# Split a comma/semicolon/space-separated MAC list into a normalized array.
# Usage: __mac_split <out_array_name> "<list>"
__mac_split() {
  local -n _out="$1"; local _raw="$2"; local _tok
  _out=()
  _raw="${_raw//[,;]/ }"
  for _tok in ${_raw}; do
    _tok="$(__norm_mac "${_tok}")"
    [[ -n "${_tok}" ]] && _out+=("${_tok}")
  done
}

# Report NET019 list entries that match no NIC on this machine (BUG0047).
#
# The per-NIC "not in _net_include_macs" lines say what was REJECTED; they never
# say that a whitelist entry matched nothing. With two NICs whose MACs differ
# only in the last two octets, a one-character typo is invisible: the operator
# sees three rejections and has to diff every MAC by eye. Worse, if enough NICs
# still match, the run proceeds and silently tests a different pair than asked
# for. Name the unmatched entry, and point at the nearest MAC actually present.
#
# Usage: __mac_report_unmatched <label> <normalized-entry>...
__mac_report_unmatched() {
  local _label="$1"; shift
  (( $# > 0 )) || return 0
  local -a _sys_if=() _sys_mac=() _a _b
  local _p _ifn _m _e _i _o _diff _best_diff _best_if _best_mac

  for _p in /sys/class/net/*; do
    _ifn="${_p##*/}"
    [[ "${_ifn}" == "lo" ]] && continue
    _m="$(__nic_mac "${_ifn}")"
    [[ -n "${_m}" ]] || continue
    _sys_if+=("${_ifn}"); _sys_mac+=("${_m}")
  done
  (( ${#_sys_mac[@]} > 0 )) || return 0

  # A NIC already claimed by another entry in the same list is never the one the
  # operator meant by THIS entry, so it must not be offered as the suggestion.
  # Without this, two NICs from one card (…b4:48 and …b5:cf) are both one octet
  # away from a typo'd …b4:cf, and the tie would be broken arbitrarily — pointing
  # at the NIC that already works instead of the one that is missing.
  local -a _claimed=()
  for _i in "${!_sys_mac[@]}"; do
    if __mac_in_list "${_sys_mac[_i]}" "$@"; then _claimed[_i]=1; else _claimed[_i]=0; fi
  done

  local _ties
  for _e in "$@"; do
    __mac_in_list "${_e}" "${_sys_mac[@]}" && continue
    _best_diff=99; _ties=""
    IFS=':' read -ra _a <<<"${_e}"
    for _i in "${!_sys_mac[@]}"; do
      (( _claimed[_i] )) && continue
      IFS=':' read -ra _b <<<"${_sys_mac[_i]}"
      _diff=0
      for _o in 0 1 2 3 4 5; do
        [[ "${_a[_o]:-}" == "${_b[_o]:-}" ]] || (( _diff++ ))
      done
      if (( _diff < _best_diff )); then
        _best_diff=${_diff}; _ties="${_sys_if[_i]} (${_sys_mac[_i]})"
      elif (( _diff == _best_diff )); then
        # Still ambiguous after dropping claimed NICs — show every candidate
        # rather than guessing which one the operator meant.
        _ties="${_ties}, ${_sys_if[_i]} (${_sys_mac[_i]})"
      fi
    done
    echo "[WARN] ${_label} entry '${_e}' matches no NIC on this machine." >&2
    # Only suggest when it is close enough to be a plausible typo; the nearest of
    # six unrelated MACs is noise, not a hint.
    if (( _best_diff <= 2 )) && [[ -n "${_ties}" ]]; then
      echo "       Closest unclaimed NIC: ${_ties} — differs in ${_best_diff} octet(s). Typo?" >&2
    else
      echo "       No similar MAC present — check 'ip -o link show'." >&2
    fi
  done
}

# Is a normalized MAC present in a list of normalized MACs?
# Usage: __mac_in_list <needle> <mac>...
__mac_in_list() {
  local _needle="$1"; shift
  local _m
  [[ -z "${_needle}" ]] && return 1
  for _m in "$@"; do [[ "${_needle}" == "${_m}" ]] && return 0; done
  return 1
}

__sanitize_if() {
  # strip CR/LF and anything after '@' (e.g., vlan/master decorations)
  local in="$1"
  in="${in//$'\r'/}"; in="${in//$'\n'/}"
  in="${in%%@*}"
  # keep safe chars
  in="$(printf "%s" "$in" | sed 's/[^A-Za-z0-9_.:-]//g')"
  printf "%s" "$in"
}

__move_back_to_root() {
  # Split the declaration: `local ifn=... ns="ns_${ifn}"` would expand ${ifn}
  # before ifn is assigned, aborting under `set -u` (see _nic_err_snapshot).
  local ifn; ifn="$(__sanitize_if "$1")"
  local ns="ns_${ifn}"
  if ip netns list 2>/dev/null | grep -q -E "^${ns}\b"; then
    echo "[DEBUG] move-back ${ifn} from ${ns} -> root"
    sudo ip netns exec "${ns}" ip link set dev "${ifn}" down 2>/dev/null || true
    sudo ip netns exec "${ns}" ip addr flush dev "${ifn}" 2>/dev/null || true
    sudo ip netns exec "${ns}" ip link set "${ifn}" netns 1 2>/dev/null || true
    sudo ip link set dev "${ifn}" up 2>/dev/null || true
  fi
}

# ---------- Namespace Approach ----------
netns_del() {
  local found=0
  # delete literal stray ns_ first if present
  if ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "ns_"; then
    echo "[WARN] removing stray namespace 'ns_'"
    sudo ip netns del ns_ 2>/dev/null || true
  fi
  sudo rm -f /run/netns/ns_ 2>/dev/null || true

  # Clean up namespaces for any interface this test manages. The interface set is
  # configurable (_net_nic_name_regex), so match ns_<ifn> against the same pattern
  # rather than a hardcoded ns_enp* — otherwise ns_enx*/ns_eth* namespaces leak.
  local _nic_re; _nic_re="$(__strip_quotes "${_net_nic_name_regex:-^enp}")"; _nic_re="${_nic_re:-^enp}"
  while read -r ns; do
    [[ -z "$ns" ]] && continue
    [[ "$ns" == ns_* ]] || continue
    local ifn="${ns#ns_}"; ifn="$(__sanitize_if "$ifn")"
    [[ "$ifn" =~ $_nic_re ]] || continue
    found=1
    __move_back_to_root "${ifn}"
    sudo ip netns del "$ns" >/dev/null 2>&1 || true
    echo "[INFO] deleted $ns"
  done < <(ip netns list 2>/dev/null | awk '{print $1}')
  (( found )) || echo "[INFO] no managed namespaces (${_nic_re}) to delete"
  sleep 0.2
}

netns_add() {
  netns_del || true

  _ethArray=()
  excluded_ethArray=()
  excluded_reasonArray=()
  # Use ip -o to get single-line per link; sanitize names
  local _nic_re; _nic_re="$(__strip_quotes "${_net_nic_name_regex:-^enp}")"; _nic_re="${_nic_re:-^enp}"
  while IFS= read -r name; do
    name="$(__sanitize_if "$name")"
    [[ -n "$name" ]] && _ethArray+=("$name")
  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -E "${_nic_re}" | sort -n)

  local n=${#_ethArray[@]}
  echo "[DEBUG] root NICs (${_nic_re}): ${_ethArray[*]}"

  # NET011: filter out NICs explicitly excluded via --skip / _net_test_skip_nics
  if [[ -v _net_test_skip_nics ]] && (( ${#_net_test_skip_nics[@]} > 0 )); then
    local _filtered=()
    for _ifn in "${_ethArray[@]}"; do
      local _excluded=0
      for _excl in "${_net_test_skip_nics[@]}"; do
        [[ "${_ifn}" == "${_excl}" ]] && { _excluded=1; break; }
      done
      if (( _excluded )); then
        echo "[INFO] NIC '${_ifn}' excluded by --skip (NET011) — will not be tested."
        excluded_ethArray+=("${_ifn}")
        excluded_reasonArray+=("--skip flag (NET011)")
      else
        _filtered+=("${_ifn}")
      fi
    done
    _ethArray=("${_filtered[@]+"${_filtered[@]}"}")
    n=${#_ethArray[@]}
    echo "[DEBUG] After --skip filter: ${_ethArray[*]:-<none>}"
  fi

  # NET019: filter by MAC address — exclude (blacklist) then include (whitelist).
  # Precedence: _net_exclude_macs wins over _net_include_macs. Pinning the
  # management / SSH-lifeline NIC in _net_exclude_macs is also the NET012
  # protection mechanism, so it must never be overridden by an include entry.
  local -a _inc_macs=() _exc_macs=()
  local _have_inc=0 _have_exc=0
  [[ -n "${_net_include_macs:-}" ]] && { __mac_split _inc_macs "${_net_include_macs}"; (( ${#_inc_macs[@]} > 0 )) && _have_inc=1; }
  [[ -n "${_net_exclude_macs:-}" ]] && { __mac_split _exc_macs "${_net_exclude_macs}"; (( ${#_exc_macs[@]} > 0 )) && _have_exc=1; }
  if (( _have_inc || _have_exc )); then
    local _filtered2=() _mac _reason
    for _ifn in "${_ethArray[@]}"; do
      _mac="$(__nic_mac "${_ifn}")"
      _reason=""
      if (( _have_exc )) && __mac_in_list "${_mac}" "${_exc_macs[@]}"; then
        _reason="excluded by _net_exclude_macs (NET019)"
      elif (( _have_inc )) && ! __mac_in_list "${_mac}" "${_inc_macs[@]}"; then
        _reason="not in _net_include_macs (NET019)"
      fi
      if [[ -n "${_reason}" ]]; then
        echo "[INFO] NIC '${_ifn}' (${_mac:-no-mac}) ${_reason} — will not be tested."
        excluded_ethArray+=("${_ifn}")
        excluded_reasonArray+=("${_reason}")
      else
        _filtered2+=("${_ifn}")
      fi
    done
    _ethArray=("${_filtered2[@]+"${_filtered2[@]}"}")
    n=${#_ethArray[@]}
    echo "[DEBUG] After MAC filter (NET019): ${_ethArray[*]:-<none>}"
    # Warn unconditionally, not only when the run is about to abort: a typo that
    # still leaves >= 2 matching NICs would otherwise test the wrong pair without
    # a word (BUG0047).
    (( _have_inc )) && __mac_report_unmatched "_net_include_macs (whitelist)" "${_inc_macs[@]}"
    (( _have_exc )) && __mac_report_unmatched "_net_exclude_macs (blacklist)" "${_exc_macs[@]}"
  fi

  if (( n < 2 )); then
    echo "[FATAL] Need at least 2 testable NICs; found $n after filtering."
    echo "        NIC name pattern (_net_nic_name_regex): ${_nic_re}"
    [[ -n "${_net_include_macs:-}" ]] && echo "        _net_include_macs (whitelist): ${_net_include_macs}"
    [[ -n "${_net_exclude_macs:-}" ]] && echo "        _net_exclude_macs (blacklist): ${_net_exclude_macs}"
    if (( ${#excluded_ethArray[@]} > 0 )); then
      echo "        Excluded this run:"
      local _xi
      for _xi in "${!excluded_ethArray[@]}"; do
        echo "          - ${excluded_ethArray[_xi]} ($(__nic_mac "${excluded_ethArray[_xi]}")) : ${excluded_reasonArray[_xi]:-?}"
      done
    fi
    echo "        Hint: check the MACs above against the NICs actually present (ip -o link show),"
    echo "        and if your target NICs are USB (enx*) or other types, widen _net_nic_name_regex"
    echo "        (e.g. '^(enp|enx)') in config.sh."
    even_ethArray=(); odd_ethArray=(); skipped_ethArray=()
    return 1
  fi

  # ---------- Pairing: NIC[0]↔NIC[1], NIC[2]↔NIC[3], … ----------
  # Always pair from the front. If NIC count is odd, the last NIC has
  # no partner: store it in skipped_ethArray[] and print a warning.
  # The caller (net_test.sh) uses skipped_ethArray[] to emit N/A rows
  # in the summary so the unpaired NIC is still visible in the report.
  even_ethArray=(); odd_ethArray=(); skipped_ethArray=()
  local _active_n=$(( n - (n % 2) ))   # round down to nearest even number
  if (( n % 2 == 1 )); then
    skipped_ethArray+=("${_ethArray[n-1]}")
    echo "[WARN] Odd NIC count (${n} interfaces found)." \
         "'${_ethArray[n-1]}' has no pair and will be skipped." \
         "It will appear as N/A in the summary." >&2
  fi

  for (( i=0; i<_active_n; i+=2 )); do
    even_ethArray+=("${_ethArray[i]}")
    odd_ethArray+=("${_ethArray[i+1]}")
  done

  echo "[DEBUG] pairs (${#even_ethArray[@]}):"
  for (( i=0; i<${#even_ethArray[@]}; i++ )); do
    echo "[DEBUG]   Pair ${i}: ${even_ethArray[i]} <-> ${odd_ethArray[i]}"
  done
  (( ${#skipped_ethArray[@]} > 0 )) && \
    echo "[DEBUG] skipped (no pair): ${skipped_ethArray[*]}"

  # ---------- Move each paired NIC into its own namespace ----------
  for (( i=0; i<_active_n; i++ )); do
    local ifn="${_ethArray[i]}"
    local ns="ns_${ifn}"
    echo "[DEBUG] prepare ${ifn} -> ${ns}"
    sudo ip link set dev "${ifn}" down 2>/dev/null || true
    sudo ip addr flush dev "${ifn}" 2>/dev/null || true
    ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "${ns}" && sudo ip netns del "${ns}" || true
    sudo ip netns add "${ns}"
    if ! sudo ip link set "${ifn}" netns "${ns}"; then
      echo "[ERR] fail move ${ifn} into ${ns}"
      continue
    fi
    sleep 0.1
  done

  # ---------- Assign IPs ----------
  for ((i=0; i<${#even_ethArray[@]}; i++)); do
    echo "[DEBUG] address ${even_ethArray[i]} & ${odd_ethArray[i]}"
    sudo ip netns exec "ns_${even_ethArray[i]}" ip a add "192.247.${i}.1/24"   dev "${even_ethArray[i]}" || true
    sudo ip netns exec "ns_${even_ethArray[i]}" ip -6 a add "fd00:2470::${i}:1/64"  dev "${even_ethArray[i]}" || true
    sudo ip netns exec "ns_${even_ethArray[i]}" ip link set dev "${even_ethArray[i]}" up || true

    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip a add "192.247.${i}.11/24"  dev "${odd_ethArray[i]}"  || true
    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip -6 a add "fd00:2470::${i}:11/64" dev "${odd_ethArray[i]}" || true
    sudo ip netns exec "ns_${odd_ethArray[i]}"  ip link set dev "${odd_ethArray[i]}"  up || true
  done

  ip netns list
  echo "[INFO] netns created. even=[${even_ethArray[*]}] odd=[${odd_ethArray[*]}]"
}

netns_reset() {
  netns_del
  netns_add
}

# 小工具：紀錄到主 log
log() {
  echo "[$(date '+%F %T')] $*" | tee -a "${_disklog}";
}

# ---------- Batch counter (n/m) ----------
# 檔案位置：<logs>/session_state/counter.<name>
# 格式（shell 可 source）：
#   sid=session_20251009_...
#   m=10
#   n=3

counter_init() {
  local _name="${1:-net}"   # 1st parameter: counter name (default: "net")
  local _target="${2:-1}"   # 2nd parameter: target count (default: 1)

  # Put counter under global logs (not bound to session subdir)
  local _base="${_log_dir:-${_tool_path:-$PWD}/logs}"
  : "${_session_state_dir:=${_base}/session_state}"
  mkdir -p -- "${_session_state_dir}"

  _counter_name="${_name}"
  _counter_file="${_session_state_dir}/counter.${_counter_name}"

  # 讀現有 counter；同時支援舊鍵名 sid/m/n（自動轉成 _sid/_m/_n）
  local __sid="" __m="" __n=""     # 暫存（本地）
  local sid="" m="" n=""           # 舊版鍵名（相容用）    # shellcheck disable=SC1090,SC1091
  if [[ -s "${_counter_file}" ]]; then
     # shellcheck disable=SC1090,SC1091
    source "${_counter_file}" || true
    [[ -n "${_sid:-}" ]] && __sid="${_sid}"
    [[ -n "${_m:-}"   ]] && __m="${_m}"
    [[ -n "${_n:-}"   ]] && __n="${_n}"
    [[ -z "${_sid}" && -n "${sid}" ]] && _sid="${sid}"
    [[ -z "${_m}"   && -n "${m}"   ]] && _m="${m}"
    [[ -z "${_n}"   && -n "${n}"   ]] && _n="${n}"
  fi

  # If an unfinished counter exists, reuse its session id to avoid creating a new one
  if [[ -n "${__sid}" && -n "${__m}" && -n "${__n}" && "${__n}" -lt "${__m}" ]]; then
    export _session_id="${__sid}"
  fi

  # Build or reuse session ID (ensure_session_id respects preset _session_id)
  ensure_session_id

  # Reset conditions: no file / missing values / finished / mismatched session
  if [[ ! -s "${_counter_file}" || -z "${__sid}" || -z "${__m}" || -z "${__n}" || "${__n}" -ge "${__m}" || "${__sid}" != "${_session_id}" ]]; then
    __sid="${_session_id}"
    __m="${_target}"
    __n=0  
  fi

  # Persist (new keys with underscores) & export
  printf '_sid=%q\n_m=%q\n_n=%q\n' "${__sid}" "${__m}" "${__n}" > "${_counter_file}"
  _sid="${__sid}"; _m="${__m}"; _n="${__n}"

  # Debug
  echo "[DEBUG] counter_init: file=${_counter_file} _sid=${_sid} _n=${_n} _m=${_m}" >&2
}

# Return k/m (k = n+1)
counter_next_tag() {
  local __n="${_n:-0}" __m="${_m:-1}"
  local _k=$(( __n + 1 ))
  if (( _k > __m )); then
    _k="${__m}"
  fi
  printf '%d/%d' "${_k}" "${__m}"
}

counter_loops_this_run() {
  local _remain=$(( _m - _n ))
  local _want="${_target_loop:-1}"
  (( _remain < 0 )) && _remain=0
  (( _want < 1 )) && _want=1
  if (( _want < _remain )); then
    echo "${_want}"
  else
    echo "${_remain}"
  fi
}

# Call after each successful loop. n+1 if n >= m, end and cleaar the session.
counter_tick() {
  _n=$(( ${_n:-0} + 1 ))
  local __m="${_m:-1}"
  printf '_sid=%q\n_m=%q\n_n=%q\n' "${_session_id}" "${__m}" "${_n}" > "${_counter_file}"
  echo "[DEBUG] counter_tick:  file=${_counter_file} _sid=${_session_id} _n=${_n} _m=${__m}" >&2
  if [[ "${_n}" -ge "${__m}" ]]; then    # Done: clear the counter file & on-disk session.id.
    # NOTE: We deliberately do NOT unset the in-memory _session_id here —
    # callers (e.g. emit_result_json) need it after this point. The script
    # is about to exit anyway; next invocation gets a fresh process.
    # If a caller needs an explicit in-memory clear, call clear_session_id().
    rm -f -- "${_counter_file}" 2>/dev/null || true
    rm -rf -- "${_session_state_dir}/session.id" 2>/dev/null || true
  fi
}

# 回傳剩餘回合數（_m - _n），至少為 0
counter_remaining() {
  local __m="${_m:-0}" __n="${_n:-0}"
  if (( __m <= __n )); then
    echo 0
  else
    echo $(( __m - __n ))
  fi
}

# ---------- fio: assess whether the dev is NVMe or not ----------
fio_is_nvme() {
  [[ "$1" == /dev/nvme* ]]
}

# ---------- Return fio_tests array ----------
build_fio_tests_for_dev() {
  local _dev="$1"
  FIO_TESTS=()
  if fio_is_nvme "${_dev}"; then
    FIO_TESTS+=("${FIO_TESTS_NVME[@]}")
  else
    FIO_TESTS+=("${FIO_TESTS_SATA[@]}")
  fi
}

# ---------- Return summary pattern for dev ----------
build_fio_summary_patterns_for_dev() {
  local dev="$1"
  SUMMARY_PATTERNS=()
  if [[ "$dev" == /dev/nvme* ]]; then
    SUMMARY_PATTERNS=("${FIO_SUMMARY_NVME[@]}")
  else
    SUMMARY_PATTERNS=("${FIO_SUMMARY_SATA[@]}")
  fi
}

# ---------- USB helpers (reusable by detect_usb / detect_storage) ----------

# 由 block 裝置名 (e.g. sda) 找到對應的 USB sysfs 節點路徑；回傳空字串代表不是 USB。
usb_sysnode_for_block() {
  # usage: usb_sysnode_for_block sda
  local name="$1" sys cur
  sys="/sys$(udevadm info -q path -n "/dev/${name}" 2>/dev/null || true)"
  [[ -z "$sys" ]] && return 1
  cur="$sys"
  while [[ -n "$cur" && "$cur" != "/" ]]; do
    # USB 裝置節點通常會有 /speed 與 /busnum /devnum
    if [[ -f "$cur/speed" && -f "$cur/busnum" && -f "$cur/devnum" ]]; then
      printf '%s\n' "$cur"; return 0
    fi
    cur="$(dirname "$cur")"
  done
  return 1
}

# 讀取目前連線速率 (Mb/s)；回傳數字（如 480/5000/10000/20000），失敗回 "?"
usb_current_speed_mbps() {
  # usage: usb_current_speed_mbps /sys/bus/usb/devices/1-3/...
  local node="$1" v
  if [[ -r "$node/speed" ]]; then
    v="$(tr -d $'\r\n' < "$node/speed")"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '?\n'
}

# 讀取 USB bcdUSB（裝置宣稱的 USB 版本），例如 2.00 / 3.20；失敗回 "?"
usb_bcd_version() {
  local node="$1" v
  if [[ -r "$node/version" ]]; then
    v="$(tr -d $'\r\n' < "$node/version")"
    [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '?\n'
}

# Mb/s → 人類可讀（支援小數）
usb_fmt_speed() {
  # usage: usb_fmt_speed 5000   -> "5 Gb/s"
  #        usb_fmt_speed 1.5    -> "1.5 Mb/s"
  local mbps="$1"

  # 空值或問號直接回傳
  [[ -z "${mbps:-}" || "${mbps}" == "?" ]] && { echo "?"; return; }

  # 必須是數字（允許小數）
  if [[ ! "$mbps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "?"
    return
  fi

  # 用 awk 做浮點比較與格式化（避免 [[ -ge ]] 的整數限制）
  awk -v x="$mbps" 'BEGIN{
    if (x >= 1000) { printf "%.0f Gb/s", x/1000.0 }
    else           { printf "%g Mb/s",  x }
  }'
}

# 從 lsusb 解析 *宣稱支援* 的 SuperSpeedPlus 模式（Gen 1x1/2x1/2x2…），回「逗號分隔的列表」。
# 需要 busnum/devnum；抓不到就回空字串。
usb_supported_gens_from_lsusb() {
  # usage: usb_supported_gens_from_lsusb 001 005
  local bus="$1" dev="$2" out modes
  command -v lsusb >/dev/null 2>&1 || { echo ""; return 0; }
  out="$(lsusb -s "${bus}:${dev}" -v 2>/dev/null || true)"
  [[ -z "$out" ]] && { echo ""; return 0; }

  # 解析 SuperSpeedPlus 區段的支援模式行（不同版本 lsusb 字樣略有差異）
  modes="$(printf '%s\n' "$out" \
    | awk '
      /SuperSpeedPlus USB Device Capability/ {ss=1; next}
      ss && /Supported operating modes/ {so=1; next}
      ss && so {
        if ($0 ~ /^[[:space:]]*$/) exit
        g=$0; sub(/^[[:space:]]*/,"",g); sub(/[[:space:]]*$/,"",g)
        # 常見輸出例： "Gen 2x1", "Gen 1x2", "Gen 2x2"
        if (g ~ /^Gen [0-9]+x[0-9]+$/) { print g }
      }
    ' \
    | paste -sd', ' -)"
  echo "$modes"
}

# 將 Gen NxM 映射為速率文字（粗略對照：Gen1=5Gb/s, Gen2=10Gb/s；Nx2 ≈ *2）
usb_gen_to_speed_label() {
  # usage: usb_gen_to_speed_label "Gen 2x2" -> "20 Gb/s"
  local g="$1" n m base
  n="$(printf '%s' "$g" | sed -n 's/Gen \([0-9]\+\)x\([0-9]\+\)/\1/p')"
  m="$(printf '%s' "$g" | sed -n 's/Gen \([0-9]\+\)x\([0-9]\+\)/\2/p')"
  [[ -z "$n" || -z "$m" ]] && { echo "?"; return; }
  # Gen1 ~= 5, Gen2 ~= 10（實際還有編碼差異，這裡取常見名義速率即可）
  if [[ "$n" -eq 1 ]]; then base=5
  elif [[ "$n" -eq 2 ]]; then base=10
  elif [[ "$n" -eq 3 ]]; then base=20   # USB4/3.2 Gen3 名義 20
  else base=$((n*5))
  fi
  echo "$((base*m)) Gb/s"
}

# 匯總：輸入 USB sysfs 節點 → 印一行概要：Current, bcdUSB, SupportedModes
usb_summarize_node() {
  local node="$1"
  local cur_mbps="" cur_human="" ver=""
  local bus="" dev=""
  local gens="" gen_speeds="" t s
  local -a arr=()

  cur_mbps="$(usb_current_speed_mbps "$node")"
  cur_human="$(usb_fmt_speed "$cur_mbps")"
  ver="$(usb_bcd_version "$node")"

  if [[ -r "$node/busnum" && -r "$node/devnum" ]]; then
    bus="$(tr -d $'\r\n' < "$node/busnum")"
    dev="$(tr -d $'\r\n' < "$node/devnum")"
    gens="$(usb_supported_gens_from_lsusb "$bus" "$dev")" || gens=""
  fi

  # 把 gens 轉成速率說明
  if [[ -n "$gens" ]]; then
    IFS=',' read -r -a arr <<<"$gens"
    for t in "${arr[@]}"; do
      t="$(echo "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      s="$(usb_gen_to_speed_label "$t")"
      if [[ -z "$gen_speeds" ]]; then
        gen_speeds="${t}(${s})"
      else
        gen_speeds="${gen_speeds}, ${t}(${s})"
      fi
    done
    printf 'Current=%s  bcdUSB=%s  Supported=%s\n' "$cur_human" "${ver}" "$gen_speeds"
  else
    printf 'Current=%s  bcdUSB=%s\n' "$cur_human" "${ver}"
  fi
}

# 由 lsusb 的 Bus/Device 反查對應的 USB 裝置 sysfs 節點（整數化比較，避免 001 vs 1 對不上）
usb_sysnode_from_bus_dev() {
  local bus_raw="$1" dev_raw="$2"
  # 轉成十進位整數（去前導 0）
  local bus dev fb fd p base
  bus=$((10#$bus_raw))
  dev=$((10#$dev_raw))

  for p in /sys/bus/usb/devices/*; do
    [[ -r "$p/busnum" && -r "$p/devnum" ]] || continue
    fb=$(tr -d $'\r\n' < "$p/busnum" 2>/dev/null || echo "")
    fd=$(tr -d $'\r\n' < "$p/devnum"  2>/dev/null || echo "")
    # 也把檔案內容整數化
    [[ -n "$fb" && -n "$fd" ]] || continue
    fb=$((10#$fb))
    fd=$((10#$fd))
    if (( fb == bus && fd == dev )); then
      base="$(basename "$p")"
      printf '/sys/bus/usb/devices/%s\n' "${base%%:*}"
      return 0
    fi
  done
  return 1
}

# 列出某個 Hub 的所有連接埠；逐埠顯示 Connected/Not Connected
# usage: usb_list_hub_ports <bus> <dev>
usb_list_hub_ports() {
  local bus="$1" dev="$2" node="" base="" prefix="" sep="" ports="" i child child_node
  node="$(usb_sysnode_from_bus_dev "$bus" "$dev" 2>/dev/null || true)" || node=""
  [[ -z "$node" ]] && return 1

  # 取得埠數（bNbrPorts）
  if command -v lsusb >/dev/null 2>&1; then
    ports="$(lsusb -s "${bus}:${dev}" -v 2>/dev/null | awk '/^[[:space:]]*bNbrPorts[[:space:]]/{print $2; exit}')"
  fi
  [[ -z "$ports" ]] && ports=0

  base="$(basename "$node")"
  if [[ "$base" == usb* ]]; then
    # root hub：prefix 是 bus 編號（usb1 -> "1"），子節點長 "1-1", "1-2"
    prefix="${base#usb}"
    sep="-"
  else
    # 外接 hub：prefix 是自身節點名（如 "1-3"），子節點長 "1-3.1", "1-3.2"
    prefix="$base"
    sep="."
  fi

  for (( i=1; i<=ports; i++ )); do
    child="${prefix}${sep}${i}"
    child_node="/sys/bus/usb/devices/${child}"
    if [[ -d "$child_node" ]]; then
      # 有裝置接在該埠
      printf "  Port %-2d : Connected  " "$i"
      usb_summarize_node "$child_node"
    else
      printf "  Port %-2d : Not Connected\n" "$i"
    fi
  done
}

# ---------- PCIe link helpers (shared by detect_pcie_ethernet / detect_storage) ----------

# 由 block 名稱 (e.g. nvme0n1) 回推 PCIe BDF（走 /sys）
pcie_bdf_from_block() {
  local name="$1" p
  p="$(readlink -f "/sys/block/${name}/device" 2>/dev/null || true)"
  while [[ -n "$p" && "$p" != "/" ]]; do
    case "$(basename "$p")" in
      ????\:??\:??\.[0-7]) printf '%s\n' "$(basename "$p")"; return 0 ;;
    esac
    p="$(dirname "$p")"
  done
  return 1
}

# 從 BDF 讀取 LnkCap/LnkSta 與 ASPM（mawk/BusyBox 友善；set -u 安全）
pcie_link_info() {
  # usage: pcie_link_info 0000:3b:00.0
  local bdf="${1:-}" dump cap_line sta_line ctl_line cap_s="" cap_w="" sta_s="" sta_w="" aspm=""
  [[ -z "$bdf" ]] && { echo "||||"; return 1; }
  dump="$(LANG=C lspci -vv -s "$bdf" 2>/dev/null || true)"
  [[ -z "$dump" ]] && { echo "||||"; return 1; }

  cap_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCap:' || true)"
  sta_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkSta:' || true)"
  ctl_line="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*LnkCtl:' || true)"

  # 例如：LnkCap: Port #0, Speed 16GT/s, Width x4, ASPM not supported
  [[ -n "$cap_line" ]] && cap_s="$(printf '%s\n' "$cap_line" | sed -n 's/.*Speed \([^,]*\),.*/\1/p')"
  [[ -n "$cap_line" ]] && cap_w="$(printf '%s\n' "$cap_line" | sed -n 's/.*Width x\([0-9]\+\).*/\1/p')"
  # 例如：LnkSta: Speed 8GT/s (ok), Width x4 (ok)
  [[ -n "$sta_line" ]] && sta_s="$(printf '%s\n' "$sta_line" | sed -n 's/.*Speed \([^,]*\).*/\1/p')"
  [[ -n "$sta_line" ]] && sta_w="$(printf '%s\n' "$sta_line" | sed -n 's/.*Width x\([0-9]\+\).*/\1/p')"
  # ASPM：不同平台出現在 LnkCtl 或 LnkCap 註記裡，盡力抓一個可讀狀態
  if [[ -n "$ctl_line" ]]; then
    aspm="$(printf '%s\n' "$ctl_line" | sed -n 's/.*ASPM[[:space:]]*\([^,;)]*\).*/\1/p')"
  fi
  if [[ -z "$aspm" && -n "$cap_line" ]]; then
    aspm="$(printf '%s\n' "$cap_line" | sed -n 's/.*ASPM[[:space:]]*\([^,;)]*\).*/\1/p')"
  fi

  [[ -z "$cap_s"  ]] && cap_s="?"
  [[ -z "$cap_w"  ]] && cap_w="?"
  [[ -z "$sta_s"  ]] && sta_s="?"
  [[ -z "$sta_w"  ]] && sta_w="?"
  [[ -z "$aspm"   ]] && aspm="?"

  printf '%s|%s|%s|%s|%s\n' "$cap_s" "$cap_w" "$sta_s" "$sta_w" "$aspm"
}

# ---------- SATA helpers (shared) ----------
# 從 smartctl 解析「SATA 版本 與 協商速率」；抓不到回 "?|?"
_sata_proto_speed_from_smartctl() {
  local dev="$1" line="" proto="" speed=""
  line="$(smartctl -i "$dev" 2>/dev/null | grep -m1 -i 'SATA Version' || true)"
  if [[ -n "$line" ]]; then
    # 例：SATA Version is: SATA 3.3, 6.0 Gb/s (current: 6.0 Gb/s)
    proto="$(printf '%s\n' "$line" | sed -n 's/.*SATA Version[^:]*:[[:space:]]*\([^,]*\).*/\1/p')"
    speed="$(printf '%s\n' "$line" | sed -n 's/.*\([0-9]\+\(\.[0-9]\+\)\?[[:space:]]*Gb\/s\).*/\1/p')"
  fi
  [[ -z "$proto" ]] && proto="?"
  [[ -z "$speed" ]] && speed="?"
  printf '%s|%s\n' "$proto" "$speed"
}

# 內部：優先無 sudo，失敗再 sudo -n，最後 sudo（都靜默）
_hdparm_try() {  # $1=-i|-I  $2=/dev/sdX
  local mode="$1" dev="$2"
  hdparm "$mode" "$dev" 2>/dev/null \
  || sudo -n hdparm "$mode" "$dev" 2>/dev/null \
  || sudo hdparm "$mode" "$dev" 2>/dev/null
}

# 從 hdparm / smartctl 解析「已啟用的 UDMA 模式」
_sata_udma_mode() {
  local dev="$1" udma="" line=""

  if command -v hdparm >/dev/null 2>&1; then
    # A1) 先試 -I 的「DMA: ... *udmaN」同一行（你的機器是這種）
    udma="$(_hdparm_try -I "$dev" \
           | tr -d '\r' \
           | sed -n 's/.*DMA:.*\*\(udma[0-9]\+\).*/\1/p')" || true

    # A2) 抓不到再掃 -I 的「UDMA modes:」區塊（有些機器長這樣）
    if [[ -z "$udma" ]]; then
      udma="$(_hdparm_try -I "$dev" \
             | tr -d '\r' \
             | sed -n '/UDMA[[:space:]]*modes:/,/^[[:space:]]*$/p' \
             | tr '\n' ' ' \
             | sed -n 's/.*UDMA[[:space:]]*modes:[^*]*\*\(udma[0-9]\+\).*/\1/p')" || true
    fi

    # B) 再抓不到，改用 -i（舊式「UDMA modes: ... *udmaN」）
    if [[ -z "$udma" ]]; then
      udma="$(_hdparm_try -i "$dev" \
             | tr -d '\r' \
             | sed -n 's/.*UDMA[[:space:]]*modes:[[:space:]]*.*\*\(udma[0-9]\+\).*/\1/p')" || true
    fi
  fi

  # C) 最後以 smartctl 備援（"UDMA Mode: udma6"）
  if [[ -z "$udma" ]] && command -v smartctl >/dev/null 2>&1; then
    line="$(smartctl -i "$dev" 2>/dev/null | tr -d '\r' | grep -m1 -i 'UDMA Mode' || true)"
    [[ -n "$line" ]] && udma="$(printf '%s\n' "$line" | sed -n 's/.*UDMA[[:space:]]*Mode:[[:space:]]*\([^ ]*\).*/\1/p')" || true
  fi

  [[ -z "$udma" ]] && udma="?"
  printf '%s\n' "$udma"
}

# 一次匯總：輸入 /dev/sdX → 回傳 "proto|link|udma"
sata_summarize_dev() {
  local dev="$1"
  local proto="?" link="?" udma="?" line p l gen dump

  # 0) 最優先：從 sysfs ata_link 讀取「目前協商速度」(current negotiated link speed)
  #    路徑：/sys/class/ata_link/link<N>/sata_spd
  #    這是核心直接記錄的實際速度，不受 smartctl / hdparm 字串解析影響。
  local _sysfs_speed=""
  local _syspath _ata_num _spd_file
  _syspath="$(udevadm info -q path -n "$dev" 2>/dev/null || true)"
  if [[ -n "$_syspath" ]]; then
    _ata_num="$(printf '%s\n' "$_syspath" | grep -oE 'ata[0-9]+' | head -n1 | tr -dc '0-9')"
    if [[ -n "$_ata_num" ]]; then
      _spd_file="/sys/class/ata_link/link${_ata_num}/sata_spd"
      [[ -r "$_spd_file" ]] && _sysfs_speed="$(tr -d '[:space:]' < "$_spd_file")"
    fi
  fi
  # sata_spd 格式如 "6.0 Gbps" 或 "3.0 Gbps"；正規化成 "6.0 Gb/s"
  if [[ -n "$_sysfs_speed" && "$_sysfs_speed" != "unknown" ]]; then
    link="$(printf '%s\n' "$_sysfs_speed" \
            | sed -E 's/([0-9]+\.[0-9]+)[[:space:]]?[Gg]bps?/\1 Gb\/s/')"
    # 從 current speed 反推 proto（避免 smartctl 誤報 SATA 1.x）
    case "$link" in
      1.5\ Gb/s)  proto="SATA 1.x" ;;
      3.0\ Gb/s)  proto="SATA 2.x" ;;
      6.0\ Gb/s)  proto="SATA 3.x" ;;
      12.0\ Gb/s) proto="SATA 4.x" ;;
    esac
  fi

  # 1) smartctl：只用來補 proto（不覆蓋已從 sysfs 拿到的 link speed）
  if [[ "$proto" == "?" ]] && command -v smartctl >/dev/null 2>&1; then
    line="$(smartctl -i "$dev" 2>/dev/null | grep -m1 -i 'SATA Version' || true)"
    if [[ -n "$line" ]]; then
      p="$(printf '%s\n' "$line" | sed -n 's/.*SATA Version[^:]*:[[:space:]]*\([^,]*\).*/\1/p')"
      [[ -n "$p" ]] && proto="$p"
      # 若 sysfs 也沒拿到 link，才從 smartctl 的 current 欄位補
      if [[ "$link" == "?" ]]; then
        # 優先抓 "current: X.X Gb/s" 括號內的值
        l="$(printf '%s\n' "$line" | sed -n 's/.*current:[[:space:]]*\([0-9.]\+[[:space:]]*Gb\/s\).*/\1/p')"
        # 退而求其次取行末第一個速率
        [[ -z "$l" ]] && l="$(printf '%s\n' "$line" \
            | sed -n 's/.*\([0-9]\+\(\.[0-9]\+\)\?[[:space:]]*Gb\/s\).*/\1/p')"
        [[ -n "$l" ]] && link="$(printf '%s\n' "$l" | sed -E 's/([0-9])\s*(Gb\/s)/\1 \2/')"
      fi
    fi
  fi

  # 2) 若 link 仍未知，用 hdparm -I GenX signaling speed 補
  if [[ "$link" == "?" ]] && command -v hdparm >/dev/null 2>&1; then
    local hl gennum rate
    hl="$(_hdparm_try -I "$dev" | tr -d '\r' \
          | sed -n 's/.*Gen\([0-9]\+\)[^()]*(\([0-9.]\+[[:space:]]*Gb\/s\)).*/\1|\2/p' | head -n1)"
    if [[ -n "$hl" ]]; then
      gennum="${hl%%|*}"; rate="${hl##*|}"
      rate="$(printf '%s\n' "$rate" | sed -E 's/([0-9])\s*(Gb\/s)/\1 \2/')"
      link="$rate"
      [[ "$proto" == "?" ]] && case "$gennum" in
        1) proto="SATA 1.x" ;; 2) proto="SATA 2.x" ;;
        3) proto="SATA 3.x" ;; 4) proto="SATA 4.x" ;;
      esac
    fi
  fi

  # 3) 最後備援：udev ID_ATA_SATA_SIGNAL_RATE_GENx
  if [[ "$link" == "?" ]] && command -v udevadm >/dev/null 2>&1; then
    dump="$(udevadm info -q property -n "$dev" 2>/dev/null || true)"
    if printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA=1$'; then
      if   printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN3=1$'; then gen=3
      elif printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN2=1$'; then gen=2
      elif printf '%s\n' "$dump" | grep -q '^ID_ATA_SATA_SIGNAL_RATE_GEN1=1$'; then gen=1
      fi
      if [[ -n "${gen:-}" ]]; then
        case "$gen" in
          1) link="1.5 Gb/s" ;; 2) link="3.0 Gb/s" ;;
          3) link="6.0 Gb/s" ;; 4) link="12.0 Gb/s" ;;
        esac
        [[ "$proto" == "?" ]] && proto="SATA 3.x"
      fi
    fi
  fi

  # 4) UDMA
  udma="$(_sata_udma_mode "$dev")"

  printf '%s|%s|%s\n' "${proto:-?}" "${link:-?}" "${udma:-?}"
}

_sata_rate_for_gen() {
  # $1 = 1|2|3|…  回 1.5 Gb/s | 3.0 Gb/s | 6.0 Gb/s（未知回 ?）
  case "$1" in
    1) echo "1.5 Gb/s" ;;
    2) echo "3.0 Gb/s" ;;
    3) echo "6.0 Gb/s" ;;
    4) echo "12.0 Gb/s" ;;  # SATA 4.0（少見，預留）
    *) echo "?" ;;
  esac
}

# ---------- sleep capability detection ----------
# 解析 /sys/power/state 與 dmesg 的 ACPI (supports Sx)
sleep_detect_support() {
  local state_line="" acpi_line=""
  local S3=0 S4=0 S5=0
  [[ -r /sys/power/state ]] && state_line="$(</sys/power/state)" || state_line=""
  acpi_line="$(dmesg | grep -i 'ACPI: (supports' | tail -n1 || true)"
  # mem => S3, disk => S4
  grep -qw mem  <<<"${state_line}" && S3=1
  grep -qw disk <<<"${state_line}" && S4=1
  # 多數機器有 S5；若 dmesg 明載 S5 就以之為準，否則預設 1
  if grep -q 'S5' <<<"${acpi_line}"; then S5=1; else S5=1; fi
  printf '%d %d %d\n' "$S3" "$S4" "$S5"
}

# --- systemd helpers (robust, single source of truth) ---

# 依腳本檔名產生建議的 service 名稱：dev_detect.sh -> dev-detect
autorun_service_name_for() {
  local entry="${1:?}" base
  base="$(basename "$entry")"; base="${base%.*}"; base="${base//_/-}"
  echo "${base}"
}

# 單元檔是否存在
sysd_unit_exists() {
  local name="${1:?}"
  [[ -e "/etc/systemd/system/${name}.service" ]] || systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -qx "${name}.service"
}

# 是否已啟用
sysd_is_enabled() {
  local name="${1:?}"
  systemctl is-enabled --quiet "${name}.service" 2>/dev/null
}

# 安裝/啟用 oneshot 服務（僅在「不存在」或「未啟用」時動作；不做 start）
# 用法：sysd_install_boot_task <name> <workdir> <exec> <logfile>
sysd_install_boot_task() {
  local name="${1:?}"; local workdir="${2:?}"; local exec="${3:?}"; local logfile="${4:?}"

  if ! sysd_unit_exists "${name}"; then
    sudo tee "/etc/systemd/system/${name}.service" >/dev/null <<UNIT
[Unit]
Description=${name} (run once per boot until done)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=${workdir}
ExecStartPre=/usr/bin/mkdir -p $(dirname "${logfile}")
StandardOutput=append:${logfile}
StandardError=append:${logfile}
ExecStart=/usr/bin/env bash -lc '${exec}'

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable "${name}.service" >/dev/null 2>&1
  else
    if ! sysd_is_enabled "${name}"; then
      sudo systemctl enable "${name}.service" >/dev/null 2>&1
    fi
  fi
}

# 停用（完成後呼叫）
sysd_disable_boot_task() {
  local name="${1:?}"
  sudo systemctl disable --now "${name}.service" >/dev/null 2>&1 || true
}

# 依 counter 狀態決定是否停用
autorun_disable_if_done() {
  local cname="${1:?}" svc="${2:?}"
  local base="${_log_dir:-${_tool_path:-$PWD}/logs}"
  # Prefer the EXACT counter file that counter_init cached this run. Recomputing
  # the path from _log_dir can point at a different file than where the counter
  # was actually written (counter_init caches _session_state_dir, and it may run
  # before log_dir()), so relying on the recomputed path alone silently read an
  # empty counter → __m=0 → the service was never disabled and dev_detect re-ran
  # every boot (BUG0038). Fall back to the recomputed path only if unset.
  local cfile="${_counter_file:-${base}/session_state/counter.${cname}}"
  local __m=0 __n=0
  if [[ -s "$cfile" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$cfile" || true
    __m="${_m:-${m:-0}}"; __n="${_n:-${n:-0}}"
  fi
  if (( __n >= __m && __m > 0 )); then
    sysd_disable_boot_task "$svc" || true
    return 0
  fi
  return 1
}

# 第一次手動執行時自動「安裝＋啟用」自己（不 start；等下次開機跑）
# 用法：autorun_install_self_if_needed <counter_name> <target_m> <entry_fullpath> [args...]
autorun_install_self_if_needed() {
  local cname="${1:?}" target="${2:?}" entry="${3:?}"; shift 3
  local svc; svc="$(autorun_service_name_for "$entry")"
  if ! sysd_is_enabled "$svc"; then
    local workdir exec logfile
    workdir="$(cd "$(dirname "$entry")" && pwd)"
    # 使用絕對路徑：避免 bash -lc 在 Ubuntu Server login shell 改變 CWD 導致 status=127
    exec="$(printf '%s %s %s' "$entry" "$target" "$*")"
    logfile="${workdir}/logs/systemd_${svc}.log"
    sysd_install_boot_task "$svc" "$workdir" "$exec" "$logfile"
    # 不要在這裡 start，避免同一個 boot 跑兩次
  fi
}

# 服務是否正在執行中
sysd_is_active() {
  local name="${1:?}"
  systemctl is-active --quiet "${name}.service" 2>/dev/null
}

# ---------- autorun_setup / autorun_uninstall ----------
#
# autorun_setup  — 取代手動執行 install_dev_detect.sh
# 行為：
#   Case A (fresh OS / service 不存在)：自動安裝 + enable（等下次開機自動跑）
#   Case B (service 已安裝並 enabled)：跳過安裝，直接繼續 script 其他流程
#   兩個 case 都不做 systemctl start，避免同一個 boot 執行兩次
#
# 用法：autorun_setup <counter_name> <target_m> <entry_fullpath> [args...]
autorun_setup() {
  local cname="${1:?}" target="${2:?}" entry="${3:?}"; shift 3
  local svc; svc="$(autorun_service_name_for "$entry")"

  if sysd_is_enabled "$svc"; then
    local active
    if sysd_is_active "$svc"; then active="running"; else active="inactive"; fi
    echo "[INFO] Service ${svc}.service already installed and enabled (active=${active}). Skipping install."
  else
    echo "[INFO] Service ${svc}.service not found. Installing..."
    local workdir exec logfile
    workdir="$(cd "$(dirname "$entry")" && pwd)"
    exec="$(printf '%s %s %s' "$entry" "$target" "$*")"
    logfile="${workdir}/logs/systemd_${svc}.log"
    sysd_install_boot_task "$svc" "$workdir" "$exec" "$logfile"
    if sysd_unit_exists "$svc" && sysd_is_enabled "$svc"; then
      echo "[INFO] Service ${svc}.service installed and enabled. Will run automatically on next boot."
    else
      echo "[WARN] Service ${svc}.service install may have failed. Check sudo permissions."
    fi
  fi
}

# autorun_uninstall — 取代手動執行 uninstall_dev_detect.sh
# 停止、disable、移除 service unit 檔，並清除 counter/session
# 用法：autorun_uninstall <entry_fullpath>
autorun_uninstall() {
  local entry="${1:?}"
  local svc; svc="$(autorun_service_name_for "$entry")"

  if ! sysd_unit_exists "$svc"; then
    echo "[INFO] Service ${svc}.service not found. Nothing to uninstall."
    return 0
  fi

  echo "[INFO] Uninstalling ${svc}.service..."
  sudo systemctl stop    "${svc}.service" 2>/dev/null || true
  sudo systemctl disable "${svc}.service" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${svc}.service"
  sudo systemctl daemon-reload

  local base="${_log_dir:-${_tool_path:-$PWD}/logs}"
  local state_dir="${base}/session_state"
  rm -f -- "${state_dir}/counter.dev" 2>/dev/null || true
  rm -f -- "${state_dir}/session.id"  2>/dev/null || true

  echo "[INFO] Service ${svc}.service uninstalled."
}

# ---------- DUT test-environment mutations (reversible) ----------
#
# 為了「測試」而對 DUT 做的環境改動，一律成對提供 apply / restore，讓
# setup_dut.sh（套用）與 restore 入口（還原）共用同一份邏輯，不再各自
# 手刻、不再有名稱/行為不一致的問題。
#
# 範圍原則：
#   - 屬於「為單次測試而暫時改變使用者日常行為」的設定（電源鍵、合蓋、
#     睡眠、idle）→ 納入，測完必須能完整還原。
#   - 讓自動框架本身能運作的基礎設施（Pi SSH 公鑰、NOPASSWD sudoers、
#     dev-detect autorun）→ 不屬於此範圍，由各自的生命週期管理，restore
#     不會動它們。
#
# 這些函式假設呼叫者具 root 權限（setup_dut.sh 與 restore 入口都有
# FWK033 root 檢查）。每個函式回傳 0；是否實際變更以 echo 訊息呈現。

TEST_ENV_LOGIND_DROPIN="/etc/systemd/logind.conf.d/99-automatic-testing.conf"
TEST_ENV_SLEEP_TARGETS="sleep.target suspend.target hibernate.target hybrid-sleep.target"

# 清掉舊版本曾直接寫進 /etc/systemd/logind.conf 的測試用 key（migration）。
# 回傳：有刪到任何一行 → 0，否則 → 1
_test_env_logind_strip_inline() {
  local conf="/etc/systemd/logind.conf" k changed=1
  local keys=(HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked
              HandleSuspendKey HandleHibernateKey IdleAction
              HandlePowerKey HandlePowerKeyLongPress)
  for k in "${keys[@]}"; do
    if grep -qE "^${k}=" "$conf" 2>/dev/null; then
      sed -i "/^${k}=/d" "$conf"; changed=0
    fi
  done
  return "$changed"
}

# 套用 logind 測試設定：電源鍵直接 poweroff（繞過 GNOME 互動關機，
# 避免 HANG_SHUTDOWN）、合蓋/睡眠/休眠鍵/idle 一律 ignore。
# 全部寫進單一 drop-in 檔，不動主 logind.conf。
test_env_logind_apply() {
  local dropin="${TEST_ENV_LOGIND_DROPIN}" changed=0
  mkdir -p "$(dirname "$dropin")"
  _test_env_logind_strip_inline && changed=1

  cat > "${dropin}.tmp" <<'LOGIND'
# Managed by automatic-testing-architecture.
# Apply  : test_env_logind_apply   (setup_dut.sh)
# Restore: test_env_logind_restore  (setup_dut.sh --restore)
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
HandlePowerKey=poweroff
HandlePowerKeyLongPress=poweroff
LOGIND

  if [[ -f "$dropin" ]] && diff -q "${dropin}.tmp" "$dropin" >/dev/null 2>&1; then
    rm -f "${dropin}.tmp"
  else
    mv "${dropin}.tmp" "$dropin"; changed=1
  fi

  if (( changed )); then
    systemctl restart systemd-logind >/dev/null 2>&1 || true
    echo "[test-env] logind: applied (HandlePowerKey=poweroff; lid/suspend/idle=ignore)"
  else
    echo "[test-env] logind: already current — no change"
  fi
  return 0
}

# 還原 logind：刪除 drop-in 並清掉任何殘留的 inline key，restart logind。
test_env_logind_restore() {
  local dropin="${TEST_ENV_LOGIND_DROPIN}" changed=0
  if [[ -e "$dropin" ]]; then
    rm -f "$dropin"; changed=1
    echo "[test-env] logind: drop-in removed (${dropin})"
  else
    echo "[test-env] logind: no drop-in present"
  fi
  _test_env_logind_strip_inline && changed=1
  if (( changed )); then
    systemctl restart systemd-logind >/dev/null 2>&1 || true
    echo "[test-env] logind: restored to system defaults"
  fi
  return 0
}

# mask 睡眠相關 target（避免 DUT 在 ON_TIME 進入低耗電被誤判為 CRASH）。
test_env_sleep_mask() {
  # shellcheck disable=SC2086
  systemctl mask ${TEST_ENV_SLEEP_TARGETS} >/dev/null 2>&1 || true
  echo "[test-env] sleep/suspend/hibernate/hybrid-sleep targets masked"
  return 0
}

# unmask 睡眠相關 target。
test_env_sleep_unmask() {
  # shellcheck disable=SC2086
  systemctl unmask ${TEST_ENV_SLEEP_TARGETS} >/dev/null 2>&1 || true
  echo "[test-env] sleep/suspend/hibernate/hybrid-sleep targets unmasked"
  return 0
}

# 聚合還原：把所有「為測試而做的暫時改動」改回來。restore 入口（setup_dut.sh
# --restore，或測試完成後由 Pi 透過 SSH 呼叫）只需呼叫這一個函式。
test_env_restore_all() {
  echo "[test-env] Restoring DUT test-environment changes…"
  test_env_logind_restore
  test_env_sleep_unmask
  echo "[test-env] Done. Framework infrastructure (SSH key, sudoers, dev-detect) left in place."
  return 0
}

# ---------- Test progress notification ----------
# 同時通知三個管道：
#   1. terminal（進度條格式，含 ETA）
#   2. SSH 登入 MOTD（每次登入都顯示）
#   3. X-Window 桌面（notify-send + zenity 視窗，可選）
#
# 用法：
#   test_progress_set <script_name> <n> <m>   # 每個 loop 開始時呼叫
#   test_progress_clear                        # 全部完成後呼叫

_ADLINK_STATUS_FILE="/var/run/adlink_test_status"
_ADLINK_MOTD_SCRIPT="/etc/update-motd.d/98-adlink-test"
_ADLINK_XWIN_PID_FILE="/var/run/adlink_test_xwin.pid"

_adlink_bar() {
  # _adlink_bar <n> <m> <width>  →  "[######      ] n/m"
  local n="$1" m="$2" w="${3:-40}"
  local filled=$(( n * w / m ))
  local empty=$(( w - filled ))
  local bar=""; local i
  for (( i=0; i<filled; i++ )); do bar+="#"; done
  for (( i=0; i<empty;  i++ )); do bar+=" "; done
  printf '[%s] %d/%d' "$bar" "$n" "$m"
}

_adlink_eta() {
  # _adlink_eta <n> <m> : return estimated remaining seconds based on elapsed time
  local n="$1" m="$2"
  local elapsed=$(( $(date +%s) - ${_session_t0:-$(date +%s)} ))
  (( n <= 0 )) && { echo "?"; return; }
  local per_loop=$(( elapsed / n ))
  local remain=$(( (m - n) * per_loop ))
  if   (( remain >= 3600 )); then printf '%dh %02dm' $(( remain/3600 )) $(( (remain%3600)/60 ))
  elif (( remain >= 60   )); then printf '%dm %02ds' $(( remain/60 )) $(( remain%60 ))
  else printf '%ds' "$remain"; fi
}

_adlink_find_display() {
  # Find active X display and XAUTHORITY for notification
  local display="" xauth="" pid
  for pid in $(pgrep -x Xorg 2>/dev/null || pgrep -x X 2>/dev/null || pgrep -x Xwayland 2>/dev/null || true); do
    display=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep '^DISPLAY=' | head -1 | cut -d= -f2)
    [[ -n "$display" ]] && break
  done
  [[ -z "$display" ]] && display=":0"
  for home in /home/*/; do
    [[ -f "${home}.Xauthority" ]] && { xauth="${home}.Xauthority"; break; }
  done
  echo "${display}|${xauth}"
}

test_progress_set() {
  local script="${1:?}" n="${2:?}" m="${3:?}"
  local ts bar eta msg sep
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  bar="$(_adlink_bar "$n" "$m" 40)"
  eta="$(_adlink_eta "$n" "$m")"
  sep="=============================================="
  printf -v msg '\n%s\n  !! TEST IN PROGRESS — DO NOT POWER OFF !!\n%s\n  Script  : %s\n  Progress: %s  ETA: %s\n  Updated : %s\n%s\n' \
    "$sep" "$sep" "$script" "$bar" "$eta" "$ts" "$sep"

  # 1) Write status file
  echo "${msg}" | sudo tee "${_ADLINK_STATUS_FILE}" >/dev/null 2>&1 || \
    echo "${msg}" > "${_ADLINK_STATUS_FILE}" 2>/dev/null || true

  # 2) Install MOTD hook (once)
  if [[ ! -f "${_ADLINK_MOTD_SCRIPT}" ]]; then
    { printf '#!/bin/sh\n[ -f "%s" ] && cat "%s"\n' \
        "${_ADLINK_STATUS_FILE}" "${_ADLINK_STATUS_FILE}"; } \
      | sudo tee "${_ADLINK_MOTD_SCRIPT}" >/dev/null 2>&1 || true
    sudo chmod +x "${_ADLINK_MOTD_SCRIPT}" 2>/dev/null || true
  fi

  # 3) Broadcast to active terminals
  echo "${msg}" | wall 2>/dev/null || true

  # 4) X-Window: try notify-send first, then zenity persistent window
  local dpy_info dpy xauth pct title body
  dpy_info="$(_adlink_find_display)"
  dpy="${dpy_info%%|*}"; xauth="${dpy_info##*|}"
  pct=$(( n * 100 / m ))
  title="Test in progress — DO NOT POWER OFF"
  body="${script}  ${bar}  ETA: ${eta}"

  local _xenv="DISPLAY=${dpy}"
  [[ -n "$xauth" ]] && _xenv="${_xenv} XAUTHORITY=${xauth}"

  # notify-send (brief popup — always try)
  env ${_xenv} notify-send -u critical -t 8000 \
      "${title}" "${body}" 2>/dev/null || true

  # Kill previous zenity window if any
  local _prev_pid=""
  [[ -f "${_ADLINK_XWIN_PID_FILE}" ]] && _prev_pid="$(cat "${_ADLINK_XWIN_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${_prev_pid}" ]] && kill "${_prev_pid}" 2>/dev/null || true

  # Launch new zenity progress window (stays on desktop until replaced/cleared)
  if command -v zenity >/dev/null 2>&1; then
    ( echo "${pct}"; sleep 86400 ) \
      | env ${_xenv} zenity --progress \
          --title="${title}" \
          --text="${body}" \
          --percentage="${pct}" \
          --no-cancel \
          --auto-close \
          2>/dev/null &
    echo $! | sudo tee "${_ADLINK_XWIN_PID_FILE}" >/dev/null 2>&1 || \
      echo $! > "${_ADLINK_XWIN_PID_FILE}" 2>/dev/null || true
  fi
}

test_progress_clear() {
  local done_msg="${1:-All tests completed. Safe to power off.}"
  local sep="=============================================="
  local msg; printf -v msg '\n%s\n  %s\n%s\n' "$sep" "$done_msg" "$sep"

  # Kill zenity window
  local _prev_pid=""
  [[ -f "${_ADLINK_XWIN_PID_FILE}" ]] && _prev_pid="$(cat "${_ADLINK_XWIN_PID_FILE}" 2>/dev/null || true)"
  [[ -n "${_prev_pid}" ]] && kill "${_prev_pid}" 2>/dev/null || true

  sudo rm -f "${_ADLINK_STATUS_FILE}" "${_ADLINK_MOTD_SCRIPT}" "${_ADLINK_XWIN_PID_FILE}" 2>/dev/null || true
  echo "${msg}" | wall 2>/dev/null || true

  # X-Window completion notification
  local dpy_info dpy xauth _xenv
  dpy_info="$(_adlink_find_display)"
  dpy="${dpy_info%%|*}"; xauth="${dpy_info##*|}"
  _xenv="DISPLAY=${dpy}"
  [[ -n "$xauth" ]] && _xenv="${_xenv} XAUTHORITY=${xauth}"
  env ${_xenv} notify-send -u normal -t 10000 \
      "Test complete" "${done_msg}" 2>/dev/null || true
}

# 是否已完成（回 1）或未完成（回 0）
counter_is_done() {
  local __m="${_m:-0}" __n="${_n:-0}"
  (( __n >= __m && __m > 0 )) && echo 1 || echo 0
}

# ---------- Standby capability detection ----------
# 回傳三個數字：S3 S4 S5（1=支援, 0=不支援）
# 依據 /sys/power/state 與 dmesg 的 "ACPI: (supports Sx)"。
standby_detect_support() {
  local state_line="" acpi_line=""
  local S3=0 S4=0 S5=0

  if [[ -r /sys/power/state ]]; then
    state_line="$(</sys/power/state)"   # 可能含：freeze standby mem disk
  fi
  acpi_line="$(dmesg | grep -i 'ACPI: (supports' | tail -n1 || true)"  # 例如：ACPI: (supports S0 S3 S4 S5)

  # mem => S3；disk => S4
  grep -qw mem  <<<"${state_line}" && S3=1
  grep -qw disk <<<"${state_line}" && S4=1

  # S5 幾乎都支援；若 dmesg 明講 S5 就用它，否則預設 1
  if grep -q 'S5' <<<"${acpi_line}"; then
    S5=1
  else
    S5=1
  fi

  printf '%d %d %d\n' "$S3" "$S4" "$S5"
}

# ---------- dev_detect HTML report generator ----------
# 用法：generate_dev_detect_report <session_dir> [output_html]
# 掃描 session_dir 裡的 dev_detect_*_of_*_*.log 與 snapshot*.txt，
# 產生含折線圖（boot interval）與 result table 的 self-contained HTML。
generate_dev_detect_report() {
  local session_dir="${1:?session_dir required}"
  local out="${2:-${session_dir}/dev_detect_report_$(date +%Y%m%d%H%M%S).html}"

  local host kernel session_id
  host="$(hostname)"
  kernel="$(uname -r)"
  session_id="$(basename "${session_dir}")"

  # ---- parse result log files ----
  declare -A _ts   # k -> epoch
  declare -A _res  # k -> Pass|Fail|INIT
  declare -A _dif  # k -> diff text (escaped, newlines replaced with ~)
  local m_total=0

  while IFS= read -r f; do
    local base result m_val k_val tmp
    base="$(basename "$f")"
    result="${base##*_}"; result="${result%.log}"
    tmp="${base%_*}"; m_val="${tmp##*_}"
    tmp="${tmp%_*}"; tmp="${tmp%_*}"; k_val="${tmp##*_}"
    [[ "$k_val" =~ ^[0-9]+$ && "$m_val" =~ ^[0-9]+$ ]] || continue
    _res[$k_val]="${result}"
    (( m_val > m_total )) && m_total=$m_val
    if [[ "${result}" == "Fail" ]]; then
      for df in "${session_dir}/"*"diff_${k_val}_of_"*".diff"; do
        [[ -f "$df" ]] || continue
        _dif[$k_val]="$(head -40 "$df" | sed 's/</\&lt;/g; s/>/\&gt;/g; s/\\/\\\\/g; s/"/\\"/g' | tr '\n' '~')"
        break
      done
    fi
  done < <(find "${session_dir}" -maxdepth 1 -name 'dev_detect_*_of_*_*.log' | sort)

  # ---- parse snapshot timestamps ----
  while IFS= read -r f; do
    local base run_ts k_val epoch tmp2
    base="$(basename "$f")"
    run_ts="${base%.txt}"; run_ts="${run_ts##*_}"
    tmp2="${base%_*}"; tmp2="${tmp2%_*}"; tmp2="${tmp2%_*}"; k_val="${tmp2##*_}"
    [[ "$k_val" =~ ^[0-9]+$ && "${run_ts}" =~ ^[0-9]{14}$ ]] || continue
    epoch=$(date -d "${run_ts:0:8} ${run_ts:8:2}:${run_ts:10:2}:${run_ts:12:2}" +%s 2>/dev/null \
            || date -j -f "%Y%m%d%H%M%S" "${run_ts}" +%s 2>/dev/null || echo "")
    [[ -n "$epoch" ]] && _ts[$k_val]="$epoch"
  done < <(find "${session_dir}" -maxdepth 1 -name 'dev_detect_snapshot_*_of_*.txt' | sort)

  # fallback: file mtime
  for k_val in $(seq 1 "$m_total"); do
    [[ -n "${_ts[$k_val]:-}" ]] && continue
    for f in "${session_dir}/"*"_${k_val}_of_"*".log" \
             "${session_dir}/"*"snapshot_${k_val}_of_"*".txt"; do
      [[ -f "$f" ]] || continue
      local mt; mt=$(stat -c "%Y" "$f" 2>/dev/null || stat -f "%m" "$f" 2>/dev/null || echo "")
      [[ -n "$mt" ]] && { _ts[$k_val]="$mt"; break; }
    done
  done

  [[ $m_total -eq 0 ]] && { echo "[WARN] generate_report: no result logs in ${session_dir}"; return 1; }

  # ---- total test duration (first ts → last ts) ----
  local t_first="" t_last="" total_time_str="?"
  for k_val in $(seq 1 "$m_total"); do
    local ts_v="${_ts[$k_val]:-}"
    [[ -z "$ts_v" ]] && continue
    [[ -z "$t_first" || "$ts_v" -lt "$t_first" ]] && t_first="$ts_v"
    [[ -z "$t_last"  || "$ts_v" -gt "$t_last"  ]] && t_last="$ts_v"
  done
  if [[ -n "$t_first" && -n "$t_last" ]]; then
    local elapsed_s=$(( t_last - t_first ))
    total_time_str="$(printf '%02dh %02dm %02ds' \
      $(( elapsed_s/3600 )) $(( (elapsed_s%3600)/60 )) $(( elapsed_s%60 )))"
  fi

  # ---- compute intervals & statistics ----
  local -a iv_vals=()
  local prev_ts=""
  for k in $(seq 1 "$m_total"); do
    local ts="${_ts[$k]:-}"
    [[ -z "$ts" || -z "$prev_ts" ]] && { prev_ts="$ts"; continue; }
    local iv=$(( ts - prev_ts )); (( iv < 0 )) && iv=0
    iv_vals+=("$iv")
    prev_ts="$ts"
  done

  local mean=0 thr=9999
  if (( ${#iv_vals[@]} > 0 )); then
    mean=$(awk -v a="${iv_vals[*]}" \
           'BEGIN{n=split(a,v," ");s=0;for(i=1;i<=n;i++)s+=v[i];print s/n}')
    thr=$(awk -v a="${iv_vals[*]}" -v m="$mean" \
          'BEGIN{n=split(a,v," ");s=0;for(i=1;i<=n;i++)s+=(v[i]-m)^2;printf "%.0f",m+2*sqrt(s/n)}')
  fi

  # ---- build JS arrays ----
  local labels="" intervals="" pt_colors="" pt_r="" rows_js=""
  local pass=0 fail=0 outliers=0
  prev_ts=""
  for k in $(seq 1 "$m_total"); do
    local ts="${_ts[$k]:-}" result="${_res[$k]:-unknown}" diff="${_dif[$k]:-}"
    local iv_str="null" iv_num=0
    if [[ -n "$ts" && -n "$prev_ts" ]]; then
      iv_num=$(( ts - prev_ts )); (( iv_num < 0 )) && iv_num=0; iv_str="$iv_num"
    fi
    local is_out=0
    if [[ "$iv_str" != "null" ]]; then
      awk -v v="$iv_num" -v t="$thr" 'BEGIN{exit (v>t)?0:1}' && is_out=1 && (( outliers++ )) || true
    fi
    [[ "$result" == "Pass" ]] && (( pass++ )) || true
    [[ "$result" == "Fail" ]] && (( fail++ )) || true
    local color; [[ $is_out -eq 1 ]] && color="#BA7517" || color="#378ADD"
    local pr;    [[ $is_out -eq 1 ]] && pr=6 || pr=3
    local ts_disp=""
    [[ -n "$ts" ]] && ts_disp=$(date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                              || date -r "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts")
    [[ -n "$labels"    ]] && labels+=","    ; labels+="$k"
    [[ -n "$intervals" ]] && intervals+=","  ; intervals+="${iv_str}"
    [[ -n "$pt_colors" ]] && pt_colors+=","  ; pt_colors+="\"${color}\""
    [[ -n "$pt_r"      ]] && pt_r+=","      ; pt_r+="${pr}"
    [[ -n "$rows_js"   ]] && rows_js+=","
    rows_js+="{k:${k},ts:\"${ts_disp}\",iv:${iv_str},result:\"${result}\",out:${is_out},diff:\"${diff}\"}"
    [[ -n "$ts" ]] && prev_ts="$ts"
  done

  # ---- write HTML (self-contained, no external deps except CDN Chart.js) ----
  cat > "${out}" <<HTMLEOF
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>dev_detect report — ${session_id}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;
     color:#222;background:#f5f5f0;padding:1.5rem}
h1{font-size:18px;font-weight:500;margin-bottom:4px}
.meta{font-size:12px;color:#666;margin-bottom:1.5rem}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:1.5rem}
.card{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:.75rem 1rem}
.card .lbl{font-size:11px;color:#888;margin-bottom:4px}
.card .val{font-size:24px;font-weight:500}
.ok{color:#1D9E75}.warn{color:#BA7517}.err{color:#E24B4A}.info{color:#185FA5}
.sec{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:1rem 1.25rem;margin-bottom:1rem}
.sec h2{font-size:12px;font-weight:500;color:#666;text-transform:uppercase;
        letter-spacing:.04em;margin-bottom:.6rem}
.cw{position:relative;width:100%;height:240px}
.leg{display:flex;gap:14px;font-size:12px;color:#666;margin-bottom:8px}
.leg span{display:flex;align-items:center;gap:5px}
.dot{width:10px;height:10px;border-radius:2px;display:inline-block}
table{width:100%;border-collapse:collapse;font-size:12px}
th{font-weight:500;color:#666;text-align:left;padding:6px 10px;
   border-bottom:1px solid #eee;white-space:nowrap}
td{padding:5px 10px;border-bottom:.5px solid #f0f0f0;vertical-align:top}
tr:hover td{background:#fafaf8}
tr.fr td{background:#fff8f8}
tr.or td{background:#fffbf4}
.b{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:500}
.Pass{background:#EAF3DE;color:#3B6D11}.Fail{background:#FCEBEB;color:#A32D2D}
.INIT{background:#E6F1FB;color:#185FA5}.unknown{background:#F1EFE8;color:#5F5E5A}
.ob{background:#FAEEDA;color:#854F0B}
pre{background:#f8f8f8;border:.5px solid #ddd;border-radius:4px;padding:8px;font-size:11px;
    overflow-x:auto;max-height:180px;margin-top:4px;white-space:pre}
.da{color:#3B6D11}.dd{color:#A32D2D}
details summary{cursor:pointer;font-size:12px;color:#185FA5}
@media(max-width:600px){.cards{grid-template-columns:repeat(2,1fr)}}
@media print{body{background:#fff;padding:0}.sec{break-inside:avoid}}
</style></head><body>
<h1>dev_detect report</h1>
<p class="meta">Host: ${host} &nbsp;|&nbsp; Kernel: ${kernel} &nbsp;|&nbsp; Session: ${session_id}</p>
<div class="cards" style="grid-template-columns:repeat(5,1fr)">
<div class="card"><div class="lbl">Total loops</div><div class="val info">${m_total}</div></div>
<div class="card"><div class="lbl">Pass</div><div class="val ok">${pass}</div></div>
<div class="card"><div class="lbl">Fail</div><div class="val err">${fail}</div></div>
<div class="card"><div class="lbl">Outlier intervals</div><div class="val warn">${outliers}</div></div>
<div class="card"><div class="lbl">Total test time</div><div class="val" style="font-size:16px;padding-top:4px">${total_time_str}</div></div>
</div>
<div class="sec"><h2>Boot interval per loop (seconds)</h2>
<div class="leg">
<span><span class="dot" style="background:#378ADD"></span>Interval (s)</span>
<span><span class="dot" style="background:#BA7517"></span>Outlier (&gt;mean+2&sigma;)</span>
<span><span class="dot" style="background:#E24B4A;width:2px;height:14px;border-radius:0"></span>Fail</span>
</div>
<div class="cw"><canvas id="ch" role="img" aria-label="Boot interval line chart">Boot interval per loop.</canvas></div></div>
<div class="sec"><h2>Loop results</h2>
<table><thead><tr>
<th>Loop</th><th>Timestamp</th><th>Interval</th><th>Result</th><th>Notes</th>
</tr></thead><tbody id="tb"></tbody></table></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
<script>
const LB=[${labels}],IV=[${intervals}],PC=[${pt_colors}],PR=[${pt_r}];
const THR=${thr},MEAN=Math.round(${mean});
const ROWS=[${rows_js}];
new Chart(document.getElementById('ch'),{type:'line',data:{labels:LB,datasets:[
  {label:'Interval',data:IV,borderColor:'#378ADD',borderWidth:1.5,tension:.3,spanGaps:true,
   pointBackgroundColor:PC,pointRadius:PR,pointHoverRadius:7},
  {label:'Threshold',data:LB.map(()=>THR),borderColor:'#BA7517',borderWidth:1,
   borderDash:[5,4],pointRadius:0,pointHoverRadius:0}
]},options:{responsive:true,maintainAspectRatio:false,
  plugins:{legend:{display:false},tooltip:{callbacks:{label:c=>{
    if(c.datasetIndex===1)return 'Threshold: '+THR+'s (mean '+MEAN+'s + 2\u03c3)';
    const r=ROWS[c.dataIndex];
    return 'Loop '+r.k+': '+(r.iv===null?'first boot':r.iv+'s')+' ['+r.result+']'+(r.out?' \u2191outlier':'');
  }}}},
  scales:{x:{ticks:{font:{size:11},autoSkip:true,maxTicksLimit:20}},
          y:{title:{display:true,text:'seconds',font:{size:11}},ticks:{font:{size:11}},min:0}}}});
const tb=document.getElementById('tb');
ROWS.forEach(r=>{
  const tr=document.createElement('tr');
  if(r.result==='Fail')tr.className='fr'; else if(r.out)tr.className='or';
  const notes=[];
  if(r.out)notes.push('<span class="b ob">outlier</span>');
  if(r.diff){
    const d=r.diff.replace(/~/g,'\n');
    notes.push('<details><summary>show diff</summary><pre>'+
      d.replace(/^(\+.*)$/gm,'<span class="da">\$1</span>')
       .replace(/^(-.*)$/gm,'<span class="dd">\$1</span>')
      +'</pre></details>');
  }
  tr.innerHTML='<td>'+r.k+'</td>'+
    '<td style="font-family:monospace;font-size:11px">'+r.ts+'</td>'+
    '<td>'+(r.iv===null?'—':r.iv+'s')+'</td>'+
    '<td><span class="b '+r.result+'">'+r.result+'</span></td>'+
    '<td>'+notes.join(' ')+'</td>';
  tb.appendChild(tr);
});
</script></body></html>
HTMLEOF

  echo "[INFO] Report: ${out}"
}

# ---------- net_test HTML report ----------
# 用法：generate_net_report <session_dir> [output_html]
generate_net_report() {
  # Reads from result.json (LOG018) instead of parsing summary.log + mtime.
  # Single source of truth: same numbers in result.json appear in the HTML.
  # Also fixes BUG0018 (Total test time = 00h 00m 00s) for net_test side.
  local session_dir="${1:?}"
  local out="${2:-${session_dir}/net_report_$(now_ts).html}"

  command -v jq >/dev/null 2>&1 || jq_install || {
    echo "[WARN] generate_net_report: jq not available; cannot generate HTML report" >&2
    return 1
  }

  # Locate result.json (latest if multiple)
  local resultjson
  resultjson="$(find "${session_dir}" -maxdepth 1 -name 'net_test_*.result.json' \
                | sort | tail -n1)"
  if [[ -z "${resultjson}" || ! -f "${resultjson}" ]]; then
    echo "[WARN] generate_net_report: no net_test_*.result.json found in ${session_dir}" >&2
    return 1
  fi

  # ---- Pull metadata from JSON ----
  local host kernel sid total_time_str overall_verdict
  host="$(           jq -r '.environment.host       // "unknown"' "${resultjson}")"
  kernel="$(         jq -r '.environment.os.kernel  // "unknown"' "${resultjson}")"
  sid="$(            jq -r '.session_id             // "unknown"' "${resultjson}")"
  total_time_str="$( jq -r '.execution.elapsed_human // "?"'      "${resultjson}")"
  overall_verdict="$(jq -r '.verdict                // "UNKNOWN"' "${resultjson}")"

  local pairs_count tests_count
  pairs_count="$(jq '.details.pairs | length'                  "${resultjson}")"
  tests_count="$(jq '[.details.pairs[].speeds[]] | length'     "${resultjson}")"

  if (( pairs_count == 0 )); then
    echo "[WARN] generate_net_report: result.json has no pairs in ${resultjson}" >&2
    return 1
  fi

  # ---- Build JS rows array via jq ----
  # One row per (pair, speed). Pairs whose speeds[] is empty (namespace creation
  # failed, no link, crash before first speed) appear as a single NOT_TESTED row
  # so they are always visible in the report — never silently hidden.
  local rows_js
  rows_js="$(jq -c '
    [ .details.pairs[]
      | .name as $pair
      | (.pair_max_mbps // null) as $pmax
      | if (.speeds | length) == 0 then
          { pair: $pair, spd: null, v4: null, v6: null,
            tf: null, tr: null, uf: null, ur: null,
            pmax: $pmax, bd: null, retr: null, jit: null, loss: null,
            errc: null, jumbo: null, thr: null, pct: null, reason: null,
            verdict: "NOT_TESTED" }
        else
          .speeds[]
          | { pair:    $pair,
              spd:     .speed_mbps,
              v4:      .ipv4_ping,
              v6:      .ipv6_ping,
              tf:      .throughput.tcp_fwd_mbps,
              tr:      .throughput.tcp_rev_mbps,
              uf:      .throughput.udp_fwd_mbps,
              ur:      .throughput.udp_rev_mbps,
              pmax:    $pmax,
              bd:      (.bidirectional.sum_mbps // null),
              retr:    (((.quality.tcp_fwd_retr // null)|tostring) + "/" + ((.quality.tcp_rev_retr // null)|tostring)),
              jit:     (((.quality.udp_fwd_jitter_ms // null)|tostring) + "/" + ((.quality.udp_rev_jitter_ms // null)|tostring)),
              loss:    (((.quality.udp_fwd_lost_pct // null)|tostring) + "/" + ((.quality.udp_rev_lost_pct // null)|tostring)),
              errc:    (if .error_counters == null then null
                        else ((.error_counters.even_rx_errors // 0) + (.error_counters.even_tx_errors // 0)
                            + (.error_counters.odd_rx_errors  // 0) + (.error_counters.odd_tx_errors  // 0)) end),
              jumbo:   (.jumbo.result // null),
              thr:     (.tcp_pass_thr_mbps // null),
              pct:     (.tcp_pass_pct // null),
              reason:  (.reason // null),
              verdict: .verdict }
        end
    ]' "${resultjson}")"

  # ---- HTML ----
  cat > "${out}" <<NREOF
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>net_test report — ${sid}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;color:#222;background:#f5f5f0;padding:1.5rem}
h1{font-size:18px;font-weight:500;margin-bottom:4px}.meta{font-size:12px;color:#666;margin-bottom:1.5rem}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:1.5rem}
.card{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:.75rem 1rem}
.card .lbl{font-size:11px;color:#888;margin-bottom:4px}.card .val{font-size:22px;font-weight:500;color:#185FA5}
.v-pass{color:#1D9E75!important}.v-fail{color:#E24B4A!important}.v-unknown{color:#888!important}
.v-error{color:#E24B4A!important}.v-skipped{color:#aaa!important}.v-not-tested{color:#aaa!important}
tr.nt td{background:#f9f9f9;color:#999}
.sec{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:1rem 1.25rem;margin-bottom:1rem}
.sec h2{font-size:12px;font-weight:500;color:#666;text-transform:uppercase;letter-spacing:.04em;margin-bottom:.6rem}
table{width:100%;border-collapse:collapse;font-size:12px}
th{font-weight:500;color:#666;text-align:left;padding:6px 8px;border-bottom:1px solid #eee;white-space:nowrap}
td{padding:5px 8px;border-bottom:.5px solid #f0f0f0}tr:hover td{background:#fafaf8}tr.fr td{background:#fff8f8}
.b{display:inline-block;padding:2px 7px;border-radius:4px;font-size:11px;font-weight:500}
.PASS{background:#EAF3DE;color:#3B6D11}.FAIL{background:#FCEBEB;color:#A32D2D}.na{background:#F1EFE8;color:#5F5E5A}
@media(max-width:700px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body>
<h1>net_test report</h1>
<p class="meta">Host: ${host} &nbsp;|&nbsp; Kernel: ${kernel} &nbsp;|&nbsp; Session: ${sid}</p>
<div class="cards">
<div class="card"><div class="lbl">Pairs (total)</div><div class="val">${pairs_count}</div></div>
<div class="card"><div class="lbl">Speed tests run</div><div class="val">${tests_count}</div></div>
<div class="card"><div class="lbl">Total test time</div><div class="val" style="font-size:15px;padding-top:4px">${total_time_str}</div></div>
<div class="card"><div class="lbl">Verdict</div><div class="val v-$(echo "${overall_verdict}" | tr '[:upper:]' '[:lower:]')" style="font-size:15px;padding-top:4px">${overall_verdict}</div></div>
</div>
<div class="sec"><h2>Test results</h2>
<p style="font-size:11px;color:#888;margin-bottom:.6rem">
Max = pair's max link speed (NET015). Full-dup = simultaneous bidirectional TCP sum (NET017).
Quality = TCP retransmits / UDP jitter(ms) / UDP loss(%), fwd/rev (NET017).
Err = NIC rx+tx error counter delta during the run (NET016) — non-zero is highlighted.
Jumbo = 9000-MTU DF ping at &ge;1000M (NET018). Thr = TCP PASS threshold actually applied (NET009).
Hover the Verdict cell for the reason (NET008).</p>
<table><thead><tr>
<th>Pair</th><th>Max</th><th>Speed(Mbps)</th><th>IPv4</th><th>IPv6</th>
<th>TCP Fwd</th><th>TCP Rev</th><th>UDP Fwd</th><th>UDP Rev</th>
<th>Full-dup</th><th>Quality</th><th>Err</th><th>Jumbo</th><th>Thr</th><th>Verdict</th>
</tr></thead><tbody id="tb"></tbody></table></div>
<script>
const ROWS=${rows_js};
const tb=document.getElementById('tb');
const fmtMbps=v=>(v==null||isNaN(v))?'—':(+v).toFixed(0);
const badge=v=>v&&v!=='N/A'?'<span class="b '+(v==='PASS'||v==='FAIL'?v:'na')+'">'+v+'</span>':'—';
const qfmt=s=>(!s||s==='null/null')?'—':s.replace(/null/g,'—');
ROWS.forEach(r=>{
  const tr=document.createElement('tr');
  const vLow=(r.verdict||'UNKNOWN').toLowerCase().replace(/_/g,'-');
  if(r.verdict==='FAIL')tr.className='fr';
  else if(r.verdict==='NOT_TESTED')tr.className='nt';
  const vClass='v-'+vLow;
  const spdCell=r.spd!=null?r.spd:'—';
  const maxCell=r.pmax!=null?r.pmax+'M':'—';
  const errCell=(r.errc==null)?'—':(r.errc>0?'<span class="b FAIL">'+r.errc+'</span>':'0');
  const jumboCell=r.jumbo?'<span class="b '+(r.jumbo==='PASS'?'PASS':(r.jumbo==='SKIP'?'na':'FAIL'))+'">'+r.jumbo+'</span>':'—';
  const thrCell=(r.thr!=null)?fmtMbps(r.thr)+'M'+(r.pct!=null?' ('+r.pct+'%)':''):'—';
  const reasonAttr=r.reason?' title="'+String(r.reason).replace(/"/g,'&quot;')+'"':'';
  tr.innerHTML='<td>'+r.pair+'</td><td style="font-size:11px">'+maxCell+'</td><td>'+spdCell+'</td>'+
    '<td>'+badge(r.v4)+'</td><td>'+badge(r.v6)+'</td>'+
    '<td style="font-size:11px">'+fmtMbps(r.tf)+'</td>'+
    '<td style="font-size:11px">'+fmtMbps(r.tr)+'</td>'+
    '<td style="font-size:11px">'+fmtMbps(r.uf)+'</td>'+
    '<td style="font-size:11px">'+fmtMbps(r.ur)+'</td>'+
    '<td style="font-size:11px">'+fmtMbps(r.bd)+'</td>'+
    '<td style="font-size:10px">retr '+qfmt(r.retr)+'<br>jit '+qfmt(r.jit)+' loss '+qfmt(r.loss)+'</td>'+
    '<td style="font-size:11px">'+errCell+'</td>'+
    '<td style="font-size:11px">'+jumboCell+'</td>'+
    '<td style="font-size:11px">'+thrCell+'</td>'+
    '<td class="'+vClass+'"'+reasonAttr+'>'+(r.verdict||'UNKNOWN')+'</td>';
  tb.appendChild(tr);
});
</script></body></html>
NREOF
  echo "[INFO] Net report: ${out}"
}

# ---------- disk_test HTML report ----------
# 用法：generate_disk_report <session_dir> [output_html]
generate_disk_report() {
  # Reads from result.json (LOG018) instead of parsing summary.log + mtime.
  # Single source of truth: same numbers in result.json appear in the HTML.
  # Also fixes BUG0018 (Total test time = 00h 00m 00s) since elapsed_human
  # is read directly from JSON, no more mtime arithmetic.
  local session_dir="${1:?}"
  local out="${2:-${session_dir}/disk_report_$(now_ts).html}"

  command -v jq >/dev/null 2>&1 || jq_install || {
    echo "[WARN] generate_disk_report: jq not available; cannot generate HTML report" >&2
    return 1
  }

  # Locate result.json (latest if multiple). Filename pattern: disk_test_*.result.json
  local resultjson
  resultjson="$(find "${session_dir}" -maxdepth 1 -name 'disk_test_*.result.json' \
                | sort | tail -n1)"
  if [[ -z "${resultjson}" || ! -f "${resultjson}" ]]; then
    echo "[WARN] generate_disk_report: no disk_test_*.result.json found in ${session_dir}" >&2
    return 1
  fi

  # ---- Pull metadata from JSON ----
  local host kernel sid total_time_str overall_verdict
  host="$(           jq -r '.environment.host       // "unknown"' "${resultjson}")"
  kernel="$(         jq -r '.environment.os.kernel  // "unknown"' "${resultjson}")"
  sid="$(            jq -r '.session_id             // "unknown"' "${resultjson}")"
  total_time_str="$( jq -r '.execution.elapsed_human // "?"'      "${resultjson}")"
  overall_verdict="$(jq -r '.verdict                // "UNKNOWN"' "${resultjson}")"

  local disks_count tests_count
  disks_count="$(jq '.details.devices | length'                 "${resultjson}")"
  tests_count="$(jq '[.details.devices[].patterns[]] | length'  "${resultjson}")"

  if (( tests_count == 0 )); then
    echo "[WARN] generate_disk_report: result.json has zero patterns in ${resultjson}" >&2
    return 1
  fi

  # ---- Build JS-friendly arrays via jq ----
  # rows_js: one entry per pattern, with disk name flattened in.
  # kind is presented as "Read"/"Write" (capitalised) for HTML readability;
  # JSON itself stores lowercase "read"/"write".
  local rows_js disk_labels
  rows_js="$(jq -c '
    [ .details.devices[]
      | .name as $disk
      | .patterns[]
      | {
          disk:    $disk,
          base:    .name,
          kind:    ((.direction // "?") | (.[0:1] | ascii_upcase) + .[1:]),
          mib:     (.measurements.avg_mibs // 0),
          mb:      (.measurements.avg_mbs  // 0),
          verdict: (.verdict // "UNKNOWN")
        }
    ]' "${resultjson}")"
  disk_labels="$(jq -c '[.details.devices[].name]' "${resultjson}")"

  # ---- HTML ----
  cat > "${out}" <<DREOF
<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>disk_test report — ${sid}</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:14px;color:#222;background:#f5f5f0;padding:1.5rem}
h1{font-size:18px;font-weight:500;margin-bottom:4px}.meta{font-size:12px;color:#666;margin-bottom:1.5rem}
.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:1.5rem}
.card{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:.75rem 1rem}
.card .lbl{font-size:11px;color:#888;margin-bottom:4px}.card .val{font-size:22px;font-weight:500;color:#185FA5}
.v-pass{color:#1D9E75!important}.v-fail{color:#E24B4A!important}.v-unknown{color:#888!important}
.v-error{color:#E24B4A!important}.v-skipped{color:#aaa!important}
.sec{background:#fff;border:0.5px solid #ddd;border-radius:8px;padding:1rem 1.25rem;margin-bottom:1rem}
.sec h2{font-size:12px;font-weight:500;color:#666;text-transform:uppercase;letter-spacing:.04em;margin-bottom:.6rem}
.cw{position:relative;width:100%}
table{width:100%;border-collapse:collapse;font-size:12px}
th{font-weight:500;color:#666;text-align:left;padding:6px 8px;border-bottom:1px solid #eee;white-space:nowrap}
td{padding:5px 8px;border-bottom:.5px solid #f0f0f0}tr:hover td{background:#fafaf8}
.rd{color:#185FA5}.wr{color:#E24B4A}
@media(max-width:600px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body>
<h1>disk_test report</h1>
<p class="meta">Host: ${host} &nbsp;|&nbsp; Kernel: ${kernel} &nbsp;|&nbsp; Session: ${sid}</p>
<div class="cards">
<div class="card"><div class="lbl">Disks tested</div><div class="val">${disks_count}</div></div>
<div class="card"><div class="lbl">Test patterns</div><div class="val">${tests_count}</div></div>
<div class="card"><div class="lbl">Total test time</div><div class="val" style="font-size:15px;padding-top:4px">${total_time_str}</div></div>
<div class="card"><div class="lbl">Verdict</div><div class="val v-$(echo "${overall_verdict}" | tr '[:upper:]' '[:lower:]')" style="font-size:15px;padding-top:4px">${overall_verdict}</div></div>
</div>
<div class="sec"><h2>Throughput (MiB/s)</h2>
<div class="cw" id="cwrap"><canvas id="ch" role="img" aria-label="Disk throughput bar chart">Disk throughput.</canvas></div></div>
<div class="sec"><h2>Detail table</h2>
<table><thead><tr>
<th>Disk</th><th>Pattern</th><th>R/W</th><th>Avg MiB/s</th><th>Avg MB/s</th><th>Verdict</th>
</tr></thead><tbody id="tb"></tbody></table></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
<script>
const ROWS=${rows_js};
const DISKS=${disk_labels};
const PAL=['#378ADD','#E24B4A','#1D9E75','#BA7517','#9b59b6','#e67e22'];
const tb=document.getElementById('tb');
ROWS.forEach(r=>{
  const tr=document.createElement('tr');
  const vClass='v-'+(r.verdict||'UNKNOWN').toLowerCase();
  tr.innerHTML='<td>'+r.disk+'</td><td>'+r.base+'</td>'+
    '<td class="'+(r.kind==='Read'?'rd':'wr')+'">'+r.kind+'</td>'+
    '<td><b>'+(+r.mib).toFixed(1)+'</b></td>'+
    '<td>'+(+r.mb).toFixed(1)+'</td>'+
    '<td class="'+vClass+'">'+(r.verdict||'UNKNOWN')+'</td>';
  tb.appendChild(tr);
});
const allBases=[...new Set(ROWS.map(r=>r.base+'_'+r.kind))];
const labels=allBases.map(x=>x.replace('_',' '));
const datasets=DISKS.map((d,di)=>({
  label:d,
  data:allBases.map(bk=>{const r=ROWS.find(r=>r.disk===d&&r.base+'_'+r.kind===bk);return r?r.mib:null;}),
  backgroundColor:PAL[di%PAL.length]+'cc',borderColor:PAL[di%PAL.length],borderWidth:1
}));
const h=Math.max(300,allBases.length*32*Math.max(1,DISKS.length/2)+80);
document.getElementById('cwrap').style.height=h+'px';
new Chart(document.getElementById('ch'),{type:'bar',data:{labels,datasets},
  options:{indexAxis:'y',responsive:true,maintainAspectRatio:false,
    plugins:{legend:{display:DISKS.length>1},
      tooltip:{callbacks:{label:c=>c.dataset.label+': '+c.parsed.x.toFixed(1)+' MiB/s'}}},
    scales:{x:{title:{display:true,text:'MiB/s',font:{size:11}},ticks:{font:{size:10}}},
            y:{ticks:{font:{size:10}}}}}});
</script></body></html>
DREOF
  echo "[INFO] Disk report: ${out}"
}

# ---------- Result JSON emitter (LOG015/LOG017/LOG019/LOG020) ----------
# Writes a result.json conforming to the framework schema (v00.00.01).
#
# Usage:
#   emit_result_json \
#     --test-name <name> \
#     --test-version <version> \
#     --verdict <PASS|FAIL|UNKNOWN|ERROR|SKIPPED> \
#     --summary-json '{"total":N,"passed":N,"failed":N,"unknown":N,"skipped":N,"error":N}' \
#     --details-json '{...}' \
#     --output <path>
#
# Auto-filled from environment:
#   _session_id, _session_t0, _m, _n
#   _config_api_version, _function_api_version
#
# Returns: 0 on success, non-zero on error.
emit_result_json() {
  command -v jq >/dev/null 2>&1 || jq_install || {
    echo "[ERROR] emit_result_json: jq not available and install failed" >&2
    return 1
  }

  local _test_name="" _test_version="" _verdict=""
  local _summary_json='{}' _details_json='{}'
  local _output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test-name)     _test_name="$2"; shift 2 ;;
      --test-version)  _test_version="$2"; shift 2 ;;
      --verdict)       _verdict="$2"; shift 2 ;;
      --summary-json)  _summary_json="$2"; shift 2 ;;
      --details-json)  _details_json="$2"; shift 2 ;;
      --output)        _output="$2"; shift 2 ;;
      *) echo "[ERROR] emit_result_json: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  # Validate required args
  [[ -n "${_test_name}" ]] || { echo "[ERROR] emit_result_json: --test-name required" >&2; return 2; }
  [[ -n "${_verdict}"   ]] || { echo "[ERROR] emit_result_json: --verdict required"   >&2; return 2; }
  [[ -n "${_output}"    ]] || { echo "[ERROR] emit_result_json: --output required"    >&2; return 2; }

  # Validate verdict value
  case "${_verdict}" in
    PASS|FAIL|UNKNOWN|ERROR|SKIPPED) ;;
    *) echo "[ERROR] emit_result_json: --verdict must be PASS/FAIL/UNKNOWN/ERROR/SKIPPED, got '${_verdict}'" >&2; return 2 ;;
  esac

  # Validate that summary_json and details_json are valid JSON
  if ! echo "${_summary_json}" | jq . >/dev/null 2>&1; then
    echo "[ERROR] emit_result_json: --summary-json is not valid JSON" >&2
    return 3
  fi
  if ! echo "${_details_json}" | jq . >/dev/null 2>&1; then
    echo "[ERROR] emit_result_json: --details-json is not valid JSON" >&2
    return 3
  fi

  # Auto-fill from environment with defaults
  local _schema_version="00.00.01"
  local _sid="${_session_id:-unknown}"
  local _cfg_ver="${_config_api_version:-unknown}"
  local _fn_ver="${_function_api_version:-unknown}"
  local _m_val="${_m:-1}"
  local _n_val="${_n:-0}"

  # Time fields
  local _end_epoch _start_epoch _elapsed_s
  _end_epoch="$(date +%s)"
  _start_epoch="${_session_t0:-${_end_epoch}}"
  _elapsed_s=$(( _end_epoch - _start_epoch ))
  (( _elapsed_s < 0 )) && _elapsed_s=0

  local _elapsed_human
  _elapsed_human="$(printf '%02d:%02d:%02d' \
    $(( _elapsed_s/3600 )) $(( (_elapsed_s%3600)/60 )) $(( _elapsed_s%60 )))"

  local _start_iso _end_iso
  _start_iso="$(date -d "@${_start_epoch}" --iso-8601=seconds 2>/dev/null \
                || date -r "${_start_epoch}" '+%Y-%m-%dT%H:%M:%S%z')"
  _end_iso="$(date -d "@${_end_epoch}" --iso-8601=seconds 2>/dev/null \
              || date -r "${_end_epoch}" '+%Y-%m-%dT%H:%M:%S%z')"

  # Environment - host
  local _host
  _host="$(hostname 2>/dev/null || echo unknown)"

  # Environment - OS (parse /etc/os-release without polluting caller's namespace)
  local _os_id="" _os_ver="" _os_code="" _os_kernel=""
  if [[ -r /etc/os-release ]]; then
    _os_id="$(   awk -F= '$1=="ID"               {gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    _os_ver="$(  awk -F= '$1=="VERSION_ID"       {gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    _os_code="$( awk -F= '$1=="VERSION_CODENAME" {gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
  fi
  _os_kernel="$(uname -r 2>/dev/null || echo unknown)"

  # FWK037: system configuration inventory, so every test's result.json records
  # which hardware produced it. Best-effort: fall back to an empty object.
  local _sysinfo_json
  _sysinfo_json="$(system_info_json 2>/dev/null || true)"
  if ! echo "${_sysinfo_json}" | jq . >/dev/null 2>&1; then
    _sysinfo_json='{}'
  fi

  # Make sure output dir exists
  local _out_dir
  _out_dir="$(dirname "${_output}")"
  mkdir -p -- "${_out_dir}"

  # Build the JSON using jq
  jq -n \
    --argjson sysinfo    "${_sysinfo_json}" \
    --arg     schema_v   "${_schema_version}" \
    --arg     t_name     "${_test_name}" \
    --arg     t_version  "${_test_version}" \
    --arg     sid        "${_sid}" \
    --arg     host       "${_host}" \
    --arg     os_id      "${_os_id}" \
    --arg     os_ver     "${_os_ver}" \
    --arg     os_code    "${_os_code}" \
    --arg     kernel     "${_os_kernel}" \
    --arg     cfg_ver    "${_cfg_ver}" \
    --arg     fn_ver     "${_fn_ver}" \
    --arg     start_iso  "${_start_iso}" \
    --arg     end_iso    "${_end_iso}" \
    --argjson elapsed_s  "${_elapsed_s}" \
    --arg     elapsed_h  "${_elapsed_human}" \
    --argjson m          "${_m_val}" \
    --argjson n          "${_n_val}" \
    --arg     verdict    "${_verdict}" \
    --argjson summary    "${_summary_json}" \
    --argjson details    "${_details_json}" \
    '{
      _result_schema_version: $schema_v,
      test_name:    $t_name,
      test_version: $t_version,
      session_id:   $sid,
      environment: {
        host: $host,
        os: {
          id:       $os_id,
          version:  $os_ver,
          codename: $os_code,
          kernel:   $kernel
        },
        framework: {
          config_api_version:   $cfg_ver,
          function_api_version: $fn_ver
        }
      },
      execution: {
        start:           $start_iso,
        end:             $end_iso,
        elapsed_seconds: $elapsed_s,
        elapsed_human:   $elapsed_h,
        loops: {
          target:    $m,
          completed: $n
        }
      },
      system_info: $sysinfo,
      verdict: $verdict,
      summary: $summary,
      details: $details
    }' > "${_output}"

  echo "[INFO] emit_result_json: wrote ${_output}"
  return 0
}

# ============================================================================
# Memory inventory & usability verification (DET002 / BUG0039)
# ============================================================================
# A DIMM can be POPULATED but not USABLE: if the memory controller fails to
# train it, SPD/DMI still reports the module (so `dmidecode` lists it) while the
# OS never gets the memory. Observed on a real DUT: 6x32GB installed, dmidecode
# shows 6 populated slots, but /proc/meminfo reports only ~128GB (and the BIOS
# setup screen agrees). Windows shows the same thing natively as
# "192 GB installed (128 GB usable)". Trusting the DMI view alone would call
# that machine healthy, so we cross-check the two totals.

# Sum of populated DIMM sizes from DMI/SPD, in bytes. Empty output if dmidecode
# is unavailable/unreadable (caller must treat that as UNKNOWN, never as 0).
mem_installed_bytes() {
  command -v dmidecode >/dev/null 2>&1 || return 1
  LANG=C dmidecode -t memory 2>/dev/null | awk '
    /^[ \t]*Size:/ {
      line=$0; sub(/^[ \t]*Size:[ \t]*/,"",line); sub(/\r$/,"",line)
      if (line ~ /No Module Installed|Not Installed|Unknown/) next
      n=line+0                      # leading number, e.g. "32 GB" -> 32
      if (n <= 0) next
      if      (line ~ /[Tt]B/) bytes = n * 1024 * 1024 * 1024 * 1024
      else if (line ~ /[Gg]B/) bytes = n * 1024 * 1024 * 1024
      else if (line ~ /[Mm]B/) bytes = n * 1024 * 1024
      else if (line ~ /[Kk]B/) bytes = n * 1024
      else                     bytes = n
      total += bytes
    }
    END { if (total > 0) printf "%.0f", total }
  '
}

# Number of populated DIMM slots per DMI. Empty if dmidecode is unavailable.
mem_populated_count() {
  command -v dmidecode >/dev/null 2>&1 || return 1
  LANG=C dmidecode -t memory 2>/dev/null | awk '
    /^[ \t]*Size:/ {
      line=$0; sub(/^[ \t]*Size:[ \t]*/,"",line); sub(/\r$/,"",line)
      if (line ~ /No Module Installed|Not Installed|Unknown/) next
      if (line+0 > 0) c++
    }
    END { printf "%d", c+0 }
  '
}

# Smallest populated DIMM size in bytes (used to size the FAIL threshold).
mem_smallest_dimm_bytes() {
  command -v dmidecode >/dev/null 2>&1 || return 1
  LANG=C dmidecode -t memory 2>/dev/null | awk '
    /^[ \t]*Size:/ {
      line=$0; sub(/^[ \t]*Size:[ \t]*/,"",line); sub(/\r$/,"",line)
      if (line ~ /No Module Installed|Not Installed|Unknown/) next
      n=line+0; if (n <= 0) next
      if      (line ~ /[Tt]B/) bytes = n * 1024 * 1024 * 1024 * 1024
      else if (line ~ /[Gg]B/) bytes = n * 1024 * 1024 * 1024
      else if (line ~ /[Mm]B/) bytes = n * 1024 * 1024
      else if (line ~ /[Kk]B/) bytes = n * 1024
      else                     bytes = n
      if (min == 0 || bytes < min) min = bytes
    }
    END { if (min > 0) printf "%.0f", min }
  '
}

# Memory the OS can actually use, in bytes (/proc/meminfo MemTotal is KiB).
mem_usable_bytes() {
  [[ -r /proc/meminfo ]] || return 1
  awk '/^MemTotal:/ { printf "%.0f", $2 * 1024; exit }' /proc/meminfo
}

# Render bytes as a human GiB string (1 decimal place).
mem_bytes_to_gib() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

# DET002 usability verdict.
# Prints: RESULT|installed_bytes|usable_bytes|populated_count|gap_bytes|threshold_bytes|reason
# RESULT is Pass | Fail | UNKNOWN. UNKNOWN when the DMI view is unavailable --
# never a silent Pass.
mem_usability_check() {
  local installed usable count smallest gap threshold tol_pct tol_floor
  installed="$(mem_installed_bytes 2>/dev/null || true)"
  usable="$(mem_usable_bytes 2>/dev/null || true)"
  count="$(mem_populated_count 2>/dev/null || true)"
  smallest="$(mem_smallest_dimm_bytes 2>/dev/null || true)"

  if [[ -z "${installed}" || -z "${usable}" ]]; then
    printf 'UNKNOWN|%s|%s|%s|||dmidecode or /proc/meminfo unavailable — cannot verify DIMM usability (not a pass)\n' \
      "${installed:-}" "${usable:-}" "${count:-}"
    return 0
  fi

  gap=$(( installed - usable ))
  (( gap < 0 )) && gap=0

  # Threshold: normal firmware/kernel reservation must not trip this, but a
  # whole missing DIMM must. tolerance = max(3% of installed, 2 GiB, half the
  # smallest populated DIMM).
  tol_pct=$(awk -v i="${installed}" 'BEGIN { printf "%.0f", i * 0.03 }')
  tol_floor=$(( 2 * 1024 * 1024 * 1024 ))
  threshold="${tol_pct}"
  (( tol_floor > threshold )) && threshold="${tol_floor}"
  if [[ -n "${smallest}" ]]; then
    local half_dimm=$(( smallest / 2 ))
    (( half_dimm > threshold )) && threshold="${half_dimm}"
  fi

  if (( gap > threshold )); then
    printf 'Fail|%s|%s|%s|%s|%s|installed %s GiB across %s DIMM(s) but only %s GiB usable — %s GiB missing (> %s GiB tolerance): one or more populated DIMMs were not trained/enabled (defective DIMM, slot, or seating)\n' \
      "${installed}" "${usable}" "${count}" "${gap}" "${threshold}" \
      "$(mem_bytes_to_gib "${installed}")" "${count}" "$(mem_bytes_to_gib "${usable}")" \
      "$(mem_bytes_to_gib "${gap}")" "$(mem_bytes_to_gib "${threshold}")"
  else
    printf 'Pass|%s|%s|%s|%s|%s|installed %s GiB across %s DIMM(s), %s GiB usable — %s GiB reserved, within %s GiB tolerance\n' \
      "${installed}" "${usable}" "${count}" "${gap}" "${threshold}" \
      "$(mem_bytes_to_gib "${installed}")" "${count}" "$(mem_bytes_to_gib "${usable}")" \
      "$(mem_bytes_to_gib "${gap}")" "$(mem_bytes_to_gib "${threshold}")"
  fi
}

# ============================================================================
# System configuration inventory (FWK037)
# ============================================================================
# Best-effort snapshot of the DUT's hardware/firmware/OS configuration, so every
# test's log and report is self-describing ("these results came from THIS CPU
# with THIS much RAM"). Informational only -- it never changes a verdict, and a
# missing tool degrades to "N/A" instead of failing the test.

_si_val() { printf '%s' "${1:-N/A}"; }

# Cache so repeated calls in one run are cheap (FWK037 implication 3).
_SYSINFO_CACHE=""

collect_system_info() {
  if [[ -n "${_SYSINFO_CACHE}" && "${1:-}" != "--refresh" ]]; then
    printf '%s' "${_SYSINFO_CACHE}"
    return 0
  fi

  # Initialise every local: function.sh runs under `set -u`, where a declared but
  # never-assigned local is an "unbound variable" fatal error when the tool that
  # would have filled it (dmidecode, lscpu) is absent.
  local host="" os="" kernel="" board="" product="" serial="" bios=""
  local cpu="" sockets="" cores="" threads=""
  local mem_inst="" mem_use="" mem_cnt="" mem_chk="" mem_res=""

  host="$(hostname 2>/dev/null || true)"
  kernel="$(uname -r 2>/dev/null || true)"
  if [[ -r /etc/os-release ]]; then
    os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}")"
  fi

  if command -v dmidecode >/dev/null 2>&1; then
    board="$(dmidecode -s baseboard-product-name 2>/dev/null | head -n1 || true)"
    product="$(dmidecode -s system-product-name 2>/dev/null | head -n1 || true)"
    serial="$(dmidecode -s system-serial-number 2>/dev/null | head -n1 || true)"
    bios="$(dmidecode -s bios-version 2>/dev/null | head -n1 || true)"
  fi

  if command -v lscpu >/dev/null 2>&1; then
    cpu="$(LANG=C lscpu | awk -F': +' '/^Model name/{print $2; exit}')"
    sockets="$(LANG=C lscpu | awk -F': +' '/^Socket\(s\)/{print $2; exit}')"
    cores="$(LANG=C lscpu | awk -F': +' '/^Core\(s\) per socket/{print $2; exit}')"
    threads="$(LANG=C lscpu | awk -F': +' '/^CPU\(s\)/{print $2; exit}')"
  fi

  # Memory: report BOTH the installed (DMI) and usable (OS) totals, plus the
  # DET002 usability verdict -- the discrepancy is the whole point.
  mem_chk="$(mem_usability_check)"
  mem_res="${mem_chk%%|*}"
  mem_inst="$(printf '%s' "${mem_chk}" | cut -d'|' -f2)"
  mem_use="$(printf '%s' "${mem_chk}" | cut -d'|' -f3)"
  mem_cnt="$(printf '%s' "${mem_chk}" | cut -d'|' -f4)"

  local mem_inst_h="N/A" mem_use_h="N/A"
  [[ -n "${mem_inst}" ]] && mem_inst_h="$(mem_bytes_to_gib "${mem_inst}") GiB"
  [[ -n "${mem_use}"  ]] && mem_use_h="$(mem_bytes_to_gib "${mem_use}") GiB"

  _SYSINFO_CACHE="$(cat <<EOS
========== System configuration (FWK037) ==========
Hostname     : $(_si_val "${host}")
OS           : $(_si_val "${os}")
Kernel       : $(_si_val "${kernel}")
Product      : $(_si_val "${product}")
Baseboard    : $(_si_val "${board}")
Serial       : $(_si_val "${serial}")
BIOS         : $(_si_val "${bios}")
CPU          : $(_si_val "${cpu}")
CPU topology : sockets=$(_si_val "${sockets}") cores/socket=$(_si_val "${cores}") logical=$(_si_val "${threads}")
Memory       : installed ${mem_inst_h} across $(_si_val "${mem_cnt}") DIMM(s), usable ${mem_use_h}  [${mem_res}]
===================================================
EOS
)"
  printf '%s' "${_SYSINFO_CACHE}"
}

# Same inventory as a JSON object for result.json (FWK028 canonical form).
system_info_json() {
  # All locals initialised — see collect_system_info (set -u safety).
  local host="" os="" kernel="" board="" product="" serial="" bios=""
  local cpu="" sockets="" cores="" threads=""
  local mem_chk="" mem_res="" mem_inst="" mem_use="" mem_cnt="" mem_gap="" mem_reason=""

  host="$(hostname 2>/dev/null || true)"
  kernel="$(uname -r 2>/dev/null || true)"
  [[ -r /etc/os-release ]] && os="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}")"
  if command -v dmidecode >/dev/null 2>&1; then
    board="$(dmidecode -s baseboard-product-name 2>/dev/null | head -n1 || true)"
    product="$(dmidecode -s system-product-name 2>/dev/null | head -n1 || true)"
    serial="$(dmidecode -s system-serial-number 2>/dev/null | head -n1 || true)"
    bios="$(dmidecode -s bios-version 2>/dev/null | head -n1 || true)"
  fi
  if command -v lscpu >/dev/null 2>&1; then
    cpu="$(LANG=C lscpu | awk -F': +' '/^Model name/{print $2; exit}')"
    sockets="$(LANG=C lscpu | awk -F': +' '/^Socket\(s\)/{print $2; exit}')"
    cores="$(LANG=C lscpu | awk -F': +' '/^Core\(s\) per socket/{print $2; exit}')"
    threads="$(LANG=C lscpu | awk -F': +' '/^CPU\(s\)/{print $2; exit}')"
  fi

  mem_chk="$(mem_usability_check)"
  mem_res="${mem_chk%%|*}"
  mem_inst="$(printf '%s' "${mem_chk}" | cut -d'|' -f2)"
  mem_use="$(printf '%s'  "${mem_chk}" | cut -d'|' -f3)"
  mem_cnt="$(printf '%s'  "${mem_chk}" | cut -d'|' -f4)"
  mem_gap="$(printf '%s'  "${mem_chk}" | cut -d'|' -f5)"
  mem_reason="$(printf '%s' "${mem_chk}" | cut -d'|' -f7-)"

  printf '{'
  printf '"hostname":%s,'   "$(_si_json_str "${host}")"
  printf '"os":%s,'         "$(_si_json_str "${os}")"
  printf '"kernel":%s,'     "$(_si_json_str "${kernel}")"
  printf '"product":%s,'    "$(_si_json_str "${product}")"
  printf '"baseboard":%s,'  "$(_si_json_str "${board}")"
  printf '"serial":%s,'     "$(_si_json_str "${serial}")"
  printf '"bios_version":%s,' "$(_si_json_str "${bios}")"
  printf '"cpu_model":%s,'  "$(_si_json_str "${cpu}")"
  printf '"cpu_sockets":%s,' "$(_si_json_num "${sockets}")"
  printf '"cpu_cores_per_socket":%s,' "$(_si_json_num "${cores}")"
  printf '"cpu_logical":%s,' "$(_si_json_num "${threads}")"
  printf '"memory":{'
  printf '"installed_bytes":%s,' "$(_si_json_num "${mem_inst}")"
  printf '"usable_bytes":%s,'    "$(_si_json_num "${mem_use}")"
  printf '"dimm_populated_count":%s,' "$(_si_json_num "${mem_cnt}")"
  printf '"gap_bytes":%s,'       "$(_si_json_num "${mem_gap}")"
  printf '"result":%s,'          "$(_si_json_str "${mem_res}")"
  printf '"reason":%s'           "$(_si_json_str "${mem_reason}")"
  printf '}}'
}

# JSON scalar emitters: empty value -> null, so a missing field is explicit.
_si_json_str() {
  [[ -n "${1}" ]] && printf '"%s"' "$(_json_escape_si "${1}")" || printf 'null'
}
_si_json_num() {
  [[ -n "${1}" && "${1}" =~ ^[0-9]+$ ]] && printf '%s' "${1}" || printf 'null'
}

_json_escape_si() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/}"
  printf '%s' "${s}"
}
