#!/usr/bin/env bash
# DET013 automated test harness for src/bash-shell/dev_detect.sh.
#
# Exercises the contract in requirements/DET013.md: --help, --snapshot-only
# vs standalone autorun behaviour, the INIT -> Pass -> Fail result sequence,
# the four-state exit code, and the JSON sidecar.
#
# Safety: dev_detect.sh installs a systemd unit (via `sudo tee` /
# `sudo systemctl ...`) and, in standalone mode with more than one pass
# remaining, calls `reboot`/`poweroff`. This harness puts a PATH shim in
# front of the real `sudo`, `reboot` and `poweroff` so none of that ever
# touches the host actually running the tests -- the shim only records
# that the call happened.
#
# Known gap: the Error (exit 2) outcome is not exercised here. It only
# fires when collect_inventory_snapshot itself fails to write its output
# file, which isn't safely reproducible without either running as a
# non-root user (this script assumes root, like dev_detect.sh) or making
# the log directory immutable (chattr +i), which may not be permitted in
# every sandbox. Left for a follow-up once a reliable trigger is found.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DETECT="${SCRIPT_DIR}/dev_detect.sh"

WORK="$(mktemp -d /tmp/dev_detect_test.XXXXXX)"
FAKEBIN="${WORK}/fakebin"
MOCK_LOG="${WORK}/mock_calls.log"
mkdir -p "${FAKEBIN}"
: > "${MOCK_LOG}"

cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

cat > "${FAKEBIN}/sudo" <<'EOF'
#!/usr/bin/env bash
echo "MOCK_SUDO $*" >> "${MOCK_LOG:?}"
exit 0
EOF

cat > "${FAKEBIN}/reboot" <<'EOF'
#!/usr/bin/env bash
echo "MOCK_REBOOT $*" >> "${MOCK_LOG:?}"
exit 0
EOF

cat > "${FAKEBIN}/poweroff" <<'EOF'
#!/usr/bin/env bash
echo "MOCK_POWEROFF $*" >> "${MOCK_LOG:?}"
exit 0
EOF
# DET002 needs a DMI view of installed memory. Without dmidecode the usability
# check is UNKNOWN by design (never a silent Pass), which rolls up like INIT and
# would make every scenario here exit 3 — the harness would be testing the
# absence of a tool, not dev_detect.sh. Report one DIMM sized to just above the
# running kernel's MemTotal so installed >= usable with a gap far below the
# 2 GiB tolerance floor, i.e. a healthy machine.
_mock_dimm_gb="$(awk '/^MemTotal:/ { g = int($2 / 1048576); if (g * 1048576 < $2) g++; print (g < 1 ? 1 : g); exit }' /proc/meminfo)"
cat > "${FAKEBIN}/dmidecode" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"-t memory"*|*"-t 17"*)
    printf '%s\n' 'Handle 0x0040, DMI type 17, 40 bytes' \\
                  'Memory Device' \\
                  '	Size: ${_mock_dimm_gb} GB' \\
                  '	Locator: DIMM_A1'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${FAKEBIN}"/sudo "${FAKEBIN}"/reboot "${FAKEBIN}"/poweroff "${FAKEBIN}"/dmidecode

export PATH="${FAKEBIN}:${PATH}"
export MOCK_LOG
: "${USER:=root}"
export USER

_pass=0
_fail=0

ok()   { _pass=$((_pass+1)); echo "  [OK] $1"; }
bad()  { _fail=$((_fail+1)); echo "  [FAIL] $1"; }
section() { echo; echo "== $1 =="; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    ok "${desc} (got ${actual})"
  else
    bad "${desc} (expected ${expected}, got ${actual})"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    ok "${desc}"
  else
    bad "${desc} (missing: ${needle})"
  fi
}

assert_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "${path}" ]]; then
    ok "${desc}"
  else
    bad "${desc} (unexpectedly exists: ${path})"
  fi
}

