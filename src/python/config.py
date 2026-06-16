# config.py — default parameters for power cycle / reboot tests
#
# Every value here is a DEFAULT. Override any of them at run time by passing
# the matching CLI flag to power_cycle.py (run `python3 power_cycle.py --help`
# for the flag list). The "CLI" column below names the flag for each value.
#
# ---------------------------------------------------------------------------
# The four phases of one cycle (loop)
# ---------------------------------------------------------------------------
# A single cycle is: power the DUT on, let it run, power it off, wait. The
# total time of one cycle is the sum of four phases:
#
#   1. BOOT phase   - press power button, then poll ping+SSH until the DUT is
#                     alive. This phase ends the MOMENT the DUT responds; it is
#                     NOT a fixed wait. BOOT_TIMEOUT_SEC is only the UPPER LIMIT:
#                     if the DUT is not alive by then, the cycle is NO_BOOT.
#                     (Catches: dead board, stuck POST, stuck at logon - any
#                      case where ping+SSH never both succeed.)
#
#   2. ON_TIME      - once alive, keep the DUT running for ON_TIME_SEC seconds,
#                     probing every HEALTH_CHECK_INTERVAL seconds. If the DUT
#                     drops offline during this window the cycle is CRASH.
#                     (This is the post-boot stability / soak window.)
#
#   3. SHUTDOWN     - issue shutdown (SSH command if --ssh-user is set, else an
#                     ATX power-button press), then poll until the DUT goes
#                     offline. Ends the moment the DUT is offline; DEAD_TIMEOUT_SEC
#                     is the UPPER LIMIT. If exceeded, force-off is applied and
#                     the cycle is HANG_SHUTDOWN.
#
#   4. OFF_TIME     - fixed wait of OFF_TIME_SEC seconds before the next cycle.
#
# So one cycle ~= (actual boot time) + ON_TIME_SEC + (actual shutdown time)
#                 + OFF_TIME_SEC. Only BOOT and SHUTDOWN are variable; they end
#                 as soon as the DUT changes state, capped by their timeouts.
# ---------------------------------------------------------------------------

# ---------- PSU type ----------
# CLI: --type
POWER_TYPE = "ATX"          # "ATX" (momentary power-button press) or "AT" (hard on/off)

# ---------- GPIO ----------
GPIO_PIN         = 40       # CLI: --pin   BOARD pin number (Pin 40 = GPIO21)
GPIO_MODE        = "BOARD"  # "BOARD" or "BCM"
RELAY_ACTIVE_LOW = True     # True for most RPi relay modules (LOW = relay ON)

# ---------- ATX press durations ----------
ATX_SHORT_PRESS_SEC = 0.5   # Power on, or request soft shutdown (single button tap)
ATX_LONG_PRESS_SEC  = 5.0   # Force power off, ignores OS state (>=4 s per ATX spec)

# ---------- Test parameters ----------
CYCLES        = 1000        # CLI: --cycles   Total counted cycles to run
ON_TIME_SEC   = 90          # CLI: --on   Phase 2: how long to keep DUT on after boot.
                            #   90 s covers a dev_detect run plus a window for the
                            #   operator to abort the test before the next power-off.
OFF_TIME_SEC  = 60          # CLI: --off   Phase 4: fixed wait after power-off

# ---------- DUT test-environment restore ----------
# Fixed path of the restore helper installed on the Linux DUT by setup_dut.sh.
# Called via SSH (with sudo, NOPASSWD) when a test session completes to revert
# logind and sleep-target changes. Manual fallback: sudo ./setup_dut.sh --restore
DUT_RESTORE_HELPER    = "/usr/local/lib/automatic-testing/dut-restore-test-env"

# ---------- DUT liveness (network) ----------
DUT_HOST              = ""  # CLI: --host   IP/hostname; "" disables liveness checks
DUT_PORT              = 22  # CLI: --port   TCP port to probe (22 = SSH)
PING_COUNT            = 2   # ping -c N (ICMP echo count per probe)
PING_TIMEOUT_SEC      = 2   # ping -W N (per-echo timeout)
TCP_TIMEOUT_SEC       = 3   # TCP connect timeout for the SSH-port probe
BOOT_TIMEOUT_SEC      = 120 # CLI: --boot-timeout   Phase 1 UPPER LIMIT. DUT should
                            #   reach desktop + answer ping+SSH within ~120 s; longer
                            #   counts as NO_BOOT (a slow boot is treated as a quality
                            #   defect, not a pass).
