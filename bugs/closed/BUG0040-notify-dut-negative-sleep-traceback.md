---
id: BUG0040
status: resolved
created: 2026-07-31
closed: 2026-07-31
os:
  - Windows 11
  - Ubuntu 24.04 LTS
related_requirements: [FWK032, PWR012]
related_bugs: []
---

# BUG0040 — `notify_dut` thread dies with a `ValueError` traceback mid-test

## Symptom

During a `reboot.py` run, a Python traceback is printed into the operator's
console between cycles:

```
2026-07-31 16:44:20  INFO  function: notify_dut: no Active session yet (attempt 6/6), retry in 10s
Exception in thread notify-dut:
Traceback (most recent call last):
  ...
  File ".../function.py", line 479, in _worker
    time.sleep(min(retry_interval, deadline - time.monotonic()))
ValueError: sleep length must be non-negative
```

The test itself continues correctly (the next cycle completes: `Cycle 2: DUT
back online in 76.2 s`), because the notification runs in a daemon thread. But
the traceback looks like a test failure to the operator and violates FWK032's
"fail silently" rule for the in-test notification.

Intermittent: it only appears when the *last* poll attempt overruns the deadline.

## Root cause

`notify_dut()`'s worker polls the DUT until `max_wait` expires:

```python
while time.monotonic() < deadline:
    rc, out = _ssh("query session")      # blocks up to ssh_timeout + 2
    ...
    time.sleep(min(retry_interval, deadline - time.monotonic()))
```

The loop condition is evaluated **before** the SSH probe, but the probe itself
blocks for up to `ssh_timeout + 2` seconds. On the final attempt the probe can
return *after* the deadline has already passed, so
`deadline - time.monotonic()` is **negative** and `time.sleep()` raises
`ValueError: sleep length must be non-negative`, killing the thread with a
traceback.

Both branches had the defect (Windows `query session` polling at the reported
line, and the Linux `wall` readiness polling a few lines above).

Pre-existing since 2026-06-04 (`33a518b`, "Fix notify_dut: poll query session
before msg.exe, run in background"); unrelated to the recent boot-timeout /
system-inventory work — `notify_dut` was not touched by any of those commits.

## Fix

- Replace the unguarded `time.sleep(...)` in both branches with a
  `_sleep_until_next_attempt()` helper that computes the remaining budget,
  returns `False` (ending the loop) when it is already spent, and otherwise
  sleeps a clamped, non-negative interval.
- Wrap the whole worker in `_safe_worker()`, which catches any escaping
  exception and logs it as a warning. FWK032 requires the notification to be
  best-effort; no future defect in this path should ever print a traceback into
  a test log again.

## Verification

Reproduced the negative-sleep condition in isolation (a probe that overruns the
remaining budget) and confirmed the original loop shape raises `ValueError`.
After the fix, with every probe forced to fail and to overrun:

- Windows branch: polls, then logs
  `notify_dut: no Active session within 1s — notification skipped` and the
  thread exits cleanly (no traceback).
- Linux branch: same, with the `wall` message.
- An injected internal exception is caught by `_safe_worker` and reported as a
  warning instead of a traceback.

## Note (not a defect)

In the reported run the **Windows** notification path was active (`no Active
session yet`), meaning `dut_os` resolved to `windows`. Polling six times and
then skipping is the intended FWK032 behaviour when no interactive desktop
session exists (`msg.exe` has nobody to deliver to). Configuring auto-logon for
the test user (`setup_dut.ps1 -TestUser`) gives an Active session so the
notification is delivered instead of skipped.
