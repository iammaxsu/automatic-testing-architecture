# sleep_config.ps1 - default parameters for the DUT-local sleep test (sleep_test.ps1)
#
# This is the "config file" half of sleep_test.ps1's two configuration methods;
# the other half is command-line parameters, which always override these values.
# (A parameter wins only when it is explicitly passed; otherwise the value here
# is used. See sleep_test.ps1's parameter-resolution block.)
#
# Keep this file side-effect free: assignments only, ASCII only (PowerShell 5.1
# on a Traditional Chinese / CP950 Windows misparses non-ASCII in BOM-less UTF-8).

# One counted sleep-wake cycle (loop), per SLP002 / SLP003:
#   1. Sit in Windows for $_sleep_pre_delay_sec seconds (settle / soak).
#   2. Arm a software RTC wake timer for $_sleep_wake_after_sec seconds, then
#      enter the chosen sleep state (S3 = sleep, S4 = hibernate).
#   3. The RTC fires and wakes the DUT; the running script resumes and records
#      the cycle.

$_sleep_cycles          = 1000     # Counted cycles to run PER sleep state.
$_sleep_states          = 'auto'   # 'auto' = every supported state among S3/S4,
                                   #   or an explicit list: 'S3', 'S4', 'S3,S4'.
$_sleep_pre_delay_sec   = 30       # Seconds in Windows before each sleep transition.
$_sleep_wake_after_sec  = 10       # RTC wake timer: seconds asleep before waking.
$_sleep_settle_sec      = 5        # Grace period after wake before the next cycle begins.
