#!/usr/bin/env bash
# test_net_method_record.sh — NET009 method traceability (BUG0063)
#
# A verdict is auditable only if the rule that produced it is recoverable from
# the same artefact. This pins that result.json carries the derivation, that the
# report renders the method section FROM that record rather than restating it,
# and that the stream policy resolves as documented.
#
# Run:  ./test_net_method_record.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_TEST="${SCRIPT_DIR}/net_test.sh"
FUNCTION_SH="${SCRIPT_DIR}/function.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "NET009 method traceability"

# ---- build the method record exactly as net_test.sh does ----
sed -n '/^_goodput_efficiency()/,/^}/p;/^_iperf_parallel_for()/,/^}/p' \
    "${NET_TEST}" > "${TMP}/lib.sh"
# shellcheck disable=SC1090
source "${TMP}/lib.sh"

_net_mtu_for_thr=1500; _net_frame_overhead_bytes=38; _net_l3l4_overhead_bytes=52
_net_tcp_pass_pct=95;  _net_tcp_pass_pct_tiers=""
_net_iperf_parallel=auto; _net_parallel_auto_from_mbps=25000; _net_parallel_auto_streams=8
_net_udp_loss_max_pct=1; _net_udp_loss_fail=0; _net_err_fail_on_delta=0

awk '/^_method_json=\$\(jq -n/,/nic_error_counters: \{ gates_verdict/ {print}
     /nic_error_counters: \{ gates_verdict/ {exit}' "${NET_TEST}" > "${TMP}/method.sh"
tail -n1 "${TMP}/method.sh" | grep -q "')" \
  || echo "     gates_verdict: (\$err_gate == 1) } }')" >> "${TMP}/method.sh"
# shellcheck disable=SC1090
source "${TMP}/method.sh"
jq -n --argjson m "${_method_json}" '{details:{method:$m}}' > "${TMP}/result.json"

# ---- every field needed to reconstruct a verdict ----
missing=""
for q in '.details.method.requirement' \
         '.details.method.tcp_threshold.formula' \
         '.details.method.tcp_threshold.mtu_bytes' \
         '.details.method.tcp_threshold.frame_overhead_bytes' \
         '.details.method.tcp_threshold.l3l4_overhead_bytes' \
         '.details.method.tcp_threshold.goodput_efficiency' \
         '.details.method.tcp_threshold.pass_pct' \
         '.details.method.iperf_streams.setting' \
         '.details.method.iperf_streams.auto_from_mbps' \
         '.details.method.iperf_streams.auto_streams' \
         '.details.method.udp_loss.cap_pct' \
         '.details.method.udp_loss.gates_verdict' \
         '.details.method.nic_error_counters.gates_verdict'; do
  # NOT `// empty`: jq's alternative operator treats `false` as unset, so the two
  # gating booleans would look missing whenever they are off — which is their
  # default. Test for the JSON null instead.
  [[ "$(jq -r "${q}" "${TMP}/result.json" 2>/dev/null)" == "null" ]] && missing="${missing} ${q}"
done
if [[ -z "${missing}" ]]; then
  ok "result.json carries every field needed to reconstruct a verdict"
else
  bad "result.json carries every field needed to reconstruct a verdict" "${missing}"
fi

# The recorded efficiency must be the one actually applied, not a restated constant.
rec="$(jq -r '.details.method.tcp_threshold.goodput_efficiency' "${TMP}/result.json")"
if [[ "${rec}" == "0.9415" && "${rec}" == "$(_goodput_efficiency 1500)" ]]; then
  ok "the recorded efficiency is the value the run computed"
else
  bad "the recorded efficiency is the value the run computed" \
      "recorded=${rec} computed=$(_goodput_efficiency 1500)"
fi

# A threshold must be reproducible from the record alone.
repro="$(jq -r '.details.method.tcp_threshold
                | (100000 * .goodput_efficiency * .pass_pct / 100) | floor' "${TMP}/result.json")"
if [[ "${repro}" == "89442" ]]; then
  ok "a 100G threshold is reproducible from the record alone"
else
  bad "a 100G threshold is reproducible from the record alone" "${repro}"
fi

if [[ "$(jq -r '.details.method.requirement' "${TMP}/result.json")" == "NET009" ]]; then
  ok "the record names the requirement it implements"
else
  bad "the record names the requirement it implements" \
      "$(jq -r '.details.method.requirement' "${TMP}/result.json")"
fi

# ---- stream policy ----
policy=""
for row in "10 1" "1000 1" "10000 1" "25000 8" "100000 8" "400000 8"; do
  # shellcheck disable=SC2086
  set -- ${row}
  got="$(_iperf_parallel_for "$1")"
  [[ "${got}" == "$2" ]] || policy="${policy} $1->${got}(want $2)"
done
if [[ -z "${policy}" ]]; then
  ok "auto resolves to 1 below 25G and 8 at or above"
else
  bad "auto resolves to 1 below 25G and 8 at or above" "${policy}"
fi

_net_iperf_parallel=4
if [[ "$(_iperf_parallel_for 1000)" == "4" && "$(_iperf_parallel_for 100000)" == "4" ]]; then
  ok "an explicit stream count overrides auto at every speed"
else
  bad "an explicit stream count overrides auto at every speed" \
      "$(_iperf_parallel_for 1000) / $(_iperf_parallel_for 100000)"
fi
_net_iperf_parallel=auto

# ---- the report renders FROM the record ----
if grep -q "jq -r '.details.method.tcp_threshold.goodput_efficiency" "${FUNCTION_SH}"; then
  ok "the report reads the efficiency from result.json"
else
  bad "the report reads the efficiency from result.json" "(not read)"
fi

# It must not hard-code the ceiling: a stale constant beside a live verdict is
# exactly the failure this requirement is written against.
if ! grep -vE '^[[:space:]]*#' "${FUNCTION_SH}" | grep -q '94\.15'; then
  ok "the report does not hard-code the ceiling"
else
  bad "the report does not hard-code the ceiling" \
      "$(grep -nvE '^[[:space:]]*#' "${FUNCTION_SH}" | grep '94\.15')"
fi

# ---- the tier table is empty by default ----
if grep -q ': "${_net_tcp_pass_pct_tiers:=}"' "${SCRIPT_DIR}/config.sh"; then
  ok "the per-speed tier table is empty by default"
else
  bad "the per-speed tier table is empty by default" \
      "$(grep -n '_net_tcp_pass_pct_tiers' "${SCRIPT_DIR}/config.sh" | head -2)"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
