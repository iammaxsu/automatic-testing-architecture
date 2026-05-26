---
id: BUG0012
status: open
created: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: [DET009]
related_bugs: []
---

# BUG0012 — dev_detect first-run snapshot vs golden template not visually distinguishable

## Symptom

On first run, dev_detect.sh produces a snapshot file and copies it to golden/dev_detect.golden.txt. Even though the design intent labels the run as INIT (via loop_result="INIT" and final filename suffix _INIT.log), users may still confuse the role of the snapshot vs. the golden template because both contain identical content.

## Fix

Existing design (line 776 of dev_detect.sh) already produces dev_detect_<session>_1_of_1_INIT.log as a marker — verify this works once BUG0011 is fixed.
