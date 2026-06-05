---
id: BUG0025
status: open
created: 2026-06-05
os:
  - Windows 11
related_requirements: [PWR009, PWR011, PWR012]
related_bugs: []
---

# BUG0025 — power_cycle.py msg.exe notification not shown on DUT during test

## Symptom

During a `power_cycle.py` run against a Windows DUT (10.0.0.137), the
intended "test in progress — do not use" pop-up does **not** appear on the
DUT desktop, even though:

- The DUT has an Active interactive console session (`query session` shows
  `console  nimitz4  1  Active`).
- A manual `ssh -o BatchMode=yes nimitz4@10.0.0.137 "msg * hello test"` from
  the Pi **does** raise the pop-up.
- The same `notify_dut()` code path was added to both `power_cycle.py` and
  `reboot.py` (function.py, post-boot, background thread polling
  `query session` for an Active session before sending `msg *`).

The only desktop message the operator sees is Windows' own
"you're about to be signed out" banner, which is triggered by the
`shutdown /s /t N` countdown — not by our notification. That banner appears
immediately before shutdown, so it is useless as an "in progress" reminder.

## Root cause

Not yet confirmed. Candidate hypotheses to investigate:

1. **Timing / lifecycle.** In `power_cycle.py`, `notify_dut()` is fired from a
   background daemon thread right after boot is confirmed. The main thread then
   enters the ON_TIME soak. If the thread's first `query session` + `msg *`
   round-trip lands in a window where the session is not yet "Active" by msg's
   definition, the loop retries every 10 s — but the pop-up may be dismissed or
   superseded before the operator notices.
2. **Daemon thread killed early.** The notification runs in a `daemon=True`
   thread. If the cycle proceeds to shutdown before the thread completes its
   `query session` → `msg *` sequence, the daemon thread is terminated with the
   process and the message is never sent. power_cycle does NOT join the thread
   (unlike reboot.py which now joins with a 30 s timeout).
3. **msg delivery target.** `msg *` delivered over an SSH (non-interactive,
   possibly Session 0 / service) context may not always route to the console
   session depending on privileges, even though a manual invocation works.
4. **Logging blind spot.** Until the INFO-level logging change, `notify_dut`
   reported nothing in the console, so it is not yet known whether the code
   reaches the `msg sent` branch, the `no Active session` retry branch, or
   exits silently.

## Fix

Not yet applied. Plan:

1. Re-run with the INFO-level `notify_dut` logging (already committed) and
   capture which branch executes: `msg sent`, `no Active session yet`, or
   `notification skipped`.
2. If the daemon thread is being killed before sending, give power_cycle the
   same treatment as reboot.py: capture the returned thread and `join()` it (or
   send the notification synchronously before entering the soak, since ON_TIME
   provides ample buffer).
3. Confirm whether `msg *` over SSH reliably reaches the console session, or
   whether an explicit session id (`msg console`) is needed.

## Verification

Run `power_cycle.py --cycles 2 --ssh-user nimitz4 --host 10.0.0.137` and
confirm:
- Console log shows `notify_dut: msg sent on attempt N` for each cycle.
- The pop-up actually appears on the DUT desktop after each boot and remains
  visible during the ON_TIME soak (not just at shutdown).
