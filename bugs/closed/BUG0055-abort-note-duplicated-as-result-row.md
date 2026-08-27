---
id: BUG0055
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [LOG015, NET008, FWK028]
related_bugs: [BUG0048, BUG0054]
---

# BUG0055 — an ERR-trap note appeared as a second result row for the same speed

## Symptom

Each of 25000, 50000, 100000 and 400000 appeared **twice** in the report:

| Speed | Verdict | Reason |
|---|---|---|
| 25000 | ERROR | unhandled command failure … at line 374 |
| 25000 | FAIL | IPv4 ICMP FAIL; IPv6 ICMP FAIL [jumbo MTU 9000: FAIL] |

The operator reasonably read this as "the speed was tested twice". It was tested
once. "Speed tests run: 11" counted the duplicates.

## Root cause

BUG0048 capped `_pair_abort` at one record per (iteration, speed), which stopped
32 copies. But one copy is still one too many when the speed goes on to complete
and write its real record: the trap's row and the real row then describe the
same test, and the trap's row carries none of the measurements.

The trap could not know which case it was in. At the moment it fires, whether
the worker will recover and produce a real record is still in the future.

## Fix

Defer the decision to when it is answerable.

`_pair_abort` now writes its reason to a **note** keyed by (iteration, speed)
and appends nothing to `.speeds[]`. Then:

- the speed's real record calls `_claim_abort_note`, folds the note into its
  `reason`, and consumes it — one row, carrying both the measurement and the
  failure that occurred during it;
- any note still unclaimed after the pair workers join means the worker really
  did die inside that speed and no real record is coming, so the parent converts
  it into the ERROR row it deserves.

The trap's original purpose — never lose a failure silently — is preserved, and
"unclaimed" is only evaluated once it is knowable.

## Verification

`src/bash-shell/test_net_error_trap.sh` — `_pair_abort`'s own body contains no
`speeds +=` (scoped to the function, since the merge step legitimately appends
one for an unclaimed note); the real record claims and folds the note; and a
note is shown to be consumed exactly once, with a second claim returning empty.
