---
id: BUG0016
status: open
created: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: []
related_bugs: []
---

# BUG0016 — DIMM8 row formatting differs from DIMM1-7 in detect_ram output

## Symptom

detect_ram awk script emits the last DIMM (e.g. DIMM8 on test02) with (Manufacturer) parenthesised and different column spacing, while DIMM1-7 use plain Manufacturer with consistent padding. Root cause: the awk END{} block uses a different printf format than the in-loop block.

## Fix

Fix: unify the two printf statements inside the awk script in detect_ram(). Low priority — purely cosmetic, no functional impact.
