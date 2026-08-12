#!/usr/bin/env bash
# test_shell_scope.sh — `local` outside a function (BUG0059)
#
# `local` at top level is a fatal error in bash. Under `set -Eeuo pipefail` --
# which every script here enables -- it aborts the run on the spot. `bash -n`
# does NOT catch it: the syntax is valid, the failure is at execution.
#
# It killed a completed 64-minute net_test after the last iteration but before
# the report was written, so the whole run's HTML output was lost while every
# per-pair log looked healthy.
#
# Run:  ./test_shell_scope.sh
# Exit: 0 = all pass, 1 = a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; echo "        --- got ---"; echo "${2}"; FAIL=$((FAIL + 1)); }

echo "Shell scope"

# Track function nesting by brace depth. Function definitions may be indented --
# they are legal inside an if/while block, and missing that produced a false
# positive on setup_dut.sh's _grub_set().
scan() {
  awk '
    # A function is "name() {" at some indent; its body ends at the first "}" at
    # that SAME indent. Matching on indentation rather than counting braces is
    # immune to the braces inside ${...}, $(...), jq filters and awk programs,
    # which is what made a brace-counting version report every local in the file.
    {
      if (!infn && match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) {
        infn = 1
        ind = $0; sub(/[^[:space:]].*$/, "", ind); fnind = length(ind)
        next
      }
      if (infn) {
        ind = $0; sub(/[^[:space:]].*$/, "", ind)
        if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/ && length(ind) == fnind) infn = 0
        next
      }
      if ($0 ~ /^[[:space:]]*local[[:space:]]/) printf "%s:%d: %s\n", FILENAME, FNR, $0
    }
  ' "$@"
}

# This file is excluded from its own scan: the fixture below deliberately
# contains a top-level `local`, and matching it would make the check permanently
# red. Everything else in the directory, tests included, is scanned.
mapfile -t _targets < <(find "${SCRIPT_DIR}" -maxdepth 1 -name '*.sh' \
                          ! -name 'test_shell_scope.sh' | sort)
hits="$(scan "${_targets[@]}")"
if [[ -z "${hits}" ]]; then
  ok "no script uses \`local\` outside a function"
else
  bad "no script uses \`local\` outside a function" "${hits}"
fi

# Non-vacuous: the scanner must actually catch the pattern, and must not flag an
# indented function definition, which is what made the first version cry wolf.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/bad.sh" <<'EOF'
#!/usr/bin/env bash
f() {
  local ok_here=1
}
if true; then
  g() {
    local also_ok=1
  }
fi
local broken=1
EOF
det="$(scan "${TMP}/bad.sh")"
if [[ "$(grep -c . <<<"${det}")" == "1" && "${det}" == *"local broken=1"* ]]; then
  ok "the scanner catches a top-level \`local\` and only that one"
else
  bad "the scanner catches a top-level \`local\` and only that one" "${det}"
fi

# The failure mode itself, so the cost is on record rather than asserted.
out="$(bash -c 'set -Eeuo pipefail; echo reached; local x; echo unreachable' 2>&1 || true)"
if [[ "${out}" == *"can only be used in a function"* && "${out}" != *unreachable* ]]; then
  ok "top-level \`local\` aborts the script under set -e"
else
  bad "top-level \`local\` aborts the script under set -e" "${out}"
fi

# And that `bash -n` cannot see it — which is why this test exists.
if bash -n "${TMP}/bad.sh" 2>/dev/null; then
  ok "bash -n does not catch it, so a syntax check is not enough"
else
  bad "bash -n does not catch it, so a syntax check is not enough" \
      "(bash -n unexpectedly rejected the file)"
fi

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
