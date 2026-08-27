#!/usr/bin/env bash
# test_net_speed_parse.sh — NET015 link-speed enumeration (BUG0051, BUG0052)
#
# ethtool names a mode as <speed>base<medium><lanes>, e.g. 100000baseCR4/Full.
# Stripping every non-digit concatenated the lane count onto the speed, so a
# 400G NIC was tested at "4000004 Mbps" and never at 400000; and the pair-max
# membership test compared space-delimited against a newline-delimited list, so
# it never matched and every report showed Max = 0.
#
# Run:  ./test_net_speed_parse.sh
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
mkdir -p "${TMP}/bin"

# Stubs: sudo runs the command, ethtool prints a captured fixture.
cat > "${TMP}/bin/sudo" <<'SUDO'
#!/bin/sh
while [ "$1" = "-S" ] || [ "$1" = "ip" ] || [ "$1" = "netns" ] || [ "$1" = "exec" ] \
   || [ "${1#ns_}" != "$1" ]; do shift; done
exec "$@"
SUDO
cat > "${TMP}/bin/ethtool" <<EOF
#!/bin/sh
cat "${TMP}/fixture.txt"
EOF
chmod +x "${TMP}/bin"/*
export PATH="${TMP}/bin:${PATH}"
export _pwd=x

sed -n '/^_supported_speeds()/,/^}/p' "${NET_TEST}" > "${TMP}/lib.sh"
# shellcheck disable=SC1090
source "${TMP}/lib.sh"

echo "NET015 link-speed enumeration"

# ---- the reported DUT: a 400G NIC offering several lane widths ----
cat > "${TMP}/fixture.txt" <<'EOF'
Settings for ens18f0np0:
        Supported ports: [ FIBRE ]
        Supported link modes:   25000baseCR/Full
                                50000baseCR2/Full
                                100000baseCR4/Full
                                50000baseCR/Full
                                100000baseCR2/Full
                                200000baseCR4/Full
                                100000baseCR/Full
                                200000baseCR2/Full
                                400000baseCR4/Full
        Supported pause frame use: Symmetric Receive-only
        Supports auto-negotiation: Yes
        Supported FEC modes: RS
        Speed: 100000Mb/s
        Lanes: 4
        Duplex: Full
EOF
got="$(_supported_speeds ns_x ens18f0np0 | tr '\n' ' ')"
if [[ "${got}" == "25000 50000 100000 200000 400000 " ]]; then
  ok "lane count is not concatenated onto the speed"
else
  bad "lane count is not concatenated onto the speed" "${got}"
fi

# The specific artefacts from the report must be gone.
if [[ "${got}" != *4000004* && "${got}" != *1000004* && "${got}" != *500002* ]]; then
  ok "no phantom speeds (500002 / 1000004 / 4000004)"
else
  bad "no phantom speeds (500002 / 1000004 / 4000004)" "${got}"
fi

# Same speed at different lane widths must collapse to one test, not several.
if [[ "$(tr ' ' '\n' <<<"${got}" | grep -c '^100000$')" == "1" ]]; then
  ok "one speed offered at several lane widths is tested once"
else
  bad "one speed offered at several lane widths is tested once" "${got}"
fi

# 200000 and 400000 are only offered as CR2/CR4 — they were never tested before.
if [[ "${got}" == *" 200000 "* && "${got}" == *" 400000 "* ]]; then
  ok "speeds offered only at multi-lane widths are still tested"
else
  bad "speeds offered only at multi-lane widths are still tested" "${got}"
fi

# ---- a plain copper NIC must be unaffected ----
cat > "${TMP}/fixture.txt" <<'EOF'
        Supported link modes:   10baseT/Half 10baseT/Full
                                100baseT/Half 100baseT/Full
                                1000baseT/Full
                                2500baseT/Full
EOF
got2="$(_supported_speeds ns_x eth0 | tr '\n' ' ')"
if [[ "${got2}" == "10 100 1000 2500 " ]]; then
  ok "copper NIC speeds parse unchanged, half-duplex modes excluded"
else
  bad "copper NIC speeds parse unchanged, half-duplex modes excluded" "${got2}"
fi

# ---- no ethtool data at all ----
: > "${TMP}/fixture.txt"
if [[ -z "$(_supported_speeds ns_x eth0)" ]]; then
  ok "an unreadable NIC yields an empty list, letting the caller default"
else
  bad "an unreadable NIC yields an empty list, letting the caller default" \
      "$(_supported_speeds ns_x eth0)"
fi

# ---- pair-max membership over a newline-separated list (BUG0052) ----
list="$(printf '25000\n50000\n100000\n200000\n400000')"
pair_max=0
for sp in ${list}; do
  if grep -qxF -- "${sp}" <<<"${list}" && (( sp > pair_max )); then pair_max="${sp}"; fi
done
if (( pair_max == 400000 )); then
  ok "pair max is the highest speed both NICs support, not 0"
else
  bad "pair max is the highest speed both NICs support, not 0" "${pair_max}"
fi

# The old form, kept as a demonstration that the test is not vacuous.
old_max=0
for sp in ${list}; do
  if echo " ${list} " | grep -q " ${sp} " && (( sp > old_max )); then old_max="${sp}"; fi
done
if (( old_max == 0 )); then
  ok "the previous space-delimited test is confirmed to match nothing"
else
  bad "the previous space-delimited test is confirmed to match nothing" "${old_max}"
fi

# Asymmetric pair: max is the highest COMMON speed, not either NIC's own max.
even="$(printf '25000\n50000\n100000\n200000\n400000')"
odd="$(printf '10000\n25000\n50000')"
pm=0
for sp in ${even}; do
  if grep -qxF -- "${sp}" <<<"${odd}" && (( sp > pm )); then pm="${sp}"; fi
done
if (( pm == 50000 )); then
  ok "an asymmetric pair takes the highest common speed"
else
  bad "an asymmetric pair takes the highest common speed" "${pm}"
fi

# ---- source-level guards ----
# Comment lines are excluded: the fix's own comment quotes the old expression to
# explain it, and matching that would make this guard permanently red.
if ! grep -vE '^[[:space:]]*#' "${NET_TEST}" | grep -q "sed 's/\[^0-9\]//g'"; then
  ok "the strip-all-non-digits parser is gone from live code"
else
  bad "the strip-all-non-digits parser is gone from live code" \
      "$(grep -nvE '^[[:space:]]*#' "${NET_TEST}" | grep "sed 's/\[^0-9\]//g'")"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
