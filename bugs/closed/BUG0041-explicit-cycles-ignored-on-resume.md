---
id: BUG0041
status: resolved
created: 2026-08-01
closed: 2026-08-01
os:
  - Ubuntu 24.04 LTS
  - Windows 11
related_requirements: [LOG023, FWK013, PWR012, LOG025]
related_bugs: []
---

# BUG0041 — an explicit `--cycles N` is silently ignored when a session resumes

## Symptom

The operator ran:

```
python ./reboot.py --cycles 300 --host 10.0.0.142 --ssh-user adlink; \
python ./power_cycle.py --cycles 300 --host 10.0.0.142 --ssh-user adlink
```

`reboot.py` correctly ran 300 cycles (session `20260731T164157`, 300/300 PASS).

`power_cycle.py` reported **100 / 100**, not 300 — and its report is headed with
an old session id and start time:

```
Started: 2026-07-27T08:48:23   Ended: 2026-08-01T09:55:46   Duration: 121h 7m 23s
Cycles ran: 100 / 100
```

The log shows why:

```
2026-08-01 02:39:59  power_cycle:   Session : 20260727T084820  (RESUMING)
2026-08-01 02:40:00  power_cycle: Resuming session 20260727T084820: 0 of 100 cycles already recorded
```

A `power_cycle` session started on 2026-07-27 with `m=100` had been interrupted
at `n=0` and was left `status: running`. Five days later the new
`--cycles 300` invocation found that stale session, resumed it, and ran the
**old** target of 100 — silently discarding the requested 300. The operator only
discovers it from the final report.

## Root cause

`function.resolve_session()` implements the LOG023/FWK013 resume rule: if a
session directory for this test+DUT has `status == "running"` and `n < m`, it is
resumed and the session's recorded `m` is used:

```python
if candidate is not None:
    ...
    m = meta["m"]            # session's target wins
    start_n = meta["n"] + 1
    resuming = True
```

`requested_m` (i.e. `--cycles`) is only consulted when creating a *new* session.
There was no check that the caller had explicitly asked for a different count,
and the existing target-identity guard (`SessionTargetMismatch`) only compares
host/port/ssh_user/type — not the cycle count. So resume silently overrode an
explicit operator instruction.

Resuming itself is correct and required (FWK013); the defect is doing it
*silently* when the operator's explicit request disagrees.

## Fix

- Add `SessionCycleMismatch`, raised by `resolve_session()` when the run
  explicitly requested a cycle count that differs from the resumable session's.
- `--cycles` now defaults to `None` (a sentinel) in `power_cycle.py` and
  `reboot.py`, so "operator asked for N" is distinguishable from "operator said
  nothing"; the config default is applied after that check.
- Both tests catch the new exception and refuse with actionable guidance:
  ```
  Refusing to resume session 20260727T084820: it was started with --cycles 100,
  but you asked for 300. Resuming would silently run 100 cycles, not 300.
    To start a NEW 300-cycle run:      add --new-session
    To finish the existing run:        re-run with --cycles 100
  ```

Behaviour preserved: omitting `--cycles`, or passing one that matches the
session, resumes exactly as before; `--new-session` starts fresh.

While fixing, a latent defect was also corrected: the edit initially split
`SessionTargetMismatch`'s `__init__` into the new class, which would have broken
the existing target-mismatch path. Caught by the regression test below.

## Verification

Reconstructed the reported stale session (`m=100`, `n=0`, `status: running`) and
exercised all paths:

1. no `--cycles` → resumes `m=100` (unchanged behaviour);
2. `--cycles 300` → **refused** with `session_m=100, requested_m=300`;
3. `--cycles 100` → resumes normally;
4. `--new-session --cycles 300` → fresh session, `m=300`, `start_n=1`;
5. mismatched host → `SessionTargetMismatch` still raised correctly.
