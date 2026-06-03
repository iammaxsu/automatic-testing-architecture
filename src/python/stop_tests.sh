#!/usr/bin/env bash
# stop_tests.sh — Emergency stop: halt all running tests (the red button)
#
# Pi side:  sends SIGINT to any running power_cycle.py or reboot.py processes
# DUT side: SSHes to the DUT and runs 'reboot.ps1 -Stop' (requires --host,
#           --ssh-user, and --dut-ps1)
#
# Usage:
#   ./stop_tests.sh
#     Stop Pi-side Python processes only.
#
#   ./stop_tests.sh --host 192.168.1.100 --ssh-user max \
#                   --dut-ps1 "C:\path\to\reboot.ps1"
#     Stop Pi-side processes AND send -Stop to reboot.ps1 on the DUT.
#
# Exit code:
#   0 — stop commands sent (or nothing was running)
#   1 — one or more stop operations failed

set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: stop_tests.sh [options]

Emergency stop: immediately halt all running tests.

  Pi side:  sends SIGINT to any running power_cycle.py or reboot.py processes
  DUT side: SSHes to the DUT and runs reboot.ps1 -Stop (if --host is set)

Options:
  --host IP_OR_HOST        DUT IP or hostname  (required for DUT-side stop)
  --ssh-user USERNAME      SSH login           (required for DUT-side stop)
  --port N                 SSH port            (default: 22)
  --dut-ps1 WIN_PATH       Full Windows path to reboot.ps1 on the DUT
                           (required for DUT-side stop)
                           Example: "C:\Users\max\automatic-testing-architecture\src\powershell\reboot.ps1"
EOF
}

# ── Defaults ──────────────────────────────────────────────────────────────────

OPT_HOST=""
OPT_SSH_USER=""
OPT_PORT="22"
OPT_DUT_PS1=""

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)      OPT_HOST="$2";     shift 2 ;;
        --ssh-user)  OPT_SSH_USER="$2"; shift 2 ;;
        --port)      OPT_PORT="$2";     shift 2 ;;
        --dut-ps1)   OPT_DUT_PS1="$2";  shift 2 ;;
        --help|-h)   usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

SEP="================================================================"
OVERALL_OK=0

echo "$SEP"
echo "EMERGENCY STOP"
echo "$SEP"
echo ""

# ── Pi side: stop Python test processes ───────────────────────────────────────

echo "--- Pi-side (local Python processes) ---"
STOPPED_PI=0
FAILED_PI=0

for SCRIPT in power_cycle.py reboot.py; do
    # Match 'python ... <script>' but not this script itself
    PIDS=$(pgrep -f "python[23]?.*${SCRIPT}" 2>/dev/null || true)
    if [[ -n "$PIDS" ]]; then
        echo "  Sending SIGINT to ${SCRIPT}  (PIDs: ${PIDS})"
        if kill -INT ${PIDS} 2>/dev/null; then
            STOPPED_PI=$((STOPPED_PI + 1))
        else
            echo "  WARNING: kill failed for some PIDs of ${SCRIPT}" >&2
            FAILED_PI=$((FAILED_PI + 1))
        fi
    fi
done

if [[ $STOPPED_PI -eq 0 && $FAILED_PI -eq 0 ]]; then
    echo "  No running power_cycle.py or reboot.py processes found."
fi

if [[ $FAILED_PI -gt 0 ]]; then
    OVERALL_OK=1
fi

# ── DUT side: stop PowerShell reboot test ─────────────────────────────────────

echo ""
if [[ -n "$OPT_HOST" && -n "$OPT_SSH_USER" && -n "$OPT_DUT_PS1" ]]; then
    echo "--- DUT-side (${OPT_SSH_USER}@${OPT_HOST}) ---"

    SSH_ARGS=(
        -o StrictHostKeyChecking=no
        -o BatchMode=yes
        -o ConnectTimeout=10
        -p "$OPT_PORT"
        "${OPT_SSH_USER}@${OPT_HOST}"
    )
    # Run reboot.ps1 -Stop on the DUT via PowerShell
    PS_CMD="powershell -ExecutionPolicy Bypass -File \"${OPT_DUT_PS1}\" -Stop"

    if ssh "${SSH_ARGS[@]}" "$PS_CMD"; then
        echo "  DUT: reboot.ps1 -Stop completed."
    else
        echo "  WARNING: DUT stop failed (SSH error or PowerShell error)." >&2
        echo "  Run manually on the DUT:" >&2
        echo "    .\\reboot.ps1 -Stop" >&2
        OVERALL_OK=1
    fi
else
    echo "--- DUT-side (skipped) ---"
    if [[ -n "$OPT_HOST" || -n "$OPT_SSH_USER" || -n "$OPT_DUT_PS1" ]]; then
        echo "  DUT-side stop requires --host, --ssh-user, AND --dut-ps1."
    fi
    echo "  To stop a DUT-side reboot test, run on the DUT:"
    echo "    .\\reboot.ps1 -Stop"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "$SEP"
if [[ $OVERALL_OK -eq 0 ]]; then
    echo "Emergency stop complete."
else
    echo "Emergency stop completed with warnings (see above)."
fi
echo "$SEP"

exit $OVERALL_OK
