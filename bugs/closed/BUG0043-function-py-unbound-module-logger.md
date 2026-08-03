---
id: BUG0043
status: resolved
created: 2026-08-03
closed: 2026-08-03
os: [Windows 11]
related_requirements: [FWK037, DET002, LOG015]
related_bugs: [BUG0039]
---

# BUG0043 — function.py raised NameError on a real run: unbound module logger

## Symptom

A 10-cycle `power_cycle.py` run against a Windows DUT died at cycle 1,
immediately after the DUT came up:

```
2026-08-03 11:14:28  INFO  power_cycle: Cycle 1: DUT alive in 110.3 s
Traceback (most recent call last):
  File ".../power_cycle.py", line 862, in main
    rec = run_one_cycle(w, args, relay, checker, shutdown_coord,
  File ".../power_cycle.py", line 364, in run_one_cycle
    _collect_system_info_once(args, result)     # FWK037
  File ".../function.py", line 1094, in log_system_info
    log.info("System configuration (FWK037):")
NameError: name 'log' is not defined
```

The run aborted entirely — no cycles recorded, no `result.json`, no report.

## Root cause

`function.py` had no module-level logger. Every function that logged bound its
own:

```python
def some_helper(...):
    log = logging.getLogger("function")
```

six times across the file. `log_system_info()` and the `except` handler in
`collect_system_info()` — both added with the FWK037 inventory work — omitted
that line and referenced a `log` that did not exist in any enclosing scope.

Two properties made it survive to a real run:

1. **It is invisible to `py_compile` and to import.** A bare name resolved at
   call time is legal Python; the module compiles and imports cleanly.
2. **Dry runs never reached it.** `_collect_system_info_once()` sits behind
   `if args.ssh_user:` in `run_one_cycle()`. Every dry-run verification of this
   branch was performed with `--dry-run --no-check` and no `--ssh-user`, so the
   branch was never entered. The first execution of that line was on the DUT.

The `collect_system_info()` occurrence is the worse of the two: it is inside
`except Exception` — a handler whose whole purpose is to keep a failed
inventory from breaking the test. It would have converted any benign inventory
error into a `NameError` and killed the run anyway.

## Fix

Give `function.py` a module-level logger, as every other module in the
framework already has (`power_cycle.py`, `reboot.py`, `liveness.py`, …):

```python
log = logging.getLogger("function")
```

This fixes both sites at once and removes the recurrence mode: a function that
forgets to bind a local `log` now picks up the module one instead of raising.
The six existing per-function bindings are left in place — they rebind the same
logger object and are harmless.

## Verification

`src/python/logger_binding_unittest.py`:

- An AST scan over **every** module in `src/python/` for a `log` that is read
  but never bound — module scope, parameters, any local assignment, or a nested
  def. Reported clean after the fix; verified against a synthetic module that
  it does detect the exact pattern, so the check is not vacuous.
- Direct exercise of the two functions that raised: `log_system_info()` with a
  full inventory (including the `Fail` memory-verdict branch), with `{}`, with
  `None`, and with partial input; and `collect_system_info()`'s error path.

```bash
cd src/python && python3 -m unittest logger_binding_unittest -v
```

**Process note.** The gap that let this reach the DUT was verification by dry
run on a branch the dry run does not execute. `--dry-run` without `--ssh-user`
skips every SSH-dependent step — firmware collection, system inventory,
notification — so "dry run passed" says nothing about them. Coverage for those
paths has to come from unit tests with a faked SSH layer (as BUG0025's fix
now does) or from a real DUT.
