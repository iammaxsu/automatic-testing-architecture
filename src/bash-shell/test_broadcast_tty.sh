#!/usr/bin/env bash
# test_broadcast_tty.sh — FWK038 presence and liveness indication
#                        (BUG0049, BUG0050)
#
# `wall` writes ~10 lines to every TTY including the one running the test, which
# scrolled away the `\r`-redrawn progress bar and made a running test look
# frozen until a keypress. And the bar did not erase to end of line, so a
# shorter label left the tail of the previous, longer one on screen.
#
# Run:  ./test_broadcast_tty.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_SH="${SCRIPT_DIR}/function.sh"
NET_TEST="${SCRIPT_DIR}/net_test.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "FWK038 presence and liveness"

# ---------- _adlink_broadcast ----------
# Drive the real function with two stand-in "terminals" (plain writable files)
# and a `who` that names them. The `/dev/` prefix the function builds is stripped
# so the paths land inside TMP; everything else runs verbatim.
mkdir -p "${TMP}/dev"
: > "${TMP}/dev/self"
: > "${TMP}/dev/other"

{
  echo 'set -uo pipefail'
  sed -n '/^_adlink_broadcast()/,/^}/p' "${FUNCTION_SH}" | sed 's#"/dev/"\$2#\$2#'
  printf 'who() { printf "max %%s\\nother %%s\\n" "%s" "%s"; }\n' \
         "${TMP}/dev/self" "${TMP}/dev/other"
  printf '_ADLINK_SELF_TTY="%s"\n' "${TMP}/dev/self"
  echo '_adlink_broadcast "TEST IN PROGRESS - DO NOT POWER OFF"'
} > "${TMP}/run.sh"
bash "${TMP}/run.sh" >/dev/null 2>&1

if [[ ! -s "${TMP}/dev/self" ]]; then
  ok "the invoking terminal is not written to"
else
  bad "the invoking terminal is not written to" "$(cat "${TMP}/dev/self")"
fi

if grep -q "TEST IN PROGRESS" "${TMP}/dev/other" 2>/dev/null; then
  ok "other terminals still receive the warning"
else
  bad "other terminals still receive the warning" "$(cat "${TMP}/dev/other" 2>&1)"
fi

# With no known tty (a cron/systemd run), every terminal must still be told.
: > "${TMP}/dev/self"; : > "${TMP}/dev/other"
sed 's#^_ADLINK_SELF_TTY=.*#_ADLINK_SELF_TTY=""#' "${TMP}/run.sh" > "${TMP}/run2.sh"
bash "${TMP}/run2.sh" >/dev/null 2>&1
if grep -q "TEST IN PROGRESS" "${TMP}/dev/self" 2>/dev/null &&
   grep -q "TEST IN PROGRESS" "${TMP}/dev/other" 2>/dev/null; then
  ok "with no tty of our own, nothing is excluded"
else
  bad "with no tty of our own, nothing is excluded" \
      "self=[$(cat "${TMP}/dev/self")] other=[$(cat "${TMP}/dev/other")]"
fi

# ---------- source-level guards ----------
if ! grep -q '| wall 2>/dev/null' "${FUNCTION_SH}"; then
  ok "no bare wall(1) call remains"
else
  bad "no bare wall(1) call remains" "$(grep -n '| wall' "${FUNCTION_SH}")"
fi

# Captured at source time on purpose: by call time this may run from a
# background subshell where tty(1) answers "not a tty".
if grep -q '^_ADLINK_SELF_TTY="\$(tty 2>/dev/null || true)"' "${FUNCTION_SH}"; then
  ok "the invoking tty is captured at source time, not at call time"
else
  bad "the invoking tty is captured at source time, not at call time" "(missing)"
fi

# ---------- progress bar erases to end of line ----------
if grep -q 'ds / %3ds  %s\\033\[K' "${NET_TEST}"; then
  ok "progress bar erases to end of line"
else
  bad "progress bar erases to end of line" "$(grep -n 'ds / %3ds' "${NET_TEST}")"
fi

if grep -q 'printf "\\r\\033\[K" >&2' "${NET_TEST}"; then
  ok "final clear does not assume a terminal width"
else
  bad "final clear does not assume a terminal width" \
      "$(grep -n 'clear the progress line' "${NET_TEST}")"
fi

# The reported artefact: a long label followed by a short one. Rendered without
# the erase, the tail of the long label survives; with it, it cannot.
long="P0 TCP Fwd  enp12s0->enp12s2 @10M"
short="P0 UDP @10M"
render_line() {   # $1 = label, $2 = trailing sequence
  printf "\r  [%-4s] %3ds  %s%b" "####" 1 "$1" "$2"
}
without="$(render_line "${long}" "" ; render_line "${short}" "")"
with="$(   render_line "${long}" '\033[K'; render_line "${short}" '\033[K')"
if [[ "${without}" == *"enp12s2 @10M"* && "${with}" == *$'\033[K' ]]; then
  ok "a shorter label is followed by an erase sequence"
else
  bad "a shorter label is followed by an erase sequence" "$(cat -v <<<"${with}")"
fi

# ---------- FWK038 liveness: the indicator outlives its nominal duration ----------
# A 3 s nominal step driven for 6 s. Before BUG0050 the bar stopped at 3 s and
# the console went silent for the remaining 3 s -- the window an operator reads
# as a hang.
cat > "${TMP}/live.sh" <<EOF
set -uo pipefail
$(sed -n '/^_iperf3_progress()/,/^}/p;/^_progress_stop()/,/^}/p' "${NET_TEST}")
_iperf3_progress "P0 TCP Fwd enp12s0->enp12s2 @10M" 3 2>"${TMP}/frames.txt" &
pp=\$!
sleep 6
_progress_stop "\$pp"
ps -p "\$pp" >/dev/null 2>&1 && echo ALIVE || echo TERMINATED
EOF
live_out="$(bash "${TMP}/live.sh" 2>/dev/null)"
frames="$(tr '\r' '\n' < "${TMP}/frames.txt")"

if grep -q "still running" <<<"${frames}"; then
  ok "the indicator keeps moving past its nominal duration"
else
  bad "the indicator keeps moving past its nominal duration" "${frames}"
fi

# The elapsed figure must keep climbing past the nominal total, not freeze at it.
if grep -qE "^ +\[#+\] +5s / +3s .*still running" <<<"${frames}"; then
  ok "elapsed keeps climbing past the nominal total"
else
  bad "elapsed keeps climbing past the nominal total" "${frames}"
fi

# It must not claim the step finished while it is still running.
if ! grep -qiE "done|complete|finished" <<<"${frames}"; then
  ok "the indicator never claims completion while running"
else
  bad "the indicator never claims completion while running" "${frames}"
fi

if [[ "${live_out}" == *TERMINATED* ]]; then
  ok "_progress_stop terminates the indicator"
else
  bad "_progress_stop terminates the indicator" "${live_out}"
fi

# An orphaned indicator must not spin forever.
if grep -q 'local hard_stop=\$(( total \* 5 + 600 ))' "${NET_TEST}"; then
  ok "a backstop bounds an orphaned indicator"
else
  bad "a backstop bounds an orphaned indicator" "(backstop missing)"
fi

# Callers must stop it, not wait on it -- waiting would block until the backstop.
if ! grep -qE 'wait "\$\{_(pp|prog_pid)\}"' "${NET_TEST}"; then
  ok "no caller waits on the indicator instead of stopping it"
else
  bad "no caller waits on the indicator instead of stopping it" \
      "$(grep -nE 'wait "\$\{_(pp|prog_pid)\}"' "${NET_TEST}")"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
