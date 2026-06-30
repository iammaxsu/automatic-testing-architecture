#!/usr/bin/env bash
# config.sh ??shared parameters for disk_test.sh & sleep_test.sh
# - Defines timestamps, persistent counters, disk log defaults
# - Records _SESSION_T0 for elapsed fallback
# - Manages _bLoops prompt unless DISABLE_LOOPS_PROMPT=1
# - Provides default sleep timing params:
#     _sleep_loops            (default 4)
#     _sleep_delay_after_boot (default 30s)
#     _sleep_wake_after_sec   (default 60s)
set -Eeuo pipefail

# ---------- config API version ----------
export _config_api_version
: "${_config_api_version:="00.00.02"}"

# ---------- Timestamp format ----------
: "${_human_timestamp_format:=%Y-%m-%d %H-%M-%S}"
: "${_log_timestamp_format:=%Y%m%dT%H%M%S}"
export _human_timestamp_format _log_timestamp_format

setup_session() {
  log_dir "" 1 || return 1   # 1 = ?? session 摮??冗
  : "${_pwd:="adlink"}"
  # Session start (for elapsed fallback)
  #export _SESSION_T0="$(date +%s)"
  export _session_t0="$(date +%s)"      # some tests use ${_session_t0} for elapsed time

  # Ensure log path (function.sh/log_dir normally sets this)
  #: "${_log_dir:=${PWD}/logs}"
  #mkdir -p "${_log_dir}"

  # Persistent counter for sleep test iteration filenames
  export _count_file="${_log_dir}/counter.log"
  if [[ -f "${_count_file}" ]]; then
    local _last
    : "${_last:="$(tail -n1 "${_count_file}" 2>/dev/null | tr -dc '0-9')"}"
    if [[ -n "${_last}" ]]; then 
    export _count="${_last}"
    else
      export _count=0
      echo "${_count}" > "${_count_file}"
    fi
  else
    export _count=0
    echo "${_count}" > "${_count_file}"
  fi

  # Disk test defaults
#  export _disklog="${_disklog:-disk_test_${_date_format2}.log}"
#  : "${YES_I_UNDERSTAND:=0}" ; export YES_I_UNDERSTAND

  # Sleep timing defaults (can be overridden by environment before calling setup_session)
  : "${_sleep_loops:=4}"
  : "${_sleep_delay_after_boot:=30}"
  : "${_sleep_wake_after_sec:=60}"
  export _sleep_loops _sleep_delay_after_boot _sleep_wake_after_sec
}
  # Loops parameter for test scripts 
#  if [[ -z "${_bLoops:-}" ]]; then
#    if [[ "${DISABLE_LOOPS_PROMPT:-0}" != "1" ]]; then
#      # interactive prompt (default 1000) for disk tests
#      echo -n "How many cycles to run the test? (default: 1000): "
#      read -r _bLoops_input || true
#      if [[ -z "${_bLoops_input:-}" ]]; then
#        export _bLoops=1000
#      elif [[ "${_bLoops_input}" =~ ^[0-9]+$ && "${_bLoops_input}" -ge 1 ]]; then
#        export _bLoops="${_bLoops_input}"
#      else
#        echo "Invalid input '${_bLoops_input}', use default 1000"
#        export _bLoops=1000
#      fi
#    else
#      # non-interactive default to keep env consistent
#      export _bLoops="${_bLoops:-1000}"
#    fi
#  fi
#}

# ---------- Network test parameters (net_test.sh, NET001-NET018) ----------
# SET001: every tunable lives here, not scattered in net_test.sh.  Command-line
# flags still win; these are the defaults.
: "${_net_iperf_time_sec:=60}"   # NET007: iperf3 duration per direction (seconds).
: "${_net_iperf_omit_sec:=3}"    # NET007: seconds omitted at start (ramp-up exclusion).
: "${_net_tcp_pass_pct:=95}"     # NET009: default TCP PASS threshold as % of link speed,
                                 #   used for any speed not in _net_tcp_pass_pct_tiers.