DEAD_TIMEOUT_SEC      = 30  # Phase 3 UPPER LIMIT: max wait for DUT to go offline after
                            #   a shutdown request; exceeding it -> force-off + HANG_SHUTDOWN
HEALTH_CHECK_INTERVAL = 30  # Seconds between liveness probes during ON_TIME (phase 2)

# ---------- Shutdown ----------
SHUTDOWN_SSH_USER = ""      # CLI: --ssh-user   SSH login for graceful OS shutdown.
                            #
                            #   *** IMPORTANT for Linux DUT ***
                            #   On Linux with a GNOME desktop session, the ATX power-button
                            #   short-press is intercepted by GNOME (endSessionDialog), so
                            #   the OS does NOT shut down within dead_timeout → HANG_SHUTDOWN.
                            #   Set this to the DUT's SSH login user (e.g. "ubuntu", "adlink")
                            #   so phase 3 uses "sudo shutdown -h now" via SSH instead of the
                            #   power button.  The power button then handles only power-ON.
                            #   sudoers NOPASSWD for /sbin/shutdown is set up by setup_dut.sh.
                            #
                            #   Set   → phase 3 shuts down via SSH command; power button = ON only.
                            #   Empty → phase 3 uses ATX power-button press (fine for Windows;
                            #             causes HANG_SHUTDOWN on Linux+GNOME).
                            #   ATX force-off remains the fallback in both modes.

# ---------- Safety ----------
# Two-phase consecutive-failure policy (FWK030):
#
#   Phase 1 — EARLY: no PASS has occurred yet.
#     If the first EARLY_FAIL_THRESHOLD consecutive cycles all fail, abort the
#     run immediately. At this point failure is almost certainly a configuration
#     error (wrong host, DUT offline, bad credentials) rather than a real
#     hardware defect. Continuing would produce meaningless data.
#     Set to 0 to disable early-abort entirely.
#
#   Phase 2 — MID-RUN: at least one PASS has occurred.
#     Consecutive failures do NOT abort the run by default (MAX_CONSECUTIVE_FAILS = 0).
#     A real hardware defect must be characterised across the full N cycles, not
#     stopped mid-way; the failure-rate and distribution charts are only meaningful
#     over the full run.
#     Set MAX_CONSECUTIVE_FAILS > 0 only if you want a hard mid-run abort limit.
#
EARLY_FAIL_THRESHOLD  = 3   # CLI: --early-fail-threshold
                             #   Abort before first PASS if N consecutive cycles fail.
MAX_CONSECUTIVE_FAILS = 0   # CLI: --max-consecutive-fails
                             #   Abort mid-run after N consecutive fails (0 = never).

WARMUP_CYCLES         = 1   # CLI: --warmup   Uncounted init cycles before the counted
                            #   test (absorbs unknown initial DUT state). 0 = skip.

# ---------- DUT init / state normalisation (FWK031) ----------
# Before its first cycle, each test brings the DUT to a testable (alive) state
# via function.init_dut(), which escalates only as far as needed:
#   Step 1  DUT responds to ping OR SSH      → already testable, no action.
#   Step 2  GPIO power-on press (uses GPIO_PIN / POWER_TYPE) → handles DUT-is-OFF.
#   Step 3  GPIO force-off + power-on        → handles DUT-is-HUNG.
# The GPIO pin for recovery is GPIO_PIN (above) — the same relay used by
# power_cycle.py. No separate init pin is needed.
INIT_WAIT_SEC = 0           # CLI: --init-wait
                            #   GPIO-unavailable fallback ONLY. When no relay/pin is
                            #   configured and the DUT is offline, wait up to this many
                            #   seconds for a powered-but-still-booting DUT (BIOS/POST).
                            #   0 = fail immediately. Ignored when a GPIO pin is available
                            #   (GPIO power recovery is used instead).

