---
id: BUG0006
status: open
created: 2026-05-05
os:
  - Ubuntu 24.04 LTS
related_requirements: []
related_bugs: [BUG0001]
---

# BUG0006 — disk_test.sh does not call run_time at start

## Symptom

Causes _RUN_T0 to remain unset; elp_time falls back to _session_t0, which has different start point semantics. Related to BUG0001.