: "${_net_tcp_pass_pct_tiers:=10:90,100:90,1000:95,2500:95,5000:95,10000:95}"
                                 # NET009: per-speed-tier override "speedMbps:pct,...".
                                 #   TCP overhead is proportionally larger at lower link
                                 #   speeds (~94-95% at 100M is normal), so 100M and below
                                 #   default to 90% while 1000M+ keep 95%.
: "${_net_err_counter_check:=1}" # NET016: 1 = diff ethtool -S error/discard counters
                                 #   around the runs at each speed and record the delta.
: "${_net_err_fail_on_delta:=0}" # NET016: 1 = a non-zero rx/tx error delta downgrades an
                                 #   otherwise-PASS speed verdict to FAIL; 0 = warn only.
: "${_net_test_bidir:=1}"        # NET017: 1 = also run a simultaneous bidirectional
                                 #   (full-duplex) iperf3 pass at each speed.
: "${_net_test_jumbo:=1}"        # NET018: 1 = at each >=1000M speed verify a DF jumbo
                                 #   ping crosses the link, then restore the MTU.
: "${_net_jumbo_mtu:=9000}"      # NET018: jumbo MTU to test (bytes); DF payload = MTU-28.

# NET019: select which NICs participate, by MAC address. A MAC is the most
# stable, OS-independent NIC identity (unlike enpXsY names). Both lists accept
# multiple entries separated by comma, semicolon, or whitespace; matching is
# case-insensitive and both ':' and '-' separators are accepted. CLI overrides:
# --include-mac / --exclude-mac (each overrides the matching list for that run).
: "${_net_include_macs:=}"       # NET019: whitelist. When non-empty, ONLY NICs whose
                                 #   MAC matches an entry are tested; all others become
                                 #   SKIPPED. Empty = every NIC is a candidate.
: "${_net_exclude_macs:=}"       # NET019 / NET012: blacklist. NICs whose MAC matches an
                                 #   entry are never tested — use it to pin the management
                                 #   / SSH-lifeline NIC so net_test never reconfigures it.
                                 #   Exclude wins over include. Example (single):
                                 #   '00-E0-4C-68-00-56'  Example (two): '00-E0-4C-68-00-56,
                                 #   AA-BB-CC-DD-EE-FF'

# ---------- fio Parameters ----------
# ===== Basis =====
#     --rw=read      --bs=1m    --iodepth=8   --numjobs=1   --size=1g   --runtime=5
#     --rw=write     --bs=1m    --iodepth=8   --numjobs=1   --size=1g   --runtime=5
#     --rw=read      --bs=1m    --iodepth=1   --numjobs=1   --size=1g   --runtime=5
#     --rw=write     --bs=1m    --iodepth=1   --numjobs=1   --size=1g   --runtime=5
#     --rw=randread  --bs=4k    --iodepth=32  --numjobs=1   --size=1g   --runtime=5
#     --rw=randwrite --bs=4k    --iodepth=32  --numjobs=1   --size=1g   --runtime=5
#     --rw=randread  --bs=4k    --iodepth=1   --numjobs=1   --size=1g   --runtime=5
#     --rw=randwrite --bs=4k    --iodepth=1   --numjobs=1   --size=1g   --runtime=5

## ---------- NVMe ----------
#     --rw=read      --bs=1m    --iodepth=8   --numjobs=1   --size=1g   --runtime=5
#     --rw=write     --bs=1m    --iodepth=8   --numjobs=1   --size=1g   --runtime=5
#     --rw=read      --bs=128k  --iodepth=32  --numjobs=1   --size=1g   --runtime=5
#     --rw=write     --bs=128k  --iodepth=32  --numjobs=1   --size=1g   --runtime=5
#     --rw=randread  --bs=4k    --iodepth=32  --numjobs=16  --size=1g   --runtime=5
#     --rw=randwrite --bs=4k    --iodepth=32  --numjobs=16  --size=1g   --runtime=5
#     --rw=randread  --bs=4k    --iodepth=1   --numjobs=1   --size=1g   --runtime=5
#     --rw=randwrite --bs=4k    --iodepth=1   --numjobs=1   --size=1g   --runtime=5

