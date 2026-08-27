#!/usr/bin/env bash
# test_net_mac_filter.sh — NET019 MAC-list diagnostics (BUG0047)
#
# Drives function.sh's MAC helpers against a faked /sys/class/net, so the
# whitelist/blacklist diagnostics can be checked without real NICs.
#
# The case that motivated this: two NICs on one card whose MACs differ only in
# the last two octets (…b4:48 and …b5:cf). A one-character typo in the whitelist
# (…b4:cf) silently dropped the second NIC, and the operator had to diff four
# MACs by eye to find it.
#
# Run:  ./test_net_mac_filter.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_SH="${SCRIPT_DIR}/function.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---- fake sysfs: the DUT's actual NICs from the AXE-7400GRW ----
mk_nic() { mkdir -p "${TMP}/sys/$1"; printf '%s\n' "$2" > "${TMP}/sys/$1/address"; }
mk_nic lo      00:00:00:00:00:00
mk_nic enp12s0 c4:12:f5:30:b4:48
mk_nic enp12s2 c4:12:f5:30:b5:cf
mk_nic enp45s0 00:30:64:7f:95:02
mk_nic enp48s0 00:30:64:7f:95:03

# Extract the MAC helpers, retargeted at the fake sysfs. Sourcing function.sh
# whole would pull in its top-level side effects.
sed -n '/^__norm_mac()/,/^}/p;/^__nic_mac()/,/^}/p;/^__mac_split()/,/^}/p;/^__mac_in_list()/,/^}/p;/^__mac_report_unmatched()/,/^}/p' \
    "${FUNCTION_SH}" | sed "s#/sys/class/net#${TMP}/sys#g" > "${TMP}/lib.sh"
# shellcheck disable=SC1090
source "${TMP}/lib.sh"

report() {
  local list="$1"
  local -a macs=()
  __mac_split macs "${list}"
  __mac_report_unmatched "_net_include_macs (whitelist)" "${macs[@]}" 2>&1
}

echo "NET019 MAC-list diagnostics"

# 1. The reported bug: B4-CF should have been B5-CF.
out="$(report 'C4-12-F5-30-B4-48,C4-12-F5-30-B4-CF')"
if [[ "${out}" == *"'c4:12:f5:30:b4:cf' matches no NIC"* ]]; then
  ok "typo'd entry is named"
else
  bad "typo'd entry is named" "${out}"
fi

# 2. The suggestion must point at the NIC the operator MEANT, not at the one the
#    other whitelist entry already matches — both are one octet away.
if [[ "${out}" == *"enp12s2 (c4:12:f5:30:b5:cf)"* && "${out}" != *"enp12s0"* ]]; then
  ok "suggestion skips the NIC already claimed by another entry"
else
  bad "suggestion skips the NIC already claimed by another entry" "${out}"
fi

# 3. A correct list says nothing at all.
out="$(report 'C4-12-F5-30-B4-48,C4-12-F5-30-B5-CF')"
if [[ -z "${out}" ]]; then
  ok "correct whitelist is silent"
else
  bad "correct whitelist is silent" "${out}"
fi

# 4. Separator and case normalisation (colons, lowercase, spaces).
out="$(report 'c4:12:f5:30:b4:48 ; C4-12-F5-30-B5-CF')"
if [[ -z "${out}" ]]; then
  ok "mixed separators and case normalise"
else
  bad "mixed separators and case normalise" "${out}"
fi

# 5. An unrelated MAC must not produce a misleading "did you mean".
out="$(report 'AA-BB-CC-DD-EE-FF')"
if [[ "${out}" == *"No similar MAC present"* ]]; then
  ok "unrelated MAC gets no bogus suggestion"
else
  bad "unrelated MAC gets no bogus suggestion" "${out}"
fi

# 6. A genuine tie lists every candidate rather than picking one.
out="$(report '00-30-64-7F-95-04')"
if [[ "${out}" == *"enp45s0"* && "${out}" == *"enp48s0"* ]]; then
  ok "ambiguous typo lists all equally-near NICs"
else
  bad "ambiguous typo lists all equally-near NICs" "${out}"
fi

# 7. An empty list is a no-op, not an error.
out="$(__mac_report_unmatched "_net_include_macs (whitelist)" 2>&1)"
if [[ -z "${out}" ]]; then
  ok "empty list is a no-op"
else
  bad "empty list is a no-op" "${out}"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
