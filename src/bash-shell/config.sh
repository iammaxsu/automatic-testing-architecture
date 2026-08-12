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

# ---------- Liveness heartbeat (FWK038) ----------
# How often the console is told the test is still alive, in seconds. This is the
# operator's evidence that a long silent step is slow rather than hung; it is NOT
# the "do not power off" broadcast to other users, which stays on its per-loop
# cadence so it does not become spam.
#
# The value bounds how long the console may sit unchanged. Keep it well under the
# time an operator would wait before concluding the run has died. 0 disables the
# heartbeat entirely (e.g. when the output is being captured to a file that
# should not carry it).
: "${_heartbeat_interval_sec:=30}"
export _heartbeat_interval_sec

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
: "${_net_iperf_overhead_sec:=5}"
                                 # FWK038: allowance, in seconds, for connection setup
                                 #   and the closing statistics exchange. Used ONLY to
                                 #   size the progress bar, never to bound the transfer.
                                 #   The bar's denominator is time + omit + this, so it
                                 #   reaches 100% about when a healthy step ends and
                                 #   "(still running)" keeps meaning "this one is
                                 #   unusual" rather than appearing on every transfer.
: "${_net_iperf_overrun_grace_sec:=30}"
                                 # FWK038: how far past the estimate a step may run
                                 #   before the bar raises "(still running)". The bar
                                 #   showing "88s / 68s" already says it is slower than
                                 #   predicted; this is the point at which that stops
                                 #   being normal variation and becomes worth flagging.
                                 #   Sized above the worst legitimate overrun seen (UDP
                                 #   teardown at 400G, ~20s) and well below a TCP connect
                                 #   timeout (~2 min), which is what the marker is for.
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

# NET017: UDP datagram-loss reporting and optional gating.
# iperf3 UDP is offered at the full link rate with no flow control, so some loss
# is the expected outcome, not a defect -- double-digit percentages at 100G are
# normal. Loss is therefore REPORTED by default and only judged if you opt in.
: "${_net_udp_loss_max_pct:=1}"  # highlight (and, if gating is on, fail) above this %
: "${_net_udp_loss_fail:=0}"     # 1 = a UDP loss above the cap downgrades the verdict

# NET004/BUG0056: how long to wait for carrier after setting a link speed.
# `ethtool -s` returns as soon as the driver accepts the request; the link comes
# up asynchronously, and a high-speed DAC link with RS-FEC can take far longer
# than the 4-second blind sleep this replaced. Too short a wait makes a healthy
# NIC look like a dead cable.
: "${_net_link_up_timeout_sec:=30}"

# NET007/NET009: parallel iperf3 streams (-P). Default 1 = single stream.
#
# A single TCP stream is bounded by one CPU core's ability to drive the stack,
# not by the link: on this class of hardware it plateaus around 75-85 Gbit/s
# whatever the link is set to. At 100G and above the NET009 threshold of 95% of
# link speed is therefore unreachable by construction, and every such row fails
# for a reason that says nothing about the NIC.
#
# Raise this to measure what the LINK can do (4-8 is typical for 100G+); leave it
# at 1 to measure what a single stream can do. They are different questions, so
# the default is not changed silently -- pick the one you mean.
: "${_net_iperf_parallel:=1}"

: "${_net_test_bidir:=1}"        # NET017: 1 = also run a simultaneous bidirectional
                                 #   (full-duplex) iperf3 pass at each speed.
: "${_net_test_jumbo:=1}"        # NET018: 1 = at each >=1000M speed verify a DF jumbo
                                 #   ping crosses the link, then restore the MTU.
: "${_net_jumbo_mtu:=9000}"      # NET018: jumbo MTU to test (bytes); DF payload = MTU-28.

# NET019: which interface NAMES are even considered for testing. Linux predictable
# names: enp* = PCI/onboard Ethernet (Intel etc.), enx* = USB Ethernet (name carries
# the MAC), eno* = onboard, eth* = legacy. The default tests only enp* — this both
# matches the usual Intel-NIC target and conveniently skips USB management NICs.
# Broaden it to also test USB NICs, e.g. ^(enp|enx), or everything: ^(enp|enx|eno|eth).
# Extended regex (grep -E). MAC include/exclude below applies to whatever this matches,
# so when you broaden this, ALSO pin the management/SSH NIC via _net_exclude_macs (or
# use _net_include_macs to whitelist only the NICs you want) to avoid testing it.
# NOTE: do NOT wrap the value in quotes here — in the `: "${var:=...}"` form the inner
# quotes become part of the value. Write it bare, e.g.  _net_nic_name_regex:=^(enp|enx)
# (surrounding quotes are stripped defensively, but bare is the intended form).
: "${_net_nic_name_regex:=^enp}"

# NET019: select which NICs participate, by MAC address. A MAC is the most
# stable, OS-independent NIC identity (unlike enpXsY names). Both lists accept
# multiple entries separated by comma, semicolon, or whitespace; matching is
# case-insensitive and both ':' and '-' separators are accepted. CLI overrides:
# --include-mac / --exclude-mac (each overrides the matching list for that run).
# As above, write the value BARE (no surrounding quotes) in the `: "${var:=...}"`
# form, e.g.  _net_include_macs:=00-E0-4C-68-00-56,00-E0-4C-68-00-2D
# (stray surrounding/embedded quotes are stripped defensively, but bare is intended).
: "${_net_include_macs:=}"       # NET019: whitelist. When non-empty, ONLY NICs whose
                                 #   MAC matches an entry are tested; all others become
                                 #   SKIPPED. Empty = every NIC is a candidate.
                                 #   Example (two): 00-E0-4C-68-00-56,00-E0-4C-68-00-2D
: "${_net_exclude_macs:=}"       # NET019 / NET012: blacklist. NICs whose MAC matches an
                                 #   entry are never tested — use it to pin the management
                                 #   / SSH-lifeline NIC so net_test never reconfigures it.
                                 #   Exclude wins over include. Example (single):
                                 #   00-E0-4C-68-00-56   Example (two):
                                 #   00-E0-4C-68-00-56,AA-BB-CC-DD-EE-FF

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
