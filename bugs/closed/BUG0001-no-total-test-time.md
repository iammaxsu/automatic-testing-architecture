---
id: BUG0001
status: closed
created: 2026-04-28
closed: 2026-05-07
os:
  - Ubuntu 24.04 LTS
related_requirements: [LOG015, LOG018]
related_bugs: [BUG0018]
---

# BUG0001 — No total test time

## Symptom

Reopened 2026-05-05: Original closure was incomplete. Main log Elapsed verified for disk_test and dev_detect, but HTML report's "Total test time" field is empty/zero due to BUG0018. BUG0001 will close when either (a) BUG0018 is fixed, or (b) result.json + LOG018 makes HTML read elapsed_seconds from result.json directly.

## Fix

Closed 2026-05-07 by BUG0018 resolution (commit 3 — generate_disk_report reads elapsed_human from result.json). Verified on AXE-7400GRW: HTML displays 00:03:01.