latest_sidecar() {
  # $1 = <tool_path>/logs. Each completed pass gets its own fresh session
  # subdir (counter_tick wipes session.id once a pass completes), so the
  # newest sidecar must be found by mtime across the whole tree, not by
  # assuming a single session directory.
  find "$1" -name '*.json' -newer "${WORK}/.marker" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d' ' -f2-
}

mark_now() { touch -d '-1 second' "${WORK}/.marker" 2>/dev/null || touch "${WORK}/.marker"; }

sidecar_field() {
  # $1 = json path, $2 = field (dotted path, e.g. components.cpu_model.result)
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    d = d.get(part) if isinstance(d, dict) else None
print(d)
" "$1" "$2"
}

run_dev_detect() {
  # Runs dev_detect.sh with a fresh _tool_path so each scenario is isolated,
  # unless TOOL_PATH is already set by the caller (for golden persistence
  # across snapshot-mode invocations).
  local exit_code=0
  ( cd "${SCRIPT_DIR}" && _tool_path="${TOOL_PATH}" bash "${DEV_DETECT}" "$@" ) \
    >"${WORK}/last_stdout.log" 2>"${WORK}/last_stderr.log" || exit_code=$?
  echo "${exit_code}"
}

systemd_unit_mtime() {
  stat -c '%Y' /etc/systemd/system/dev-detect.service 2>/dev/null || echo "absent"
}

# ---------------------------------------------------------------------------
section "--help"
TOOL_PATH="${WORK}/help_tool"
mkdir -p "${TOOL_PATH}"
mark_now
code="$(run_dev_detect --help)"
out="$(cat "${WORK}/last_stdout.log")"
assert_eq "--help exits 0" "0" "${code}"
assert_contains "--help lists --snapshot-only" "${out}" "--snapshot-only"
assert_contains "--help lists --power-cycle" "${out}" "--power-cycle"
assert_contains "--help lists --vpu-check" "${out}" "--vpu-check"
assert_contains "--help lists exit codes" "${out}" "INIT"
assert_not_exists "--help did not create a logs dir" "${TOOL_PATH}/logs"

# ---------------------------------------------------------------------------
section "unrecognized argument -> usage error, exit 64, no pass"
TOOL_PATH="${WORK}/badarg_tool"
mkdir -p "${TOOL_PATH}"
mark_now
code="$(run_dev_detect --not-a-real-flag)"
err="$(cat "${WORK}/last_stderr.log")"
assert_eq "bad flag exits 64" "64" "${code}"
assert_contains "bad flag names the offending token" "${err}" "--not-a-real-flag"
assert_not_exists "bad flag did not run a pass (no logs dir)" "${TOOL_PATH}/logs"

# ---------------------------------------------------------------------------
section "snapshot mode: first pass (clean DUT) -> INIT, exit 3"
TOOL_PATH="${WORK}/snapshot_tool"
mkdir -p "${TOOL_PATH}"
unit_before="$(systemd_unit_mtime)"
mark_now
code="$(run_dev_detect --snapshot-only)"
assert_eq "first --snapshot-only pass exit code" "3" "${code}"

sidecar="$(latest_sidecar "${TOOL_PATH}/logs")"
if [[ -n "${sidecar}" && -f "${sidecar}" ]]; then
  ok "JSON sidecar written (${sidecar##*/})"
  result="$(sidecar_field "${sidecar}" result)"
  assert_eq "sidecar result == INIT" "INIT" "${result}"
  schema_ver="$(sidecar_field "${sidecar}" schema_version)"
  assert_eq "sidecar schema_version == 2.0" "2.0" "${schema_ver}"
  comp_result="$(sidecar_field "${sidecar}" components.cpu_model.result)"
  assert_eq "components.cpu_model.result == INIT" "INIT" "${comp_result}"
  comp_golden="$(sidecar_field "${sidecar}" components.cpu_model.golden)"
  assert_eq "components.cpu_model.golden is null on INIT" "None" "${comp_golden}"
  comp_pcie="$(sidecar_field "${sidecar}" components.pcie_gpu.result)"
  assert_eq "components.pcie_gpu (bash-only component) present" "INIT" "${comp_pcie}"
