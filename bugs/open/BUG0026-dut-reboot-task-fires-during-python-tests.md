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

An initial attempt registered the task **disabled** and had `reboot.ps1` enable it
on start / disable it on completion (`Set-RebootTaskEnabled`). That was abandoned:
`Enable/Disable-ScheduledTask` on a SYSTEM/Highest task requires elevation, but
`reboot.ps1` is run **non-elevated** (over SSH, or a normal local shell), so the
enable silently failed and the test never resumed.

Final fix — distinguish the human caller from the scheduler by **argument**, not by
task state. The task stays enabled permanently; the gate is in-script:

1. **`reboot.ps1`**: new `-Resume` entry point. It resumes a running session and
   otherwise **exits silently — it never starts a new session**. Task Scheduler is
   the only caller that passes `-Resume`.
2. **`reboot.ps1`**: session resolution aligned with LOG023 — a running session
   always wins (resume, stored `m` kept); a new session is created only when none is
   running. New `-NewSession` flag forces a fresh session.
3. **`reboot.ps1`**: removed the rogue "start a default 1000-cycle session when
   nothing is running" branch from the scheduler path; removed the
   `Set-RebootTaskEnabled` helper and the `reboot_stopped.flag` sentinel.
4. **`setup_dut.ps1`**: `DUT-Reboot` is registered **enabled** with the action
   `reboot.ps1 -Resume`.

This keeps `reboot.ps1` runnable non-elevated, resumes correctly, and never disturbs
a normal boot or a Pi-controlled test.

## Verification

1. Register the task on a fresh DUT via `setup_dut.ps1 -RebootScript ...`; confirm
   `(Get-ScheduledTask DUT-Reboot).Actions.Arguments` contains `-Resume`.
2. Run `power_cycle.py --cycles 3 ...` from the Pi (DUT reboots, task fires
   `reboot.ps1 -Resume` each boot); confirm **no** `reboot_session.json` is created
   under the PowerShell directory and no DUT-local reboot loop starts.
3. Run `reboot.ps1 -Cycles 5` (non-elevated, over SSH); confirm a session is created
   and the DUT auto-reboots 5 times to completion without re-running the command.
4. Interrupt mid-test, then run `reboot.ps1` again; confirm it resumes the same
   `session_id` rather than starting over.
