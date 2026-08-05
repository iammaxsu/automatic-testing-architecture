# config.py - default settings for the BMC / IPMI Robot Framework suites.
#
# Layered configuration (SET006), highest priority first:
#
#   1. Robot CLI            -v BMC_HOST:10.0.0.124   (per-run override)
#   2. Environment          IPMI_PASSWORD=...        (credentials only)
#   3. config_local.py      site/bench-specific values, NOT in version control
#   4. this file            the canonical, documented defaults
#
# CREDENTIALS: leave IPMI_PASSWORD empty here. This repository is public, so
# the password belongs in config_local.py (git-ignored) or in the environment.
# Copy config_local.py.example to config_local.py and edit it once; every run
# then picks it up with no `export` needed. The password is passed to ipmitool
# through the environment (-E), never on a command line, so it stays out of
# `ps` output and out of logs.
#
# This file holds plain constants and comments only - no logic, no imports
# (SET006). The resolution order above is implemented in lib/BMCLibrary.py.

# ---------- BMC connection ----------
BMC_HOST = ""              # CLI: -H / -v BMC_HOST    BMC IP or hostname.
BMC_USER = "admin"         # CLI: -v BMC_USER         IPMI account.
IPMI_PASSWORD = ""         # Put the real password in config_local.py instead.
IPMI_INTERFACE = "lanplus" # CLI: -v IPMI_IFACE       IPMI 2.0 = lanplus.

# ---------- ipmitool call behaviour ----------
IPMI_TIMEOUT = 60          # Seconds before one ipmitool call is abandoned.
IPMI_RETRIES = 3           # Attempts per call; transient lanplus errors retry.
IPMI_RETRY_DELAY = 5       # Seconds between attempts.

# ---------- Output layout (LOG025) ----------
LOG_ROOT = "logs"          # CLI: -o    Runs land in <LOG_ROOT>/<dut>/<session>/.

# ---------- Board-specific expectations ----------
# Sensor names differ per board; list them with:
#   ipmitool -I lanplus -H <host> -U <user> -E sensor list
SENSOR_TEMP = "CPU_Temp"   # Temperature sensor asserted to read 'ok'.
SENSOR_VOLT = "5V_DUAL"    # Voltage rail asserted to read 'ok' and in range.
VOLT_MIN = 4.5             # Lower bound for SENSOR_VOLT, in volts.
VOLT_MAX = 5.5             # Upper bound for SENSOR_VOLT, in volts.
LAN_CHANNEL = 1            # BMC LAN channel for `lan print` (some boards use 8).
USER_CHANNEL = 1           # Channel for `user list`.
EXPECTED_USER = "admin"    # Account that must exist in `user list`.

# ---------- Power control (destructive; gated) ----------
POWER_TESTS_ENABLED = False # CLI: -v POWER_TESTS_ENABLED:True to allow at all.
POWER_CYCLES = 1            # CLI: -v POWER_CYCLES      Iterations for endurance.
POWER_OFF_TIMEOUT = 60      # Upper limit waiting for the board to reach 'off'.
POWER_ON_TIMEOUT = 180      # Upper limit waiting for the board to reach 'on'.
POWER_OFF_TIME = 60         # Fixed off-time before powering on again. PWR010
                            # phase 4; too short and the power-on command is
                            # accepted but ignored (BUG0028).
POWER_TRANSITION_TIMEOUT = 30  # Window for observing the off dip after a cycle,
                            # and the interval before a power-on is re-issued.

# ---------- DUT liveness (optional, for power tests) ----------
DUT_HOST = ""              # CLI: -v DUT_HOST    DUT *OS* IP (not the BMC). When
                           # set, recovery also waits for the OS to answer ping.
DUT_BOOT_TIMEOUT = 300     # Upper limit waiting for the DUT OS after power-on.
