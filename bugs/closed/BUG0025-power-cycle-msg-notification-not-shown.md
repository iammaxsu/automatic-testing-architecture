---
id: BUG0025
status: resolved
created: 2026-06-05
closed: 2026-08-03
os:
  - Windows 11
related_requirements: [PWR009, PWR011, PWR012, FWK032]
related_bugs: [BUG0040]
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

The `query session` precondition. `notify_dut()` would not attempt delivery
at all unless that probe both exited 0 **and** printed `Active`:

```python
rc, out = _ssh("query session")
if rc == 0 and "Active" in out:
    _ssh(f"msg * {message}")
```

Enumerating terminal sessions is an administrative operation. Run over SSH as
an ordinary test user it commonly fails outright — `Error 5 getting session
names` — so `rc != 0`, the gate never opened, and `msg.exe` was never invoked.
The loop then retried for 60 s and logged "no Active session within 60s".

The gate was therefore **stricter than the thing it guarded**: `msg *` needs
no such privilege. This is exactly why the manual reproduction worked — it
sent `msg *` directly and skipped the check. The evidence that looked like a
contradiction ("the session IS Active, and msg DOES work") was in fact the
diagnosis.

Two defects compounded it:

1. **The success log lied.** `msg`'s return code was discarded and
   `"msg sent on attempt %d"` was logged unconditionally, so on the paths
   where delivery *was* attempted there was no way to tell whether it
   succeeded. This is the "logging blind spot" originally listed as
   hypothesis 4.
2. **The message was unquoted.** `msg * {message}` passes prose containing
   `cycle 1/10.` to a parser that treats leading-`/` tokens as switches.

Hypothesis 2 from the original report (daemon thread killed before delivery)
was **not** the cause: the notification is sent post-boot and the ON_TIME soak
keeps the process alive well past it. `power_cycle.py` still deliberately does
not join the thread, and does not need to.

## Fix

Ask `msg.exe` and believe its exit code, instead of predicting the answer from
a privileged probe:

1. **Gate removed.** Delivery is attempted immediately, `msg * "<message>"`
   first.
2. **Console fallback.** If the wildcard fails, `msg console "<message>"` —
   `msg *` iterates every session including disconnected and service ones and
   can fail as a whole, where addressing the interactive desktop by name is the
   narrower request.
3. **Return codes checked and reported.** Success is logged only on `rc == 0`,
   and each failed attempt logs both commands' rc and first line of stderr.
4. **Message quoted** via the new `function.win_msg_cmd()`, which also folds
   embedded double quotes so a message can never break the command line.
   No `/time` is passed: with no time limit the popup stays until acknowledged,
   which is what an "in progress" reminder needs.
5. **Diagnostic snapshot on give-up.** After the retry budget is spent, one
   `query session` runs and its output goes into the warning — so a failure
   now says *why*. This is also where a missing `msg.exe` surfaces: Windows
   Home editions do not ship it.

`_ssh()` now returns stderr alongside rc and stdout so the above can be
reported. FWK032 is preserved throughout: the notification remains best-effort
and cannot affect the test (see BUG0040 for the traceback that motivated the
surrounding `_safe_worker` guard).

## Verification

`src/python/notify_dut_unittest.py` — 12 cases driving the Windows branch with
a fake `ssh(1)`, including the direct regression guard that the first remote
command is `msg`, and that `query session` never runs before it:

```bash
cd src/python && python3 -m unittest notify_dut_unittest -v
```

Covers: no gating, quoting, no `/time`, stop-after-success, console fallback,
diagnostic-only `query session` after give-up, exceptions never escaping, and
the Linux `wall` path being unaffected.

**Pending on real hardware** — needs one run against the Windows DUT:

```bash
python3 power_cycle.py --cycles 2 --ssh-user <user> --host <dut-ip>
```

Confirm the console log shows `notify_dut: msg delivered ...` for each cycle,
and that the pop-up appears on the DUT desktop after each boot and stays
visible through the ON_TIME soak rather than only at shutdown. Status stays
`resolved` until that run is done.
