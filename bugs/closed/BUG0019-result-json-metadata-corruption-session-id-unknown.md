---
id: BUG0019
status: closed
created: 2026-05-07
closed: 2026-05-07
os:
  - Ubuntu 26.04 LTS
related_requirements: [FWK027, LOG015, LOG020, LOG022]
related_bugs: []
---

# BUG0019 — result.json metadata corruption session_id unknown elapsed_seconds 0

## Symptom

First e2e run of commit 2 (disk_test with emit_result_json) produced a result.json with session_id: "unknown" and execution.elapsed_seconds: 0 (start == end timestamp). Two independent framework-level root causes: (1) counter_tick unset _session_id on completion. (2) _session_t0 was never set — disk_test.sh does not call setup_session().

## Fix

Resolved 2026-05-07 by two surgical changes in function.sh: (1) Removed unset _session_id from counter_tick. (2) run_time() now also seeds _session_t0 via : "${_session_t0:=${_RUN_T0}}". Verified on AXE-7400GRW (Ubuntu 26.04) 2026-05-07: session_id="session_20260507T150804_33091", elapsed_seconds=167.
