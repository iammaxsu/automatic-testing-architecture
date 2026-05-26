---
id: BUG0002
status: closed
created: 2026-04-29
closed: 2026-05-05
os:
  - Ubuntu 24.04 LTS
related_requirements: [FWK026, LOG021]
related_bugs: []
---

# BUG0002 — Cannot open dev_detect.sh html report

## Symptom

Due to the owner is root, it CANNOT open the html report of dev_detect.sh.

## Fix

Closed 2026-05-05 — fix_log_permissions() in function.sh chowns output to ${SUDO_USER:-${USER}} via trap EXIT (FWK026 + LOG021). Verified: dev_detect.sh output owned by adlink:adlink, not root.
