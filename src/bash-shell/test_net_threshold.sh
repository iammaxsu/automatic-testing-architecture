#!/usr/bin/env bash
# test_net_threshold.sh — NET009 TCP pass threshold (BUG0061)
#
# The threshold used to be a percentage of the nominal LINK SPEED, but iperf3
# reports TCP payload (goodput) while the link speed is wire rate. Every frame
# also carries 38 bytes the payload never sees, plus IP/TCP headers inside the
# MTU. At MTU 1500 the ceiling is 94.15% of line rate, so a 95% threshold
# demanded more than the wire can carry and no hardware could ever pass.
#
# Run:  ./test_net_threshold.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_TEST="${SCRIPT_DIR}/net_test.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
sed -n '/^_goodput_efficiency()/,/^}/p' "${NET_TEST}" > "${TMP}/lib.sh"
# shellcheck disable=SC1090
source "${TMP}/lib.sh"

# The threshold as net_test computes it.
thr() { awk -v s="$1" -v e="$(_goodput_efficiency "${3:-1500}")" -v p="${2:-95}" \
            'BEGIN{printf "%.0f", s*e*p/100}'; }
verdict() { awk -v m="$1" -v t="$2" 'BEGIN{print (m>=t)?"PASS":"FAIL"}'; }

echo "NET009 TCP pass threshold"

# ---- the ceiling itself ----
# (1500 - 52) / (1500 + 38) = 0.9415
if [[ "$(_goodput_efficiency 1500)" == "0.9415" ]]; then
  ok "MTU 1500 goodput ceiling is 94.15% of line rate"
else
  bad "MTU 1500 goodput ceiling is 94.15% of line rate" "$(_goodput_efficiency 1500)"
fi

# Jumbo frames amortise the same overhead over six times the payload.
if [[ "$(_goodput_efficiency 9000)" == "0.9900" ]]; then
  ok "MTU 9000 goodput ceiling is 99.00%, so jumbo changes the target"
else
  bad "MTU 9000 goodput ceiling is 99.00%" "$(_goodput_efficiency 9000)"
fi

# A nonsensical MTU must not produce a negative or absurd fraction.
if [[ "$(_goodput_efficiency 40)" == "1.0000" ]]; then
  ok "an MTU below the header size degrades safely to 1.0"
else
  bad "an MTU below the header size degrades safely to 1.0" "$(_goodput_efficiency 40)"
fi

# ---- the measurements that motivated this, from session 20260812T132556 ----
# All four were at 99-100% of the achievable rate and all four were failed.
fails=""
for row in "25000 23500" "50000 47100" "100000 94200" "200000 182000"; do
  # shellcheck disable=SC2086
  set -- ${row}
  t="$(thr "$1")"
  [[ "$(verdict "$2" "${t}")" == "PASS" ]] || fails="${fails} $1(measured $2 < thr ${t})"
done
if [[ -z "${fails}" ]]; then
  ok "hardware running at the wire's limit now passes at every speed"
else
  bad "hardware running at the wire's limit now passes at every speed" "${fails}"
fi

# The old formula must be shown to have failed them, or this test proves nothing.
oldfails=0
for row in "25000 23500" "50000 47100" "100000 94200" "200000 182000"; do
  # shellcheck disable=SC2086
  set -- ${row}
  old="$(awk -v s="$1" 'BEGIN{printf "%.0f", s*95/100}')"
  [[ "$(verdict "$2" "${old}")" == "FAIL" ]] && oldfails=$((oldfails + 1))
done
if (( oldfails == 4 )); then
  ok "the previous formula failed all four, confirming the fix is not cosmetic"
else
  bad "the previous formula failed all four" "${oldfails} of 4"
fi

# ---- it must still catch a genuinely underperforming link ----
underperf=""
for row in "25000 20000" "100000 60000" "200000 150000"; do
  # shellcheck disable=SC2086
  set -- ${row}
  t="$(thr "$1")"
  [[ "$(verdict "$2" "${t}")" == "FAIL" ]] || underperf="${underperf} $1(measured $2 passed thr ${t})"
done
if [[ -z "${underperf}" ]]; then
  ok "a genuinely slow link still fails"
else
  bad "a genuinely slow link still fails" "${underperf}"
fi

# The threshold must stay below the ceiling, or the same trap reopens.
overshoot=""
for spd in 1000 10000 25000 100000 400000; do
  ceil="$(awk -v s="${spd}" -v e="$(_goodput_efficiency 1500)" 'BEGIN{printf "%.0f", s*e}')"
  t="$(thr "${spd}")"
  (( t <= ceil )) || overshoot="${overshoot} ${spd}(thr ${t} > ceiling ${ceil})"
done
if [[ -z "${overshoot}" ]]; then
  ok "the threshold never exceeds the physical ceiling at any speed"
else
  bad "the threshold never exceeds the physical ceiling at any speed" "${overshoot}"
fi

# ---- source guard ----
if grep -q '_thr_mbps=$(awk -v s="${_netspd}" -v p="${_pct}" -v e="${_eff}"' "${NET_TEST}"; then
  ok "net_test applies the efficiency term when computing the threshold"
else
  bad "net_test applies the efficiency term when computing the threshold" \
      "$(grep -n '_thr_mbps=' "${NET_TEST}")"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
