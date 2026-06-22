---
id: BUG0031
status: resolved
created: 2026-06-22
closed: 2026-06-22
os: [Windows 11 (zh-TW)]
related_requirements: [FWK028]
related_bugs: [BUG0030]
---

## Symptom

After BUG0030 (UTF-8 decode crash in `detect_dut_os()`) was fixed, a fresh
power-cycle run against the same Windows DUT (10.0.0.146, session
`20260622T103926`) still showed the exact same surface symptom: every
cycle's report carried `OS: linux (assumed)`, and every SSH shutdown
attempt failed with

```
WARNING shutdown: SSH shutdown command failed (exit 5): 此電腦上已停用 Sudo。
        若要啟用，請移至 [設定] 應用程式中的 Developer Settings page
WARNING shutdown: SSH shutdown failed — falling back to ATX press
```

The user confirmed manually that `ssh user@10.0.0.146` works perfectly
(logs into `DESKTOP-VVNSRMN`, a real Windows machine, no errors) — so SSH
credentials and connectivity were never the problem.

## Root cause

`power_cycle.py:main()` probes the DUT OS via `function.detect_dut_os()`
exactly once, **before the DUT is ever powered on** (the warmup phase's
first relay press happens afterwards). At that instant the DUT is off, so
the SSH probe correctly fails with exit 255 ("host offline?"), which
`detect_dut_os()` correctly reports as `"unknown"` — this is not a bug in
the probe itself. `main()` then falls back to `config.DUT_OS` ("linux")
with `dut_os_source = "assumed"`, fixes `shutdown_coord.ssh_cmd` to the
Linux command at construction time, and never re-evaluates it again: the
`ShutdownCoordinator` is built once and reused for every cycle (warmup,
calibrate, main loop).

So even with valid SSH credentials and a fully UTF-8-clean probe
response, the OS is permanently mis-assumed as Linux for the entire run
because the *only* probe attempt happens while the DUT is guaranteed to
be unreachable. This is a distinct failure mode from BUG0030 (which was a
decode crash on an actual SSH response) — confirmed by the log line
`DUT OS detection: SSH failed (exit 255, host offline?) — unknown`,
timestamped 3 seconds before the warmup cycle's first power-on.

## Fix

Added `_redetect_os_if_needed()` in `power_cycle.py`, called immediately
after every `run_one_cycle()` invocation (calibrate phase, warmup loop,
main loop). On the first cycle where the DUT is confirmed alive
(`rec["t_alive"]` set, verdict not `NO_BOOT`) and the OS is still
unconfirmed (`args.dut_os_source != "explicit"` and not yet re-detected),
it re-runs `function.detect_dut_os()` now that the DUT is actually up,
and if the result is no longer `"unknown"`:

- updates `args.dut_os` and `args.dut_os_source = "detected"`,
- recomputes `shutdown_coord.ssh_cmd` from the corrected OS so every
  subsequent shutdown uses the right command,
- updates `result["config"]["dut_os"]` / `["dut_os_source"]` so the
  canonical `result.json` (and the report rendered from it, per FWK028)
  reflect the correction for the whole run, not just cycles after
  re-detection.

`args.dut_os_source` is now also stored on `args` (previously a
`main()`-local variable only) so the helper can read and update it from
the three call sites. The calibrate phase passes a shallow-copied
`cal_args` to `run_one_cycle()` (so its temporary `boot_timeout`/`on_time`
overrides don't leak into the real run) — `_redetect_os_if_needed()` is
deliberately called with the real `args`, not `cal_args`, so the
correction propagates to the warmup and main loops instead of being
silently discarded with the copy.

## Verification

- `python3 -m py_compile power_cycle.py shutdown.py function.py` passes.
- Logic re-checked against the failing session: with the fix, the
  warmup cycle's `run_one_cycle()` call sets `rec["t_alive"]` once the
  DUT responds to a TCP/ping check; the SSH probe immediately after that
  now succeeds (DUT is on and reachable), returns `"windows"`, and
  `shutdown_coord.ssh_cmd` switches to `shutdown /s /t 5` before that
  same cycle's shutdown step runs. Independent confirmation on hardware
  pending → status `resolved`.
