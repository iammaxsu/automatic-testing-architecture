---
id: BUG0059
status: resolved
created: 2026-08-12
closed: 2026-08-12
os: [Ubuntu 24.04 LTS]
related_requirements: [LOG015, FWK028]
related_bugs: [BUG0055]
---

# BUG0059 — `local` at top level aborted the run after the last iteration, losing the report

## Symptom

A complete 64-minute `net_test.sh` run produced its summary and every per-pair
log, then produced **no HTML report**. The main log simply stops:

```
[2026-08-12 10:12:35] [Pair 0] START  ens18f0np0<->ens18f1np1
[2026-08-12 11:16:47] [Pair 0] DONE   ens18f0np0<->ens18f1np1
[2026-08-12 11:16:47] === Iteration 1/1 DONE ===
```

Nothing follows — no report path, no completion banner. Every measurement had
already been taken; only the artefact that presents them was lost.

## Root cause

Introduced by this project's own BUG0055 fix, one commit earlier. The
unclaimed-note conversion added at merge time began with:

```bash
local _mk _mspd
```

but that loop runs at **top level**, not inside a function. `local` outside a
function is a fatal error in bash:

```
bash: local: can only be used in a function
```

Every script here sets `set -Eeuo pipefail`, so the run aborted on that line —
immediately after the iteration finished and immediately before the report was
generated.

Two things let it through:

1. **`bash -n` does not catch it.** The syntax is valid; the failure happens at
   execution. The change was syntax-checked and passed.
2. **No test exercised the merge path.** Every test added for BUG0055 examined
   `_pair_abort` and `_claim_abort_note` in isolation. The code that ran
   *between* them and the report was never executed by anything but the DUT.

## Fix

Drop the `local`. The variables are top-level by necessity there.

`src/bash-shell/test_shell_scope.sh` scans every script for `local` used outside
a function so this class cannot recur. It matches a function's extent by
**indentation** — `name() {` at indent N closes at the first `}` at indent N —
rather than by counting braces, because braces inside `${…}`, `$(…)`, jq filters
and embedded awk programs make brace counting report nearly every `local` in the
file. A first, brace-counting version did exactly that, and also cried wolf on
`setup_dut.sh`'s legitimately indented `_grub_set()`.

## Verification

`./src/bash-shell/test_shell_scope.sh` — no script uses top-level `local`; the
scanner is shown to catch the pattern and to flag only it, including not
flagging an indented function definition; top-level `local` is demonstrated to
abort under `set -e`; and `bash -n` is demonstrated not to catch it, which is
why the check exists at all.

Checked against the actual regression: with the offending line restored, the
scan fails and names `net_test.sh:1159`.

## Note

The cost here was an hour of bench time and a lost report, from a defect in a
fix for a reporting bug. The lesson recorded in `docs/branch-and-pr-hygiene.md`
applies: a change to the path that runs *after* the measurements is not covered
by unit tests of the pieces on either side of it.
