# config.py — default parameters for power cycle tests
# Override any value by passing CLI args to power_cycle.py,
# or by setting environment variables before import.

# ---------- PSU type ----------
POWER_TYPE = "ATX"          # "ATX" or "AT"

# ---------- GPIO ----------
GPIO_PIN         = 40       # BOARD pin number (Pin 40 = GPIO21)
GPIO_MODE        = "BOARD"  # "BOARD" or "BCM"
RELAY_ACTIVE_LOW = True     # True for most RPi relay modules (LOW = relay ON)

# ---------- ATX press durations ----------
ATX_SHORT_PRESS_SEC = 0.5   # Normal power on / soft shutdown request
ATX_LONG_PRESS_SEC  = 5.0   # Force power off (≥4 s spec)

# ---------- Test parameters ----------
CYCLES        = 1000        # Total boot cycles to run
ON_TIME_SEC   = 300         # How long to keep DUT powered on per cycle
OFF_TIME_SEC  = 60          # How long to wait after power-off before next cycle

# ---------- DUT liveness (network) ----------
DUT_HOST              = ""  # IP or hostname; set "" to disable liveness checks
DUT_PORT              = 22  # TCP port to probe (22 = SSH)
PING_COUNT            = 2   # ping -c N
PING_TIMEOUT_SEC      = 2   # ping -W N
TCP_TIMEOUT_SEC       = 3   # TCP connect timeout
BOOT_TIMEOUT_SEC      = 180 # Max seconds to wait for DUT to come online after power-on
DEAD_TIMEOUT_SEC      = 30  # Max seconds to wait for DUT to go offline after power-off
HEALTH_CHECK_INTERVAL = 30  # Seconds between liveness probes during ON_TIME

# ---------- Shutdown ----------
SHUTDOWN_SSH_USER = ""      # SSH username for graceful shutdown; empty = skip SSH method

# ---------- Safety ----------
MAX_CONSECUTIVE_FAILS = 3   # Abort test after N consecutive failures (0 = never)
WARMUP_CYCLES         = 1   # Initialization cycles before the counted test begins (0 = skip)

# ---------- Output ----------
LOG_DIR    = "./logs"       # Where to write result.json and .log
REPORT_DIR = "./logs"       # Where to write _report.html (can differ from LOG_DIR)
