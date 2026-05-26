---
id: BUG0020
status: open
created: 2026-05-08
os:
  - Ubuntu 26.04 LTS
related_requirements: [SLP001, SLP004, SLP005]
related_bugs: [BUG0015]
---

# BUG0020 — sleep_test not yet integrated or verified

## Symptom

SLP001-SLP005 requirements are defined. A sleep_test.sh file exists locally but is untracked (not committed to the repo) and has not been end-to-end verified via Ansible. No session log, result.json, or HTML report has been produced.

## Fix

Phase 3 item. Prerequisite: resolve BUG0015 (SSH lifeline) so Ansible can safely run sleep cycles on remote DUTs.
