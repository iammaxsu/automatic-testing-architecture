---
id: BUG0014
status: closed
created: 2026-05-05
closed: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: [FWK025, FWK026]
related_bugs: []
---

# BUG0014 — Root requirement of detection scripts not formalised in spec

## Symptom

dev_detect.sh and net_test.sh require root for hardware access (SMBIOS, USB descriptors, network namespaces, ethtool speed control). This was not stated in spec, leading to BUG0011-class silent failures when invoked as a non-root user.

## Fix

Resolved by adding spec FWK025 (self-elevate via exec sudo -E) and FWK026 (chown via SUDO_USER on EXIT). Both already implemented in function.sh::fix_log_permissions.
