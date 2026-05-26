---
id: BUG0013
status: open
created: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: [LOG014, FUN005]
related_bugs: []
---

# BUG0013 — Log entries do not include log level prefix

## Symptom

LOG014 requires each log entry to be prefixed with timestamp and log level (DEBUG/INFO/WARN/ERROR/FATAL). Current implementation in function.sh log() only prefixes timestamp; main logs across disk_test, net_test, dev_detect contain entries like [2026-05-04 11:34:42] ==== disk_test.sh ==== without level marker.

## Fix

Phase 3 fix: extend log() in function.sh to accept (level, message) per FUN005, e.g. log INFO "starting disk test". Backwards compatibility: keep log "msg" as shorthand for log INFO "msg".
