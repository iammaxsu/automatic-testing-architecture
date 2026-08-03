#!/usr/bin/env bash
# run_tests.sh — Composite test runner: power_cycle.py then reboot.py
#
# Runs power_cycle.py (Phase 1) and/or reboot.py (Phase 2) from the same
# directory.  Either phase is skipped when its --*-cycles argument is 0.
#
# Usage:
#   ./run_tests.sh --host 192.168.1.100 --ssh-user max \
#                  --power-cycles 10 --reboot-cycles 20
#
# Exit code:
#   0 — all executed phases passed (PASS)
#   1 — at least one phase failed, or both phases were skipped

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: run_tests.sh [options]

Composite test runner: power_cycle.py (Phase 1) then reboot.py (Phase 2).
At least one of --power-cycles or --reboot-cycles must be greater than 0.

Required:
  --host IP_OR_HOST        DUT IP or hostname
  --ssh-user USERNAME      SSH login (required for reboot phase;
                           optional for power_cycle graceful shutdown)

Phase selection:
  --power-cycles N         power cycle iterations  (default: 0 = skip)
  --reboot-cycles N        software reboot iterations (default: 0 = skip)

Common options:
  --out DIR                output root directory (default: logs)
  --port N                 SSH/liveness TCP port (default: from config.py)
  --dut-os OS              auto|windows|linux     (default: auto)
  --boot-timeout N         max seconds to wait for DUT boot (default: 120)
  --off N                  off/settle wait between cycles in seconds
  --early-fail-threshold N abort if first N cycles all fail before any PASS (default: 3)
  --max-consecutive-fails N abort after N consecutive mid-run failures; 0 = never (default: 0)
  --no-check               disable liveness checks
  --dry-run                simulate without touching GPIO or SSH
  --new-session            force new sessions; do not resume incomplete ones
  --resume                 resume incomplete sessions regardless of age
  --resume-max-age HOURS   auto-resume only sessions updated within HOURS
                           (default: 24; 0 disables auto-resume)

GPIO / power control (both phases):
  --type ATX|AT            PSU type (default: from config.py)
  --pin N                  GPIO board pin (default: config.GPIO_PIN). Used by
                           power_cycle for every cycle, and by reboot's init to
                           recover the DUT if it is offline at start (FWK031).

Power cycle only:
  --on N                   DUT on-time per cycle in seconds

Reboot init only:
  --init-wait N            GPIO-unavailable fallback: seconds to wait for a powered-
                           but-still-booting DUT; 0 = fail immediately (default: 0).
                           Ignored when a GPIO pin is available (GPIO recovery is used).
EOF
}

# ── Defaults ──────────────────────────────────────────────────────────────────

OPT_HOST=""
OPT_SSH_USER=""
OPT_POWER_CYCLES=0
OPT_REBOOT_CYCLES=0
OPT_OUT="logs"
OPT_PORT=""
OPT_DUT_OS=""
OPT_BOOT_TIMEOUT=""
OPT_ON=""
OPT_OFF=""
OPT_TYPE=""
OPT_PIN=""
OPT_EARLY_FAIL_THRESHOLD=""
OPT_MAX_CONSEC_FAILS=""
OPT_NO_CHECK=0
OPT_DRY_RUN=0
OPT_NEW_SESSION=0
OPT_RESUME=0
OPT_RESUME_MAX_AGE=""
OPT_INIT_WAIT=""

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)           OPT_HOST="$2";          shift 2 ;;
        --ssh-user)       OPT_SSH_USER="$2";      shift 2 ;;
        --power-cycles)   OPT_POWER_CYCLES="$2";  shift 2 ;;
        --reboot-cycles)  OPT_REBOOT_CYCLES="$2"; shift 2 ;;
        --out)            OPT_OUT="$2";           shift 2 ;;
        --port)           OPT_PORT="$2";          shift 2 ;;
        --dut-os)         OPT_DUT_OS="$2";        shift 2 ;;
        --boot-timeout)   OPT_BOOT_TIMEOUT="$2";  shift 2 ;;
        --on)             OPT_ON="$2";            shift 2 ;;
        --off)            OPT_OFF="$2";           shift 2 ;;
        --type)           OPT_TYPE="$2";          shift 2 ;;
        --pin)            OPT_PIN="$2";           shift 2 ;;
        --early-fail-threshold)  OPT_EARLY_FAIL_THRESHOLD="$2"; shift 2 ;;
        --max-consecutive-fails) OPT_MAX_CONSEC_FAILS="$2";    shift 2 ;;
        --init-wait)      OPT_INIT_WAIT="$2";      shift 2 ;;
        --no-check)       OPT_NO_CHECK=1;           shift   ;;
        --dry-run)        OPT_DRY_RUN=1;            shift   ;;
        --new-session)    OPT_NEW_SESSION=1;         shift   ;;
        --resume)         OPT_RESUME=1;              shift   ;;
        --resume-max-age) OPT_RESUME_MAX_AGE="$2";  shift 2 ;;
        --help|-h)        usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────

if [[ "$OPT_POWER_CYCLES" -eq 0 && "$OPT_REBOOT_CYCLES" -eq 0 ]]; then
    echo "ERROR: At least one of --power-cycles N or --reboot-cycles N must be > 0." >&2
    exit 1
fi

# ── Build common arg array ────────────────────────────────────────────────────
# These arguments are forwarded to both sub-scripts when they apply.