else
  bad "JSON sidecar written"
fi
assert_eq "no real systemd unit modification in snapshot mode" "${unit_before}" "$(systemd_unit_mtime)"
if grep -qE 'systemctl|systemd' "${MOCK_LOG}" 2>/dev/null; then
  bad "no autorun-related sudo call in snapshot mode (mock log: $(cat "${MOCK_LOG}"))"
else
  ok "no autorun-related sudo call in snapshot mode"
fi
if grep -qE "MOCK_REBOOT|MOCK_POWEROFF" "${MOCK_LOG}" 2>/dev/null; then
  bad "no reboot/poweroff issued in snapshot mode"
else
  ok "no reboot/poweroff issued in snapshot mode"
fi

# ---------------------------------------------------------------------------
section "snapshot mode: second pass, unchanged hardware -> Pass, exit 0"
: > "${MOCK_LOG}"
mark_now
code="$(run_dev_detect --snapshot-only)"
assert_eq "second --snapshot-only pass exit code" "0" "${code}"
sidecar="$(latest_sidecar "${TOOL_PATH}/logs")"
if [[ -n "${sidecar}" && -f "${sidecar}" ]]; then
  result="$(sidecar_field "${sidecar}" result)"
  assert_eq "sidecar result == Pass" "Pass" "${result}"
  comp_result="$(sidecar_field "${sidecar}" components.cpu_model.result)"
  assert_eq "components.cpu_model.result == Pass" "Pass" "${comp_result}"
  comp_current="$(sidecar_field "${sidecar}" components.cpu_model.current)"
  comp_golden="$(sidecar_field "${sidecar}" components.cpu_model.golden)"
  assert_eq "components.cpu_model.golden == current on Pass" "${comp_current}" "${comp_golden}"
else
  bad "JSON sidecar written for second pass"
fi
if grep -qE 'systemctl|systemd' "${MOCK_LOG}" 2>/dev/null; then
  bad "still no autorun-related sudo call in snapshot mode"
else
  ok "still no autorun-related sudo call in snapshot mode"
fi

# ---------------------------------------------------------------------------
section "snapshot mode: golden mismatch -> Fail, exit 1"
# Layer 2: the Pass/Fail verdict now comes from the per-component goldens
# (cpu_model.golden.txt etc.), not the whole-file dev_detect.golden.txt --
# corrupt a specific component golden so this exercises the real path.
golden_file="${TOOL_PATH}/logs/golden/cpu_model.golden.txt"
if [[ ! -f "${golden_file}" ]]; then
  bad "locate persisted cpu_model golden file to corrupt"
else
  echo "INJECTED_MISMATCH_LINE" >> "${golden_file}"
  mark_now
  code="$(run_dev_detect --snapshot-only)"
  assert_eq "post-corruption --snapshot-only pass exit code" "1" "${code}"
  sidecar="$(latest_sidecar "${TOOL_PATH}/logs")"
  if [[ -n "${sidecar}" && -f "${sidecar}" ]]; then
    result="$(sidecar_field "${sidecar}" result)"
    assert_eq "sidecar result == Fail" "Fail" "${result}"
    diff_path="$(sidecar_field "${sidecar}" diff_path)"
    assert_eq "sidecar diff_path is set on Fail" "True" "$([[ "${diff_path}" != "None" ]] && echo True || echo False)"
    comp_result="$(sidecar_field "${sidecar}" components.cpu_model.result)"
    assert_eq "components.cpu_model.result == Fail" "Fail" "${comp_result}"
  else
    bad "JSON sidecar written for Fail pass"
  fi
fi

# ---------------------------------------------------------------------------
section "USB detect: PassMark loopback plug is counted (DET004/DET012 parity)"
TOOL_PATH="${WORK}/passmark_tool"
mkdir -p "${TOOL_PATH}"
FAKEBIN_PM="${WORK}/fakebin_passmark"
mkdir -p "${FAKEBIN_PM}"
cat > "${FAKEBIN_PM}/lsusb" <<'EOF'
#!/usr/bin/env bash
# Minimal stand-in: a real PassMark USB3.0 Loopback Plug reports this exact
# string as its iProduct descriptor, which lsusb surfaces verbatim.
case "$*" in
  *-v*) exit 1 ;;
  *) echo "Bus 001 Device 005: ID 0403:6015 PassMark USB3.0 Loopback plug" ;;
