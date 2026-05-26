---
id: BUG0011
status: closed
created: 2026-05-05
closed: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: [CMP005]
related_bugs: []
---

# BUG0011 — dev_detect aborts silently when an upstream detector tool is missing

## Symptom

dev_detect.sh aborts under non-root execution because dmidecode -t memory and lsusb -v require root for SMBIOS / USB descriptor access on Ubuntu 26.04 LTS. Combined with set -Eeuo pipefail + pipefail, the failed command's non-zero exit propagates through the awk pipeline and aborts the script after detect_ram.

## Fix

Two-layer fix: (a) Ansible playbook installs all required tools (immediate). (b) Phase 3: wrap each detect_* call in a _safe layer that captures stderr to ${_devlog}.errors and continues on failure, so a single broken detector does not crash the whole inventory.