# ---------- DUT operating system ----------
# CLI: --dut-os   Set to "windows" or "linux" to match the DUT.
# This selects the correct default SSH commands for reboot and graceful shutdown.
# Override the individual commands at runtime with --ssh-cmd if needed.
# When SHUTDOWN_SSH_USER is set, the OS is auto-detected via SSH at startup
# (uname -s) and this default is used as a fallback when the DUT is offline
# at test start (SSH returns exit 255 → "unknown" → falls back to this value).
# Set this to match your DUT's OS so the fallback is always correct.
DUT_OS = "linux"

# OS-specific SSH command defaults.  Not intended to be set directly;
# scripts derive their defaults from these dicts using DUT_OS or --dut-os.
_OS_REBOOT_CMD = {
    "windows": "shutdown /r /t 0",     # immediate restart via Windows shutdown utility
    "linux":   "sudo reboot",           # requires NOPASSWD for /sbin/reboot in sudoers
}
_OS_SHUTDOWN_CMD = {
    "windows": "shutdown /s /t 5",     # graceful shutdown, 5-s countdown
    "linux":   "sudo shutdown -h now",  # requires NOPASSWD for /sbin/shutdown in sudoers
}

# ---------- Reboot test (reboot.py) ----------
REBOOT_SSH_CMD    = _OS_REBOOT_CMD[DUT_OS]  # derived from DUT_OS; override with --ssh-cmd
REBOOT_SETTLE_SEC = 5                        # Seconds to wait after SSH reboot command before
                                             #   starting to poll for the DUT going offline.
                                             #   Gives the OS time to begin its reboot sequence.

# ---------- Sleep / suspend test (sleep_test.py) ----------
# sleep_test.py is the Pi-controlled (control-node) sleep-wake endurance test.
# It mirrors reboot.py: it does NOT put the DUT to sleep itself (a sleeping DUT
# has no network), it SSH-invokes the DUT-local helper (sleep_test.ps1 -OneShot)
# which arms a software RTC wake timer and then suspends; the Pi then confirms
# the transition purely by network liveness (offline = slept, back online = woke).
#
# One cycle (loop) per SLP002/SLP003:
#   1. DUT sits in Windows for SLEEP_PRE_DELAY_SEC seconds (settle / soak).
#   2. SSH-invoke the DUT helper: arm a wake timer for SLEEP_WAKE_AFTER_SEC s,
#      then enter the chosen sleep state (S3 = sleep, S4 = hibernate).
#   3. Wait for the DUT to go offline  (entered sleep)  - capped by SLEEP_DEAD_TIMEOUT_SEC.
#   4. Wait for the DUT to come back online (RTC woke it) - capped by SLEEP_WAKE_TIMEOUT_SEC.
#   Verdict: PASS only if it both slept and woke within the timeouts.
SLEEP_CYCLES            = 1000  # CLI: --cycles   Counted sleep-wake cycles PER sleep state.
SLEEP_STATES           = "auto" # CLI: --states   "auto" (test every supported state among
                                #   S3/S4), or an explicit comma list e.g. "S3", "S4", "S3,S4".
SLEEP_PRE_DELAY_SEC    = 30     # CLI: --pre-delay   Phase 1: seconds in Windows before sleeping.
SLEEP_WAKE_AFTER_SEC   = 10     # CLI: --wake-after  RTC wake timer: seconds asleep before wake.
SLEEP_DEAD_TIMEOUT_SEC = 60     # UPPER LIMIT: max wait for the DUT to go offline after the sleep
                                #   command; exceeding it -> NO_SLEEP (the DUT never suspended).
SLEEP_WAKE_TIMEOUT_SEC = 120    # CLI: --wake-timeout   UPPER LIMIT: max wait for the DUT to come
                                #   back online after it slept; exceeding it -> NO_WAKE (stuck asleep).
# Remote path of the DUT-local helper that arms the wake timer and suspends.
# Invoked over SSH as: powershell -ExecutionPolicy Bypass -File <this> -OneShot -State <S> -WakeAfter <n>
SLEEP_REMOTE_HELPER    = r"C:\TestAutomation\sleep_test.ps1"  # CLI: --remote-helper

# ---------- Output ----------
LOG_DIR    = "./logs"       # CLI: --out      Where to write result.json and .log
REPORT_DIR = "./logs"       # CLI: --report   Where to write _report.html (may differ from LOG_DIR)
