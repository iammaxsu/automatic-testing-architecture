#!/usr/bin/env bash
# test_net_error_trap.sh — NET ERR-trap false positives (BUG0048)
#
# A pair whose two NICs cannot reach each other produced 32 "[ERROR] worker
# aborted" lines and 32 identical ERROR records for a single 10 Mbps iteration.
# None of them was an abort: the ERR trap was firing on commands that fail by
# design and are handled on the next line — ping with 100% loss, and grep
# finding no rate in an iperf3 log that never connected.
#
# Run:  ./test_net_error_trap.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_TEST="${SCRIPT_DIR}/net_test.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

export TMP   # the snippets below run in a child shell and reference it
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Pull the extractors out of net_test.sh. Sourcing it whole would run the test.
sed -n '/^_extract_rate()/,/^}/p;/^_extract_mbps_num()/,/^}/p;/^_extract_retr()/,/^}/p;/^_extract_udp_jitter()/,/^}/p;/^_extract_udp_loss()/,/^}/p' \
    "${NET_TEST}" > "${TMP}/lib.sh"

# An iperf3 client log from a link that never came up — the reported case.
cat > "${TMP}/failed.log" <<'EOF'
Connecting to host 192.247.0.11, port 5201
iperf3: error - unable to connect to server - server may have stopped running or use a different port, firewall issue, etc.: Connection timed out
EOF

# A normal iperf3 log, so the extractors are shown to still work.
cat > "${TMP}/ok.log" <<'EOF'
[  5]   0.00-10.00  sec  1.09 GBytes   938 Mbits/sec                  sender
[  5]   0.00-10.00  sec  1.09 GBytes   936 Mbits/sec                  receiver
EOF

echo "NET ERR-trap false positives"

# Run a snippet with the caller's real settings: set -Eeuo pipefail plus an ERR
# trap that announces itself. stderr is folded in so nothing is missed.
run_snippet() {
  bash -c "
    set -Eeuo pipefail
    source '${TMP}/lib.sh'
    trap 'echo TRAP:\${LINENO}:\${BASH_COMMAND}' ERR
    $1
  " 2>&1
}

# 1. Under the caller's own settings (set -Eeuo pipefail + an ERR trap), the
#    extractors must not trip the trap on a log with no rate in it.
out="$(run_snippet '
  r="$(_extract_rate "${TMP}/failed.log")"
  n="$(_extract_mbps_num "${TMP}/failed.log")"
  echo "rate=[${r}] mbps=[${n}]"
')"
if [[ "${out}" != *TRAP:* ]]; then
  ok "no-rate log does not trip the ERR trap"
else
  bad "no-rate log does not trip the ERR trap" "${out}"
fi

# 2. …and still reports the documented empty / zero result.
if [[ "${out}" == *"rate=[] mbps=[0]"* ]]; then
  ok "no-rate log yields empty rate and 0 Mbps"
else
  bad "no-rate log yields empty rate and 0 Mbps" "${out}"
fi

# 3. A healthy log must still parse.
out2="$(run_snippet '
  echo "rate=[$(_extract_rate "${TMP}/ok.log")] mbps=[$(_extract_mbps_num "${TMP}/ok.log")]"
')"
if [[ "${out2}" == *"936 Mbits/sec"* && "${out2}" == *"mbps=[936]"* && "${out2}" != *TRAP:* ]]; then
  ok "healthy log still parses to 936 Mbps"
else
  bad "healthy log still parses to 936 Mbps" "${out2}"
fi

# 4. A failing ping must not trip the trap either. _ping_check needs netns and
#    sudo, so exercise the pipeline shape it uses: a command that exits non-zero
#    feeding tee, under pipefail.
out3="$(run_snippet '
  t="${TMP}/ping.out"
  { echo "4 packets transmitted, 0 received, 100% packet loss"; exit 1; } \
    | tee "${t}" >> "${TMP}/ping.log" || true
  grep -q " 0% packet loss" "${t}" && echo "PASS" || echo "FAIL"
')"
if [[ "${out3}" == "FAIL" ]]; then
  ok "100%-loss ping yields FAIL without tripping the trap"
else
  bad "100%-loss ping yields FAIL without tripping the trap" "${out3}"
fi

# 5. The source itself must keep the guards — they are one ` || true` away from
#    being "tidied" back out, and the failure only shows on real hardware.
if grep -q 'tee "${tmpf}" >> "${logfile}" || true' "${NET_TEST}" &&
   grep -q "grep -oE '\[0-9.\]+\\\\s+\[KMG\]?bits/sec' | tail -n1 || true" "${NET_TEST}"; then
  ok "the || true guards are still present in net_test.sh"
else
  bad "the || true guards are still present in net_test.sh" "(guard missing)"
fi

# 6. _pair_abort must dedupe per (iteration, speed) rather than per firing.
if grep -q '_marker="${pair_json}.err.${_k:-0}.${_netspd:-0}"' "${NET_TEST}" &&
   grep -q '\[\[ -e "${_marker}" \]\] && return 0' "${NET_TEST}"; then
  ok "_pair_abort dedupes per iteration and speed"
