---
id: BUG0003
status: open
created: 2026-04-30
os:
  - Ubuntu 24.04 LTS
related_requirements: []
related_bugs: []
---

# BUG0003 — Safe to power off message misleading

## Symptom

Candidate: "Safe to power off" message also fires on SIGINT/SIGTERM, indistinguishable from normal completion.
