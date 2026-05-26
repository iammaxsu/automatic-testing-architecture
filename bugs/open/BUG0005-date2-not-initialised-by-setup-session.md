---
id: BUG0005
status: open
created: 2026-05-05
os:
  - Ubuntu 24.04 LTS
related_requirements: []
related_bugs: []
---

# BUG0005 — _date2 not initialised by setup_session

## Symptom

_date2 referenced by disk_test.sh (lines 34, 36, 154) but not initialised by setup_session() in config.sh. Currently worked around by Ansible passing it via env var.

## Fix

Recommended fix (Route C): in setup_session(), set _date2 as a backwards-compatible alias of _now_timestamp. New code should use _now_timestamp or _session_id directly. Related cleanup: _date1 is referenced nowhere in the codebase and can be removed entirely without alias.
