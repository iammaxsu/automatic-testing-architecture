---
id: BUG0007
status: open
created: 2026-05-05
os:
  - Ubuntu 24.04 LTS
related_requirements: []
related_bugs: [BUG0022]
---

# BUG0007 — wall broadcast progress message uses 1/1 ETA 0s

## Symptom

wall broadcast progress message uses 1/1 ETA: 0s for "last loop entering final stage" — easily misread as "completed". Caused operator confusion during Ansible async run.

## Fix

Suggest changing wording to e.g. Phase: fio pattern 5/8 on disk 1/1 (loop 1/1).
