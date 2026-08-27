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

Added `_redetect_os_if_needed()` in `power_cycle.py`, called **from inside
`run_one_cycle()`** immediately after the DUT is confirmed alive
(`log.info("Cycle %d: DUT alive ...")`) and before the shutdown step. At
that point SSH actually answers, so re-running `function.detect_dut_os()`
succeeds. If the result is no longer `"unknown"`:

- updates `args.dut_os` and `args.dut_os_source = "detected"`,
- recomputes `shutdown_coord.ssh_cmd` from the corrected OS so the same
  cycle's shutdown (and every later one) uses the right command,
- updates `result["config"]["dut_os"]` / `["dut_os_source"]` so the
  canonical `result.json` (and the report rendered from it, per FWK028)
  reflect the correction.

The helper only acts when `args.dut_os_source == "assumed"` — an
unverified guess. A successful startup probe (`"detected"`) or an
explicit `--dut-os` (`"explicit"`) is already trustworthy and is left
alone; re-probing those would add a pointless SSH round-trip.
`args.dut_os_source` is stored on `args` (previously a `main()`-local
variable only) so the helper can read and update it.

`shutdown_coord` and `result` are shared objects passed into
`run_one_cycle()`, so updates to them propagate to the whole run even
when the cycle is driven by the calibrate phase's shallow-copied
`cal_args`. With the default `--warmup 1`, the first warmup cycle (which
uses the real `args`) confirms the OS before calibrate even starts.

### First-attempt regression caught in review

The first version of this fix called `_redetect_os_if_needed()` *after*
each `run_one_cycle()` returned. By then the cycle had already shut the
DUT down and waited `off_time`, so the DUT was **off** and the probe
failed `exit 255` every time — the redetection never actually corrected
anything (the one passing run only worked because its startup probe
happened to catch the DUT still powered on), and it logged a spurious
`DUT OS detection: SSH failed (exit 255, host offline?)` warning on every
cycle. Moving the call inside `run_one_cycle()`, against the live DUT,
fixes both the ineffectiveness and the log noise.

## Verification

- `python3 -m py_compile power_cycle.py shutdown.py function.py report.py`
  passes.
- Unit-level simulation: with `dut_os_source="assumed"` and a stub probe
  returning `"windows"`, one call updates `args.dut_os`,
  `args.dut_os_source`, `shutdown_coord.ssh_cmd` (→ `shutdown /s /t 5`),
  and `result["config"]`; a second call is a no-op (probes exactly once);
  and a `"detected"`/`"explicit"` source never probes at all.
- Session `20260622T115250` (10/10 PASS, all cycles `shutdown_method:
  ssh`) confirms the OS path now reaches a graceful SSH shutdown on the
  zh-TW Windows DUT. Independent confirmation that the *re-detection*
  path (DUT off at startup) recovers mid-run is pending hardware →
  status `resolved`.
