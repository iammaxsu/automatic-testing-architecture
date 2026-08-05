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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"

# -H is optional when config_local.py / config.py names a BMC (SET006).
if [[ -z "${BMC_HOST}" ]]; then
  BMC_HOST="$(python3 - "${HERE}" <<'PY' 2>/dev/null || true
import importlib.util, pathlib, sys
here = pathlib.Path(sys.argv[1])
def load(name):
    p = here / (name + ".py")
    if not p.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location(name, p)
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        return m
    except Exception:
        return None
for mod in (load("config_local"), load("config")):
    value = getattr(mod, "BMC_HOST", "") if mod else ""
    if value:
        print(value); break
PY
)"
  [[ -n "${BMC_HOST}" ]] && echo "[INFO] host     : ${BMC_HOST} (from config)"
fi
[[ -z "${BMC_HOST}" ]] && {
  echo "[FATAL] no BMC host: pass -H <bmc-host>, or set BMC_HOST in src/robot/config_local.py" >&2
  usage >&2; exit 2; }

# Use the project venv when the caller has not activated one. A stale system
# launcher (e.g. ~/.local/bin/robot whose interpreter lost the package) other-
# wise passes a "does the command exist" check and fails only mid-run.
if [[ -z "${VIRTUAL_ENV:-}" && -f "${REPO_ROOT}/.venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.venv/bin/activate"
  echo "[INFO] venv     : ${REPO_ROOT}/.venv (auto-activated)"
fi

# Verify robot really runs. `robot --version` prints the banner but exits 251,
# so check the banner text, not the exit status (and avoid a pipeline, which
# `set -o pipefail` would fail on that 251).
_robot_banner="$(robot --version 2>&1 || true)"
if [[ "${_robot_banner}" != "Robot Framework"* ]]; then
  echo "[FATAL] 'robot' is not usable ($(command -v robot || echo 'not found'))." >&2
  echo "        Set up the venv once:" >&2
  echo "          python3 -m venv ${REPO_ROOT}/.venv" >&2
  echo "          source ${REPO_ROOT}/.venv/bin/activate && pip install robotframework" >&2
  echo "        See src/robot/README.md." >&2
  exit 2
fi

# Filesystem-safe <dut> component (LOG025): IPv6 ':' and any '/' -> '_'.
DUT_SAFE="${BMC_HOST//[:\/]/_}"
SESSION_ID="$(date +%Y%m%dT%H%M%S)"          # ISO 8601 basic (LOG023)
OUT_DIR="${LOG_ROOT}/${DUT_SAFE}/${SESSION_ID}"
mkdir -p "${OUT_DIR}" || { echo "[FATAL] cannot create ${OUT_DIR}" >&2; exit 2; }

echo "[INFO] DUT      : ${BMC_HOST}"
echo "[INFO] suite    : ${SUITE}"
echo "[INFO] output   : ${OUT_DIR}/"

# LOG_ROOT is passed so resumable suites put their session state under the same
# logs tree (<log-root>/<dut>/<test>_session.json) - deleting it is a full reset.
robot -v BMC_HOST:"${BMC_HOST}" -v LOG_ROOT:"${LOG_ROOT}" \
      -d "${OUT_DIR}" "${EXTRA[@]}" "${SUITE}"
rc=$?

echo "[INFO] report   : ${OUT_DIR}/report.html"
exit "${rc}"