else
  bad "_pair_abort dedupes per iteration and speed" "(dedupe missing)"
fi

# 7. The handler must not claim an abort it cannot know happened.
if ! grep -q 'worker aborted (exit' "${NET_TEST}"; then
  ok "handler no longer claims 'worker aborted'"
else
  bad "handler no longer claims 'worker aborted'" "$(grep -n 'worker aborted (exit' "${NET_TEST}")"
fi

# 8. The jumbo DF ping is the same defect class at a site BUG0048 missed: a
#    failing ping is the answer, and rc is inspected on the next line (BUG0054).
if grep -q 'ping -M do -s "${payload}" -c 2 -W 2 "${dst}" 2>&1)" && rc=0 || rc=$?' "${NET_TEST}"; then
  ok "the jumbo DF ping cannot trip the ERR trap"
else
  bad "the jumbo DF ping cannot trip the ERR trap" \
      "$(grep -n 'ping -M do' "${NET_TEST}")"
fi

# The compound form must still preserve the real exit status, or FAIL-FRAG and
# FAIL become indistinguishable.
out3b="$(
  set -Eeuo pipefail
  trap 'echo TRAP' ERR
  o="$( { echo "ping: local error: message too long"; exit 1; } 2>&1 )" && rc=0 || rc=$?
  echo "rc=${rc} matched=$(grep -qiE 'message too long' <<<"${o}" && echo yes || echo no)"
)"
if [[ "${out3b}" == "rc=1 matched=yes" ]]; then
  ok "the compound form keeps the exit status and the output"
else
  bad "the compound form keeps the exit status and the output" "${out3b}"
fi

# 9. The trap must record a NOTE, not a second result row for the same speed
#    (BUG0055) -- that is what made every failing speed appear twice.
# Scoped to _pair_abort's own body: the merge step legitimately appends a
# speeds[] row for a note nobody claimed, and must not trip this.
abort_body="$(sed -n '/^_pair_abort()/,/^}/p' "${NET_TEST}")"
if grep -q 'printf .* > "${_marker}"' <<<"${abort_body}" &&
   ! grep -q 'speeds +=' <<<"${abort_body}"; then
  ok "_pair_abort writes a note, not a speeds[] row"
else
  bad "_pair_abort writes a note, not a speeds[] row" \
      "$(grep -n 'speeds +=' <<<"${abort_body}")"
fi

if grep -q '_abort_note="$(_claim_abort_note)"' "${NET_TEST}"; then
  ok "the real record claims and folds in the note"
else
  bad "the real record claims and folds in the note" "(claim missing)"
fi

# 10. Link state must be verified rather than slept through (BUG0056).
if grep -q '_wait_link_up "ns_${ev}" "${ev}" "${_netspd}"' "${NET_TEST}" &&
   ! grep -qE '^\s+sleep 4$' "${NET_TEST}"; then
  ok "carrier is waited for, not guessed with a fixed sleep"
else
  bad "carrier is waited for, not guessed with a fixed sleep" \
      "$(grep -nE '^\s+sleep 4$|_wait_link_up' "${NET_TEST}" | head -3)"
fi

# 11. The neighbour cache must be primed before measuring (BUG0060). A speed
#     change drops carrier and clears the ARP/ND entry; the first packet then
#     pays for resolution and ping counts it as loss.
ping_body="$(sed -n '/^_ping_check()/,/^}/p' "${NET_TEST}")"
if grep -q -- '-c 1 -W 2 "${addr}"' <<<"${ping_body}" &&
   grep -q '>/dev/null 2>&1 || true' <<<"${ping_body}"; then
  ok "a discarded priming packet precedes the measurement"
else
  bad "a discarded priming packet precedes the measurement" "${ping_body}"
fi

# The priming packet must not reach the log or the verdict.
if [[ "$(grep -c -- '-c 4 "${addr}"' <<<"${ping_body}")" == "1" ]]; then
  ok "only the 4-packet run is measured and logged"
else
  bad "only the 4-packet run is measured and logged" "${ping_body}"
fi

# Priming must apply to both families, or the asymmetry that made this look
# IPv4-specific simply moves.
if grep -q '_png="ping"; \[\[ "$v6" == "1" \]\] && _png="ping6 -6"' <<<"${ping_body}"; then
  ok "priming and measurement use the same family-selected command"
else
  bad "priming and measurement use the same family-selected command" "${ping_body}"
fi

# The reported symptom, reproduced: 4 sent / 3 received fails a 0%-loss check.
sample="4 packets transmitted, 3 received, 25% packet loss, time 3060ms"
if ! grep -q " 0% packet loss" <<<"${sample}"; then
  ok "a single lost packet is enough to fail the check, hence the priming"
else
  bad "a single lost packet is enough to fail the check" "${sample}"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
