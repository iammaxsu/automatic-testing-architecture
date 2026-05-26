---
id: BUG0018
status: closed
created: 2026-05-06
closed: 2026-05-07
os:
  - Ubuntu 26.04 LTS
related_requirements: [LOG018]
related_bugs: [BUG0001]
---

# BUG0018 — HTML report Total test time computed from file mtimes

## Symptom

All three generate_*_report functions in function.sh compute total_time_str by stat -c %Y on summary files and subtracting min from max mtime. Two issues: (1) When only 1 loop is run, find returns 1 file, t_first == t_last, elapsed = 0. (2) Even with multiple loops, the approach is wrong: e.g. net_test appends to a single _netsum file, so its mtime only reflects the last write.

## Fix

Resolved 2026-05-07 by commit 3 — generate_disk_report rewritten to read elapsed_human from result.json. Verified on AXE-7400GRW: HTML shows 00:03:01, no longer 00h 00m 00s.
