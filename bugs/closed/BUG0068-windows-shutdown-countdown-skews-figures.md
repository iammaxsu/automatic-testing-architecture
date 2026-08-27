---
id: BUG0068
status: resolved
created: 2026-08-27
os:
  - Windows
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR009, PWR010, FWK036, FWK028]
related_bugs: [BUG0067, BUG0066]
---

# BUG0068 — a Windows-only countdown made shutdown figures incomparable

## Symptom

Windows DUTs shut down via `shutdown /s /t 5`; Linux DUTs via
`sudo shutdown -h now`. Five seconds of every Windows `shutdown_time_sec` was
therefore a delay the framework itself had asked for, and no equivalent existed
on Linux. A reference Windows run reported a 15.7 s median; a third of that
figure was the countdown.

Nothing in the report said so, so the two OSes' shutdown statistics looked
directly comparable and were not.

## Root cause

`config._OS_SHUTDOWN_CMD` was written per-OS without the two entries being
compared for what they measure. `_OS_REBOOT_CMD` had already settled on
`shutdown /r /t 0` for Windows, so the inconsistency was internal to this repo,
not a Windows constraint: `/t 0` is available and is what the reboot test
already uses.

Why the countdown existed at all is a fair question, and the answer is the
second half of this bug: an immediate shutdown races its own transport. Windows
can tear the SSH session down before the client collects an exit status, so
`_try_ssh` sees a non-zero return or a dropped connection and reports failure —
even though the command worked. The coordinator would then fall through to the
relay, record `shutdown_method: "atx"`, and attribute to the relay a shutdown
SSH had performed. A few seconds of countdown made that race unlikely, at the
cost of biasing every measurement.

## Fix

1. `_OS_SHUTDOWN_CMD["windows"]` is `shutdown /s /t 0`, matching the reboot
   command's style. Both OSes now shut down immediately, so `shutdown_time_sec`
   measures the DUT and not a framework-injected delay.
2. Neither command gains `/f` or `--force`. Forcing applications closed would
   suppress exactly the hangs `HANG_SHUTDOWN` exists to catch.
3. `ShutdownCoordinator._confirm_by_death()` closes the race: when the SSH
   command reports an error, the DUT is given a bounded window
   (`SSH_CONFIRM_DEATH_SEC`, 20 s, capped by `DEAD_TIMEOUT_SEC`) to go offline.
   If it does, the command evidently took effect and the cycle is recorded as
   `ssh`. If it does not — bad credentials, missing sudo rights — the coordinator
   falls through to the relay exactly as before, having spent that window and
   nothing else.

Reports from before this change are not comparable with later ones for Windows
shutdown time; the ~5 s offset is the whole difference.

## Verification

`src/python/shutdown_unittest.py` — 9 tests: both OS commands are immediate,
neither forces applications closed, the Windows shutdown and reboot commands
agree in style; a dropped session or a timeout with a DUT that does go offline
is recorded as `ssh`; a genuine failure still falls through to the relay; the
confirm window is bounded by both limits; a coordinator with no checker cannot
confirm and does not guess; and a clean exit does not spend the window.

Pending on the bench: a Windows run should now show a shutdown-time median
roughly 5 s lower than the reference run, with `shutdown_method` still `ssh` on
every passing cycle. A run where the method flips to `atx` means the race is
being lost more often than the confirm window covers.
