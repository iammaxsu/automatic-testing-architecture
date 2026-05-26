---
id: BUG0017
status: closed
created: 2026-05-05
closed: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: []
related_bugs: [BUG0001, BUG0015]
---

# BUG0017 — net_test elapsed time and end-to-end Ansible flow not yet verified

## Symptom

Spun off from BUG0001 closure. net_test.sh has self-elevate (FWK025) added but full Ansible run not yet performed because BUG0015 (SSH lifeline) is blocking on test02.

## Fix

Closed 2026-05-05 — net_test e2e verified on AXE-7400GRW (Ubuntu 26.04): 4 speeds x 4 tests all PASS, elapsed 17 min, HTML report generated.