esac
EOF
chmod +x "${FAKEBIN_PM}/lsusb"
mark_now
code=0
( cd "${SCRIPT_DIR}" && _tool_path="${TOOL_PATH}" PATH="${FAKEBIN_PM}:${PATH}" bash "${DEV_DETECT}" --snapshot-only ) \
  >"${WORK}/last_stdout.log" 2>"${WORK}/last_stderr.log" || code=$?
out="$(cat "${WORK}/last_stdout.log")"
assert_eq "PassMark scenario exit code (INIT on clean DUT)" "3" "${code}"
assert_contains "USB section names the PassMark target" "${out}" "Target: PassMark USB3.0 Loopback plug"
assert_contains "USB section counts exactly one PassMark plug" "${out}" "Count: 1"

# ---------------------------------------------------------------------------
section "standalone mode: a single run stays in the foreground (BUG0038)"
TOOL_PATH="${WORK}/standalone_tool"
mkdir -p "${TOOL_PATH}"
unit_before="$(systemd_unit_mtime)"
: > "${MOCK_LOG}"
mark_now
code="$(run_dev_detect)"
assert_eq "standalone single-target-loop run exit code (INIT on clean DUT)" "3" "${code}"
# Boot persistence exists to keep a multi-boot campaign going. A one-shot run
# finishes in this process, so installing a systemd unit would leave the DUT
# re-running dev_detect at every boot forever (BUG0038).
if grep -qE 'systemctl|systemd' "${MOCK_LOG}" 2>/dev/null; then
  bad "a single run installs no autorun unit (mock log: $(cat "${MOCK_LOG}"))"
else
  ok "a single run installs no autorun unit"
fi
assert_eq "no real systemd unit modification in standalone mode" "${unit_before}" "$(systemd_unit_mtime)"
if grep -qE "MOCK_REBOOT|MOCK_POWEROFF" "${MOCK_LOG}" 2>/dev/null; then
  bad "no reboot/poweroff issued (target loop count is 1, run should complete, not reboot)"
else
  ok "no reboot/poweroff issued (target loop count is 1, run should complete, not reboot)"
fi
sidecar="$(latest_sidecar "${TOOL_PATH}/logs")"
if [[ -n "${sidecar}" && -f "${sidecar}" ]]; then
  ok "JSON sidecar also written in standalone mode"
else
  bad "JSON sidecar also written in standalone mode"
fi

# ---------------------------------------------------------------------------
section "standalone mode: a multi-boot campaign does install autorun"
TOOL_PATH="${WORK}/campaign_tool"
mkdir -p "${TOOL_PATH}"
unit_before="$(systemd_unit_mtime)"
: > "${MOCK_LOG}"
mark_now
code="$(run_dev_detect 2)"
if grep -qE 'systemctl|systemd' "${MOCK_LOG}" 2>/dev/null; then
  ok "autorun_setup attempted a systemd-related sudo call (mocked, no real systemd touched)"
else
  bad "autorun_setup attempted a systemd-related sudo call (mock log: $(cat "${MOCK_LOG}"))"
fi
assert_eq "no real systemd unit modification for the campaign either" \
          "${unit_before}" "$(systemd_unit_mtime)"
if grep -qE "MOCK_REBOOT|MOCK_POWEROFF" "${MOCK_LOG}" 2>/dev/null; then
  ok "the campaign reboots to reach its second pass"
else
  bad "the campaign reboots to reach its second pass (mock log: $(cat "${MOCK_LOG}"))"
fi

# ---------------------------------------------------------------------------
echo
echo "============================================="
echo "Results: ${_pass} passed, ${_fail} failed"
echo "============================================="
[[ "${_fail}" -eq 0 ]]
