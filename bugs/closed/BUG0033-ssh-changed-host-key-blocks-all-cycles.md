---
id: BUG0033
status: resolved
created: 2026-06-25
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
  - Windows 11
related_requirements: [FWK035, PWR012, PWR009]
related_bugs: [BUG0030, BUG0034]
---

# BUG0033 — Changed SSH host key blocks every test cycle

## Symptom

A real `reboot.py` run against a Windows 11 DUT at `10.0.0.146`: `init_dut()`
powered the DUT on from cold and confirmed it alive (ping) after 101 s — yet every
one of the next three reboot cycles failed immediately with `SSH_ERROR`, and the
run aborted via the early-fail threshold (0 PASS / 3 SSH_ERROR). The captured log
shows the SSH command returning non-zero with the banner:

```
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
...
Offending ECDSA key in /home/max.su/.ssh/known_hosts:5
  remove with:
  ssh-keygen -f "/home/max.su/.ssh/known_hosts" -R "10.0.0.146"
```

The DUT was demonstrably up (it had just been pinged); the failure was the SSH
*client on the control node* refusing to connect.

## Root cause

The control node's `~/.ssh/known_hosts` held an old key for `10.0.0.146` that no
longer matched the key the DUT now presents (the machine had been reimaged / its
OpenSSH host key had changed). Every SSH call site in the framework set only
`-o StrictHostKeyChecking=no`. That option suppresses the prompt for a **first-
contact, unknown** host, but it does **not** override OpenSSH's hard refusal when
an existing `known_hosts` entry's key has **changed** — that case is always
rejected. So `StrictHostKeyChecking=no` alone could never get past a changed key,
and because the framework reuses DUT IPs across reimages, the stale entry blocked
100 % of cycles.

The same incomplete idiom was duplicated across six independent call sites
(`function.py` ×3, `reboot.py`, `shutdown.py`, `sleep_test.py`) plus
`stop_tests.sh`, so none of them could connect to a re-keyed DUT.

## Fix

Introduced `function.ssh_base_opts(connect_timeout)` as the single source of truth
for SSH options (FWK035) and routed all six Python call sites through it. The
option set now adds:

- `UserKnownHostsFile=/dev/null` — never read or persist a host key, so a changed
  key is accepted (safe in a physically controlled lab, where there is no
  meaningful MITM threat between control node and DUT).
- `LogLevel=ERROR` — suppress the now-harmless changed-key warning banner.

`stop_tests.sh` (bash, cannot import `function`) carries the same options inline
with a comment referencing FWK035.

Immediate manual workaround for an already-affected control node (no longer needed
after the fix, but documented for completeness): the banner's own hint,
`ssh-keygen -f ~/.ssh/known_hosts -R "<dut-ip>"`.

## Verification

Sandbox: `function.ssh_base_opts()` returns the expected five-option list; all of
`function.py`, `reboot.py`, `shutdown.py`, `sleep_test.py`, `power_cycle.py`
byte-compile and `stop_tests.sh` passes `bash -n`.

Still pending on real hardware: re-run `reboot.py` against a DUT whose key has
changed since last contact (e.g. freshly reimaged) and confirm cycles connect and
complete instead of failing with "REMOTE HOST IDENTIFICATION HAS CHANGED".
