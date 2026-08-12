---
id: BUG0054
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [NET018, NET008]
related_bugs: [BUG0048, BUG0055]
---

# BUG0054 — the jumbo DF ping tripped the ERR trap

## Symptom

Every speed whose 9000-MTU jumbo test failed also produced a phantom record:

```
"reason": "unhandled command failure (exit 1) at line 374: sudo -S ip netns exec \"${ns}\" ping -M do -s \"${payload}\" -c 2 -W 2 \"${dst}\" 2>&1",
"verdict": "ERROR"
```

The correlation is exact: in session `20260811T141916`, the four speeds with
`jumbo: FAIL` each carried one, and 200000 — the only speed with `jumbo: PASS`
— carried none.

## Root cause

The same defect BUG0048 fixed in `_ping_check` and `_extract_rate`, at a third
site that was missed:

```bash
out="$(… ping -M do -s "${payload}" -c 2 -W 2 "${dst}" 2>&1)"
rc=$?
```

A DF ping that cannot cross the link exits non-zero, and that is the **answer**
this function exists to obtain — `rc` is inspected on the very next lines to
distinguish `FAIL-FRAG` from `FAIL`. But a bare assignment from a command
substitution carries the substitution's exit status, so the ERR trap fired on a
fully handled path.

## Fix

```bash
out="$(… )" && rc=0 || rc=$?
```

An `&&`/`||` list is a compound command, which the ERR trap does not fire on,
and `rc` still receives the real exit status — necessary, since `FAIL-FRAG` and
`FAIL` are told apart by inspecting the output afterwards.

`|| true` would have silenced the trap too, but it would also have forced `rc=0`
and collapsed the two verdicts into one.

## Verification

`src/bash-shell/test_net_error_trap.sh` — the source uses the compound form; and
the form is exercised directly to confirm it both suppresses the trap and
preserves the exit status and output together.
