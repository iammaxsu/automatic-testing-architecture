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
                            #   Set -> phase 3 sends "shutdown /s /t 5" over SSH and the
                            #     power button is used ONLY to power on.
                            #   Empty -> phase 3 powers off with an ATX button press
                            #     instead (two presses per cycle: on, then off).
                            #   ATX force-off remains the fallback in both modes.

# ---------- Safety ----------
MAX_CONSECUTIVE_FAILS = 3   # Abort the run after N consecutive failed cycles (0 = never)
WARMUP_CYCLES         = 1   # CLI: --warmup   Uncounted init cycles before the counted
                            #   test (absorbs unknown initial DUT state). 0 = skip.

# ---------- Reboot test (reboot.py) ----------
REBOOT_SSH_CMD    = "shutdown /r /t 0"  # Command sent over SSH to reboot the DUT.
                                        #   Windows: "shutdown /r /t 0"  (restart, 0-s delay)
                                        #   Linux:   "sudo reboot"  (requires NOPASSWD for reboot)
REBOOT_SETTLE_SEC = 5                   # Seconds to wait after SSH reboot command before
                                        #   starting to poll for the DUT going offline.
                                        #   Gives the OS time to begin its reboot sequence.

# ---------- Output ----------
LOG_DIR    = "./logs"       # CLI: --out      Where to write result.json and .log
REPORT_DIR = "./logs"       # CLI: --report   Where to write _report.html (may differ from LOG_DIR)
