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
