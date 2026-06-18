#!/usr/bin/env bash
# run_spike.sh - one-command driver for the IPMI engine evaluation spike.
#
# Sets up an isolated venv, installs the candidate stack, dumps the real
# IpmiLibrary keyword list (authoritative, for building Phase 1), then runs
# both layers of the spike against your BMC:
#   1. spike_probe.py   - python-ipmi layer + ipmitool CLI control
#   2. spike_ipmi.robot - the Kontron RF library's connection keywords
#
# Usage:
#   export IPMI_PASSWORD='...'
#   ./run_spike.sh -H 10.0.0.124 -U admin [-o ./spike_out]
#
# Nothing here is production code; the venv and output dir are disposable.
set -u -o pipefail

BMC_HOST=""
BMC_USER="admin"
OUT_DIR="./spike_out"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":H:U:o:h" opt; do
  case "${opt}" in
    H) BMC_HOST="${OPTARG}" ;;
    U) BMC_USER="${OPTARG}" ;;
    o) OUT_DIR="${OPTARG}" ;;
    h) usage; exit 0 ;;
    :) echo "[FATAL] -${OPTARG} needs an argument" >&2; exit 2 ;;
    *) echo "[FATAL] unknown option -${OPTARG}" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "${BMC_HOST}" ]] && { echo "[FATAL] -H <bmc-host> is required" >&2; usage >&2; exit 2; }
[[ -z "${IPMI_PASSWORD:-}" ]] && { echo "[FATAL] export IPMI_PASSWORD first" >&2; exit 2; }
command -v ipmitool >/dev/null 2>&1 || { echo "[FATAL] ipmitool not found (apt install ipmitool)" >&2; exit 2; }
command -v python3  >/dev/null 2>&1 || { echo "[FATAL] python3 not found" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
mkdir -p "${OUT_DIR}"
VENV="${OUT_DIR}/spikevenv"

echo "### 1/4  Creating venv + installing candidate stack"
if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}" || { echo "[FATAL] venv creation failed (apt install python3-venv)" >&2; exit 2; }
fi
# shellcheck disable=SC1091
. "${VENV}/bin/activate"
pip install -q --upgrade pip >/dev/null 2>&1 || true
pip install -q robotframework robotframework-ipmilibrary python-ipmi || {
  echo "[FATAL] pip install failed" >&2; exit 2; }
echo "    versions:"
pip show robotframework robotframework-ipmilibrary python-ipmi 2>/dev/null \
  | grep -E "^Name|^Version" | paste - - | sed 's/^/      /'

echo
echo "### 2/4  Dumping authoritative IpmiLibrary keyword list -> ${OUT_DIR}/ipmilibrary_keywords.txt"
python3 -m robot.libdoc IpmiLibrary list > "${OUT_DIR}/ipmilibrary_keywords.txt" 2>/dev/null \
  && echo "    $(wc -l < "${OUT_DIR}/ipmilibrary_keywords.txt") keywords captured" \
  || echo "    [WARN] libdoc dump failed"

echo
echo "### 3/4  python-ipmi layer probe (A=ipmitool CLI, B=lanplus, C=native 1.5)"
python3 "${HERE}/spike_probe.py" -H "${BMC_HOST}" -U "${BMC_USER}" \
  | tee "${OUT_DIR}/spike_probe.out"
PROBE_RC=${PIPESTATUS[0]}

echo
echo "### 4/4  Kontron RF library connection keywords"
robot -v BMC_HOST:"${BMC_HOST}" -v BMC_USER:"${BMC_USER}" \
  -d "${OUT_DIR}" -l rf_log.html -r rf_report.html -o rf_output.xml \
  "${HERE}/spike_ipmi.robot"
ROBOT_RC=$?

echo
echo "========================================================================"
echo "SPIKE COMPLETE"
echo "  python-ipmi probe : exit ${PROBE_RC}  (0 = >=1 path connected)"
echo "  RF library suite  : exit ${ROBOT_RC}  (0 = a connection keyword worked)"
echo "  artefacts         : ${OUT_DIR}/"
echo "    - spike_probe.out            engine recommendation"
echo "    - rf_report.html / rf_log.html   RF library result"
echo "    - ipmilibrary_keywords.txt   keyword list for Phase 1"
echo "Read the ENGINE DECISION block in spike_probe.out, then share the"
echo "results so we can lock the Phase 1 engine."
echo "========================================================================"
