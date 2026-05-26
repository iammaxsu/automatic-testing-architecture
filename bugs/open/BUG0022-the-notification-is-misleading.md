---
id: BUG0022
status: open
created: 2026-05-14
os:
  - Ubuntu 26.04 LTS
related_requirements: []
related_bugs: [BUG0007]
---

# BUG0022 — The notification is misleading

## Symptom

The notification pop-up on the desktop always reports "Test in progress - DO NOT POWER OFF" and never updates to reflect the actual phase. Two root causes: (1) The message string is hard-coded and does not encode progress. (2) test_progress_set is only called once per loop (disk_test.sh line ~204, before the inner fio pattern loop). During the entire 8-pattern x per-disk inner loop the notification never refreshes.

## Fix

Phase 3 fix: (a) extend test_progress_set signature to take a sub-phase string; (b) call it inside the fio pattern loop, not only the outer loop; (c) reword to include the sub-phase. Pairs with BUG0007 (similar wording confusion).
