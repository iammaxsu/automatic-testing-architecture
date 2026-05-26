---
id: BUG0015
status: open
created: 2026-05-05
os:
  - Ubuntu 26.04 LTS
related_requirements: [NET011, NET012]
related_bugs: []
---

# BUG0015 — net_test.sh consumes the SSH lifeline NIC

## Symptom

net_test.sh enumerates all enp* NICs and moves them into network namespaces. If the SSH session is using one of those NICs (e.g. enp49s0 on test02), the SSH session is killed when its NIC is moved, and Ansible loses contact with the DUT.

## Fix

Workaround: route SSH through a non-enp NIC (e.g. enx* USB Ethernet, or ens*). Phase 3 fix: implement NET011 (include/exclude lists) + NET012 (lifeline detection safeguard).
