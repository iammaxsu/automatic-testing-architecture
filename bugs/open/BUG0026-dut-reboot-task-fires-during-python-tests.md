---
id: BUG0026
status: open
created: 2026-06-05
os:
  - Windows 11
related_requirements: [PWR011, PWR012, FWK032]
related_bugs: []
---

# BUG0026 — DUT-Reboot Task Scheduler task fires during Pi-controlled Python tests

## Symptom

While running `power_cycle.py` or `reboot.py` from the Pi against a Windows DUT, the
DUT's local Task Scheduler task `DUT-Reboot` fires on every boot and launches
`reboot.ps1`.  The operator observes:

- `logs/reboot_session.json` and `logs/reboot_<sid>.log` appear under the PowerShell
  script directory even though no DUT-local test was started.
- Log contains a small number of entries (equal to the number of Python-controlled
  reboots since the last manual `-Stop`).
- Deleting the `logs/` folder does not prevent this: Task Scheduler recreates it on
  the next boot.
- The DUT-local test competes with the Pi-controlled test, producing misleading log
  artefacts and consuming reboot cycles from an unintended PowerShell session.

## Root cause

`setup_dut.ps1` registers `DUT-Reboot` as **enabled** at startup.  The protection
mechanism in `reboot.ps1` relies on the session file and a `reboot_stopped.flag`
sentinel: if neither is present, `reboot.ps1` starts a **new** 1000-cycle session.
After `power_cycle.py` finishes and the DUT is powered off, neither a running session
nor a sentinel exists, so the next boot triggers an unintended DUT-local test.

PWR011 Implication #1 states "reboot.ps1 is safe to leave registered in Task Scheduler
permanently: it exits immediately if no `status = running` session exists" — but the
code does the opposite (starts a new session).  Specification and implementation were
inconsistent.

## Fix

Applied in commit that introduces this bug file:

1. **`setup_dut.ps1`**: `Register-StartupTask` now calls `Disable-ScheduledTask`
   immediately after registration.  `DUT-Reboot` is registered as **disabled** by
   default.
2. **`reboot.ps1`**: A new `Set-RebootTaskEnabled` helper enables the task when a
   test starts (fresh `-Cycles N` or interactive no-args start) and disables it on
   completion or `-Stop`.  Task Scheduler therefore only fires while a DUT-local test
   is actively running.
3. **`reboot.ps1`**: The `reboot_stopped.flag` sentinel is retired; the scheduled-task
   enabled state is now the single authoritative signal.

## Verification

1. Register the task on a fresh DUT via `setup_dut.ps1 -RebootScript ...`.
2. Confirm `Get-ScheduledTask DUT-Reboot | Select State` shows `Disabled`.
3. Run `power_cycle.py --cycles 3 ...` from the Pi; confirm no `reboot_session.json`
   is created under the PowerShell directory.
4. Run `reboot.ps1 -Cycles 5`; confirm task becomes `Ready` (enabled) and
   `reboot_session.json` is created.
5. After 5 cycles complete, confirm task returns to `Disabled`.
