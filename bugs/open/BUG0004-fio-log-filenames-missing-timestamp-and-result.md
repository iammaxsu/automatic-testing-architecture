---
id: BUG0004
status: open
created: 2026-05-05
os:
  - Ubuntu 24.04 LTS
related_requirements: [LOG008, LOG012]
related_bugs: []
---

# BUG0004 — fio log filenames missing timestamp and result

## Symptom

LOG008/LOG012 spec defines <timestamp>_<result> suffix, but actual files (e.g. sdb_RND4KQ1T1_Read_1_of_1.log) omit both.

## Fix

Resolution path: bring disk_test.sh filename generation in line with LOG008/LOG012. Track as code change, not as spec change. Affects LOG013 (summary log already aggregates by base pattern, will not be affected).
