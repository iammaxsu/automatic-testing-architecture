#!/usr/bin/env bash
# run.sh - run a BMC/IPMI Robot suite into a per-DUT, per-session output dir.
#
# Builds  logs/<dut>/<session_id>/  (LOG025 + LOG017/LOG023) and passes it to
# Robot's -d, so runs never overwrite each other and multiple DUTs stay
# distinguishable. Mirrors the Python runners' LOG_DIR convention.
#
# Usage:
#   ./run.sh -H <bmc-host> [-s <suite-path>] [-o <log-root>] [-- <extra robot args>]
#
#   -H host        BMC IP / hostname (required); also becomes -v BMC_HOST and
#                  the <dut> directory name.
#   -s suite       suite file or directory (default: src/robot/ipmi/)
#   -o log-root    root logs directory (default: logs)
#   --             everything after this is forwarded verbatim to `robot`
#   -h             this help
#
# Examples:
#   export IPMI_PASSWORD='...'
#   ./run.sh -H 10.0.0.124
#   ./run.sh -H 10.0.0.124 -s src/robot/ipmi/lan.robot -- --include lan
#   ./run.sh -H 10.0.0.124 -s src/robot/ipmi/power.robot -- \
#            -v POWER_TESTS_ENABLED:True -v DUT_HOST:10.0.0.50
#
# Output: <log-root>/<dut>/<session_id>/{report,log}.html, output.xml, ...
set -u -o pipefail

BMC_HOST=""
SUITE="src/robot/ipmi/"
LOG_ROOT="logs"
EXTRA=()

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) BMC_HOST="${2:?-H needs a value}"; shift 2 ;;
    -s) SUITE="${2:?-s needs a value}"; shift 2 ;;
    -o) LOG_ROOT="${2:?-o needs a value}"; shift 2 ;;
    --) shift; EXTRA=("$@"); break ;;
    -h) usage; exit 0 ;;
    *) echo "[FATAL] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "${BMC_HOST}" ]] && { echo "[FATAL] -H <bmc-host> is required" >&2; usage >&2; exit 2; }
command -v robot >/dev/null 2>&1 || {
  echo "[FATAL] 'robot' not found - activate the venv (see src/robot/README.md)" >&2; exit 2; }

# Filesystem-safe <dut> component (LOG025): IPv6 ':' and any '/' -> '_'.
DUT_SAFE="${BMC_HOST//[:\/]/_}"
SESSION_ID="$(date +%Y%m%dT%H%M%S)"          # ISO 8601 basic (LOG023)
OUT_DIR="${LOG_ROOT}/${DUT_SAFE}/${SESSION_ID}"
mkdir -p "${OUT_DIR}" || { echo "[FATAL] cannot create ${OUT_DIR}" >&2; exit 2; }

echo "[INFO] DUT      : ${BMC_HOST}"
echo "[INFO] suite    : ${SUITE}"
echo "[INFO] output   : ${OUT_DIR}/"

robot -v BMC_HOST:"${BMC_HOST}" -d "${OUT_DIR}" "${EXTRA[@]}" "${SUITE}"
rc=$?

echo "[INFO] report   : ${OUT_DIR}/report.html"
exit "${rc}"