# ===== Basis =====
: "${_fio_direct:=1}"
: "${_fio_size:=1g}"      # total size per job: 128m|256m|512m|1g|2g|4g
: "${_fio_runtime:=5}"      # runtime in seconds: 5|10|15|30|60
: "${_fio_ramp:=0}"
: "${_fio_name:=test}"
: "${_fio_ioengine:=libaio}"     # sync|psync|libaio|mmap|pvsync|pvsync2
: "${_fio_randrepeat:=0}"        # 0 = varied random patterns per run (KDiskMark default)
: "${_fio_end_fsync:=1}"         # 1 = fsync after write stage (KDiskMark default)

# ===== Parameter list for SATA =====
# Format: "BASE  RW  BS   IODEPTH  NUMJOBS"
# BASE: Show in filename & summary, e.g. SEQ1MQ8T1、RND4KQ32T1. 
FIO_TESTS_SATA=(
  "SEQ1MQ8T1      read          1m      8     1"
  "SEQ1MQ8T1      write         1m      8     1"
  "SEQ1MQ1T1      read          1m      1     1"
  "SEQ1MQ1T1      write         1m      1     1"
  "RND4KQ32T1     randread      4k      32    1"
  "RND4KQ32T1     randwrite     4k      32    1"
  "RND4KQ1T1      randread      4k      1     1"
  "RND4KQ1T1      randwrite     4k      1     1"
)

# ===== Parameter list for NVMe =====
# Format: "BASE  RW  BS   IODEPTH  NUMJOBS"
# BASE: Show in filename & summary, e.g. SEQ1MQ8T1、RND4KQ32T1. 
FIO_TESTS_NVME=(
  "SEQ1MQ8T1      read          1m      8     1"
  "SEQ1MQ8T1      write         1m      8     1"
  "SEQ128KQ32T1   read          128K    32    1"
  "SEQ128KQ32T1   write         128K    32    1"
  "RND4KQ32T16    randread      4k      32    16"
  "RND4KQ32T16    randwrite     4k      32    16"
  "RND4KQ1T1      randread      4k      1     1"
  "RND4KQ1T1      randwrite     4k      1     1"
)

# ===== Summary patterns for SATA =====
FIO_SUMMARY_SATA=(
  "SEQ1MQ8T1      Read"
  "SEQ1MQ8T1      Write"
  "SEQ1MQ1T1      Read"
  "SEQ1MQ1T1      Write"
  "RND4KQ32T1     Read"
  "RND4KQ32T1     Write"
  "RND4KQ1T1      Read"
  "RND4KQ1T1      Write"
)

# ===== Summary patterns for NVMe =====
FIO_SUMMARY_NVME=(
  "SEQ1MQ8T1      Read"
  "SEQ1MQ8T1      Write"
  "SEQ128KQ32T1   Read"
  "SEQ128KQ32T1   Write"
  "RND4KQ32T16    Read"
  "RND4KQ32T16    Write"
  "RND4KQ1T1      Read"
  "RND4KQ1T1      Write"
)

# ===== Sweep mode parameters (used when disk_test.sh --sweep is given) =====
# Block sizes and queue depths mirror the DiskSpd matrix reference script.
_SWEEP_BLOCK_SIZES=(4k 8k 16k 32k 64k 128k 256k 512k 1m 2m 4m 8m)
_SWEEP_QUEUE_DEPTHS=(1 2 4 8 16 32 64 128 256 512)
_SWEEP_THREADS=1
: "${_sweep_duration:=5}"    # seconds of measured I/O per test (--runtime)
: "${_sweep_warmup:=1}"      # ramp_time seconds before measurement starts
export _SWEEP_THREADS _sweep_duration _sweep_warmup
