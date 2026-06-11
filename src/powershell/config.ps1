# config.ps1 - the single source of tunable parameters for the PowerShell tools.
#
# SET001: every tunable parameter (cycle counts, timeouts, delays, sleep states,
# etc.) lives HERE, not scattered inside the individual test scripts.  Each tool
# (reboot.ps1, sleep_test.ps1, dev_detect.ps1, ...) dot-sources this file and
# reads its defaults from the variables below.  Command-line parameters always
# override these values (a parameter wins only when it is explicitly passed).
#
# RULES for this file:
#   * Assignments only - keep it SIDE-EFFECT FREE.  No file writes, no New-Item,
#     no Get-Content, no path computation.  Any tool must be able to dot-source
#     this file at any time without surprises (it is loaded by scripts running
#     under `Set-StrictMode -Version Latest`).
#   * ASCII only.  PowerShell 5.1 on a Traditional Chinese / CP950 Windows
#     misparses non-ASCII bytes in a BOM-less UTF-8 file.
#   * Do NOT compute $_script_root / $_log_path here; each tool resolves those
#     itself relative to its own location.

# ======================================================================
# Reboot test  (reboot.ps1, PWR011)
# ======================================================================
# One cycle = the DUT issues a software reboot of itself, Task Scheduler
# re-launches reboot.ps1 -Resume on the next boot, and that boot is recorded.
$_reboot_cycles     = 1000   # Counted reboot cycles for a NEW session.
$_reboot_settle_sec = 30     # Countdown (seconds) shown before each reboot fires.

# ======================================================================
# Sleep / suspend test  (sleep_test.ps1, SLP002 / SLP003)
# ======================================================================
# One counted sleep-wake cycle (loop):
#   1. Sit in Windows for $_sleep_pre_delay_sec seconds (settle / soak).
#   2. Arm a software RTC wake timer for $_sleep_wake_after_sec seconds, then
#      enter the chosen sleep state (S3 = sleep, S4 = hibernate).
#   3. The RTC fires and wakes the DUT; the running script resumes and records
#      the cycle.
$_sleep_cycles         = 1000     # Counted cycles to run PER sleep state.
$_sleep_states         = 'auto'   # 'auto' = every supported state among S3/S4,
                                  #   or an explicit list: 'S3', 'S4', 'S3,S4'.
$_sleep_pre_delay_sec  = 30       # Seconds in Windows before each sleep transition.
$_sleep_wake_after_sec = 10       # RTC wake timer: seconds asleep before waking.
$_sleep_settle_sec     = 5        # Grace period after wake before the next cycle begins.

# ======================================================================
# Network test  (net_test.ps1, NET001-NET013)
# ======================================================================
# Pairs of physical Ethernet NICs are tested back-to-back (directly cabled).
# Isolation is achieved by assigning each pair a private /24 subnet
# (192.247.{idx}.0/24 + fd00:2470::{idx}:0/64) with no default gateway,
# matching what Linux network namespaces provide on the bash side.
$_net_loops            = 1    # Test loop count (each loop runs all pairs once).
$_net_iperf_time_sec   = 60   # NET007: iperf3 test duration per direction (seconds).
$_net_iperf_omit_sec   = 3    # NET007: seconds to omit at start (ramp-up exclusion).
$_net_tcp_pass_pct     = 95   # NET009: default TCP PASS threshold as % of link speed,
                              #   used for any speed not listed in $_net_tcp_pass_pct_tiers.
$_net_tcp_pass_pct_tiers = '10:90,100:90,1000:95,2500:95,5000:95,10000:95'
                              # NET009: per-speed-tier override, "speedMbps:pct,...".
                              #   TCP overhead is proportionally larger at lower link
                              #   speeds (measured ~94-95% at 100M is normal), so 100M
                              #   and below default to a 90% threshold while 1000M+
                              #   keeps 95%. Adjust per DUT/site policy.
$_net_strict_lifeline  = 1    # NET012: 1 = warn and auto-exclude any NIC whose MAC
                              #   matches $_net_exclude_macs if it appears in the test set.
$_net_exclude_macs     = ''   # NET012: comma-separated MAC addresses of management /
                              #   control NICs that must NEVER be tested, regardless of
                              #   vendor filter or NIC name.  Matching is case-insensitive;
                              #   both colon (AA:BB:CC:DD:EE:FF) and hyphen
                              #   (AA-BB-CC-DD-EE-FF) separators are accepted.
                              #   Supports multiple entries for multi-management-NIC
                              #   setups (e.g. one control USB NIC + one spare USB NIC).
                              #   When empty, net_test.ps1 falls back to excluding the
                              #   NIC carrying the active SSH/RDP session (nothing is
                              #   excluded on a local-console run).  Set this to pin the
                              #   management NIC(s) for unattended / Ansible-driven runs.
                              #   Example (single): '00-50-56-C0-00-08'
                              #   Example (two):    '00-50-56-C0-00-08, AA-BB-CC-DD-EE-FF'
# Multi-speed testing (NET004): each NIC is driven at every link speed it
# advertises (10/100/1000/2500/10000 Mbps, ...), set via the *SpeedDuplex
# advanced property.  A pair is tested only at speeds BOTH NICs support.
$_net_speeds           = 'auto'  # 'auto' = every speed both NICs in a pair support;
                                 #   or an explicit list e.g. '100,1000' / '1000,10000'.
$_net_vendor_filter    = 'Intel' # Only test NICs whose description matches this string
                                 #   ('' = all vendors).  Intel exposes a predictable
                                 #   *SpeedDuplex enum, so it is the supported default.
$_net_link_wait_sec    = 30      # Max seconds to wait for the link to re-establish at a
                                 #   new speed before recording that speed as UNKNOWN.
$_net_link_wait_autoneg_sec = 90 # NET004: 1000BASE-T and faster require auto-negotiation
                                 #   on copper -- a forced fixed speed never links.  When a
                                 #   >=1000M force fails, net_test.ps1 retries with Auto
                                 #   Negotiation and waits up to this many seconds for both
                                 #   NICs to converge on the same speed (renegotiation after
                                 #   a PHY reset is slower than a normal forced-speed wait).
# iperf3 auto-install (mirrors the bash side's apt-get/dnf "ensure tool" logic).
# If iperf3 is not already in PATH, net_test.ps1 tries to install it the same way
# net_test.sh does on Linux -- here via the Windows package managers, newest to
# oldest, then a portable-zip download as a no-package-manager fallback.
$_net_iperf3_auto_install = 1                  # 1 = install iperf3 if missing; 0 = error out.
$_net_iperf3_winget_id    = 'ar51an.iPerf3'    # winget package id (built into Win10 1809+/11).
$_net_iperf3_choco_pkg    = 'iperf3'           # Chocolatey package name.
$_net_iperf3_scoop_pkg    = 'iperf3'           # Scoop package name (main bucket).
# Portable-zip fallback when NO package manager is present: the script queries
# this GitHub repo's latest release and downloads the asset ending in the pattern
# below into tools\iperf3 beside the script, then prepends it to PATH for the run.
$_net_iperf3_gh_repo      = 'ar51an/iperf3-win-builds'  # '' disables the download fallback.
$_net_iperf3_zip_pattern  = 'win64.zip'                 # asset suffix to pick (the plain build).