COMMON_ARGS=()
[[ -n "$OPT_HOST"                ]] && COMMON_ARGS+=(--host                 "$OPT_HOST")
[[ -n "$OPT_SSH_USER"            ]] && COMMON_ARGS+=(--ssh-user             "$OPT_SSH_USER")
[[ -n "$OPT_PORT"                ]] && COMMON_ARGS+=(--port                 "$OPT_PORT")
[[ -n "$OPT_DUT_OS"              ]] && COMMON_ARGS+=(--dut-os               "$OPT_DUT_OS")
[[ -n "$OPT_BOOT_TIMEOUT"        ]] && COMMON_ARGS+=(--boot-timeout         "$OPT_BOOT_TIMEOUT")
[[ -n "$OPT_OFF"                 ]] && COMMON_ARGS+=(--off                  "$OPT_OFF")
[[ -n "$OPT_TYPE"                ]] && COMMON_ARGS+=(--type                 "$OPT_TYPE")
[[ -n "$OPT_PIN"                 ]] && COMMON_ARGS+=(--pin                  "$OPT_PIN")
[[ -n "$OPT_EARLY_FAIL_THRESHOLD" ]] && COMMON_ARGS+=(--early-fail-threshold "$OPT_EARLY_FAIL_THRESHOLD")
[[ -n "$OPT_MAX_CONSEC_FAILS"    ]] && COMMON_ARGS+=(--max-consecutive-fails "$OPT_MAX_CONSEC_FAILS")
[[ "$OPT_NO_CHECK"    -eq 1      ]] && COMMON_ARGS+=(--no-check)
[[ "$OPT_DRY_RUN"     -eq 1      ]] && COMMON_ARGS+=(--dry-run)
[[ "$OPT_NEW_SESSION" -eq 1      ]] && COMMON_ARGS+=(--new-session)
[[ "$OPT_RESUME"      -eq 1      ]] && COMMON_ARGS+=(--resume)
[[ -n "$OPT_RESUME_MAX_AGE"      ]] && COMMON_ARGS+=(--resume-max-age "$OPT_RESUME_MAX_AGE")

# ── State tracking ────────────────────────────────────────────────────────────

PC_VERDICT="SKIPPED"
RB_VERDICT="SKIPPED"

SEP="================================================================"

# ── Phase 1: power_cycle ──────────────────────────────────────────────────────

if [[ "$OPT_POWER_CYCLES" -gt 0 ]]; then
    echo "$SEP"
    echo "PHASE 1 — Power Cycle Test  ($OPT_POWER_CYCLES cycles)"
    echo "$SEP"

    PC_OUT="$OPT_OUT/power_cycle"
    PC_ARGS=("${COMMON_ARGS[@]}" --cycles "$OPT_POWER_CYCLES" --out "$PC_OUT")
    [[ -n "$OPT_ON" ]] && PC_ARGS+=(--on "$OPT_ON")

    set +e
    python3 "$SCRIPT_DIR/power_cycle.py" "${PC_ARGS[@]}"
    PC_EXIT=$?
    set -e

    PC_VERDICT="$([[ $PC_EXIT -eq 0 ]] && echo "PASS" || echo "FAIL")"
    echo ""
    echo "Phase 1 result: $PC_VERDICT  (exit $PC_EXIT)"
    echo ""
fi

# ── Phase 2: reboot ───────────────────────────────────────────────────────────

if [[ "$OPT_REBOOT_CYCLES" -gt 0 ]]; then
    echo "$SEP"
    echo "PHASE 2 — Software Reboot Test  ($OPT_REBOOT_CYCLES cycles)"
    echo "$SEP"

    RB_OUT="$OPT_OUT/reboot"
    RB_ARGS=("${COMMON_ARGS[@]}" --cycles "$OPT_REBOOT_CYCLES" --out "$RB_OUT")
    [[ -n "$OPT_INIT_WAIT" ]] && RB_ARGS+=(--init-wait "$OPT_INIT_WAIT")

    set +e
    python3 "$SCRIPT_DIR/reboot.py" "${RB_ARGS[@]}"
    RB_EXIT=$?
    set -e

    RB_VERDICT="$([[ $RB_EXIT -eq 0 ]] && echo "PASS" || echo "FAIL")"
    echo ""
    echo "Phase 2 result: $RB_VERDICT  (exit $RB_EXIT)"
    echo ""
fi

# ── Combined summary ──────────────────────────────────────────────────────────

echo "$SEP"
echo "COMPOSITE TEST SUMMARY"
echo "$SEP"
printf "  %-32s  %s\n" "Power Cycle  (${OPT_POWER_CYCLES} cycles):"  "$PC_VERDICT"
printf "  %-32s  %s\n" "Software Reboot  (${OPT_REBOOT_CYCLES} cycles):" "$RB_VERDICT"
echo ""

OVERALL="PASS"
if [[ "$PC_VERDICT" == "FAIL" || "$RB_VERDICT" == "FAIL" ]]; then
    OVERALL="FAIL"
elif [[ "$PC_VERDICT" == "SKIPPED" && "$RB_VERDICT" == "SKIPPED" ]]; then
    OVERALL="NO_DATA"
fi

echo "  OVERALL: $OVERALL"
echo "$SEP"

if [[ "$OVERALL" == "PASS" ]]; then
    exit 0
else
    exit 1
fi
