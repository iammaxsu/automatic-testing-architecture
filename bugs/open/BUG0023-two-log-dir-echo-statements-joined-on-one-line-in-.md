---
id: BUG0023
status: open
created: 2026-05-14
os:
  - Ubuntu 26.04 LTS
related_requirements: []
related_bugs: []
---

# BUG0023 — Two log_dir echo statements joined on one line in function.sh

## Symptom

In function.sh log_dir() (currently line 219), two echo "[INFO] ..." statements are written on the same physical line with only a space between them, instead of being separated by a newline. Result: at runtime they become a single echo invocation that prints [INFO] log dir: /path echo [INFO] session log dir: /path.

## Fix

Trivial cosmetic fix. Low priority.
