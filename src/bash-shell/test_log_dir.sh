#!/usr/bin/env bash
# test_log_dir.sh — log_dir() console output (BUG0023)
#
# log_dir() used to end with `printf '%s\n' "${_log_dir}"`, leaking a bare path
# into every run's output, and announced unconditionally, so scripts that call
# it directly and then call setup_session() (net_test.sh, slp_test.sh) printed
# the same two [INFO] lines twice.
#
# Run:  ./test_log_dir.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Run log_dir in a child shell so each case starts from a clean environment.
# _tool_path is pre-set so nothing is created outside TMP.
run_case() {
  local calls="$1"
  env -u _log_dir -u _session_log_dir -u _session_id -u _log_dir_announced \
      -u USER -u SUDO_USER \
      _tool_path="${TMP}/tool" \
      bash -c "
        source '${SCRIPT_DIR}/config.sh'
        source '${SCRIPT_DIR}/function.sh'
        ${calls}
      " 2>/dev/null
}

# USER/SUDO_USER are unset above on purpose: a systemd unit starts that way, and
# fix_log_permissions must not abort under `set -u` (see BUG0023).

echo "log_dir() console output"

# 1. A single call announces both paths, once each.
out="$(run_case 'log_dir "" 1')"
if [[ "$(grep -c '^\[INFO\] log dir:' <<<"${out}")" == "1" &&
      "$(grep -c '^\[INFO\] session log dir:' <<<"${out}")" == "1" ]]; then
  ok "single call announces each path once"
else
  bad "single call announces each path once" "${out}"
fi

# 2. No bare path line. Every line must be a tagged message.
stray="$(grep -v '^\[' <<<"${out}" | grep -v '^[[:space:]]*$')"
if [[ -z "${stray}" ]]; then
  ok "no bare path leaked to stdout"
else
  bad "no bare path leaked to stdout" "${stray}"
fi

# 3. The net_test.sh / slp_test.sh pattern: log_dir, then setup_session's
#    second log_dir with identical arguments. The second must be silent.
out2="$(run_case 'log_dir "" 1; log_dir "" 1')"
if [[ "$(grep -c '^\[INFO\] log dir:' <<<"${out2}")" == "1" ]]; then
  ok "repeated call with the same paths is silent"
else
  bad "repeated call with the same paths is silent" "${out2}"
fi

# 4. A call that genuinely resolves elsewhere must still announce.
out3="$(run_case 'log_dir "" 1; _log_dir=""; _session_log_dir=""; log_dir "" 1 "'"${TMP}"'/other"')"
if [[ "$(grep -c '^\[INFO\] log dir:' <<<"${out3}")" == "2" ]]; then
  ok "a changed log dir is announced again"
else
  bad "a changed log dir is announced again" "${out3}"
fi

# 5. The exported variables are the contract callers rely on.
out4="$(run_case 'log_dir "" 1 >/dev/null; printf "%s\n%s\n" "${_log_dir}" "${_session_log_dir}"')"
if [[ "$(sed -n 1p <<<"${out4}")" == "${TMP}/tool/logs" &&
      "$(sed -n 2p <<<"${out4}")" == "${TMP}/tool/logs/"* ]]; then
  ok "_log_dir and _session_log_dir are exported for callers"
else
  bad "_log_dir and _session_log_dir are exported for callers" "${out4}"
fi

# 6. Success status is preserved — callers use `log_dir "" 1 || return 1`.
if run_case 'log_dir "" 1 >/dev/null' && true; then
  ok "returns success"
else
  bad "returns success" "(non-zero exit)"
fi

# 7. Explicit: no USER, no SUDO_USER (a systemd unit) must not abort under
#    `set -u` inside fix_log_permissions. run_case already unsets both, so this
#    states the requirement rather than leaving it implicit in the harness.
out5="$(env -u USER -u SUDO_USER -u _log_dir -u _session_log_dir \
            -u _session_id -u _log_dir_announced _tool_path="${TMP}/nouser" \
        bash -c "source '${SCRIPT_DIR}/config.sh'
                 source '${SCRIPT_DIR}/function.sh'
                 log_dir \"\" 1 >/dev/null && echo SURVIVED" 2>&1)"
if [[ "${out5}" == *SURVIVED* ]]; then
  ok "survives with USER and SUDO_USER unset"
else
  bad "survives with USER and SUDO_USER unset" "${out5}"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
