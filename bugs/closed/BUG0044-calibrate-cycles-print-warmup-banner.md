---
id: BUG0044
status: resolved
created: 2026-08-03
closed: 2026-08-03
os: [Windows 11]
related_requirements: [PWR016, LOG013]
related_bugs: [BUG0045]
---

# BUG0044 — calibrate cycles printed a second, contradictory WARMUP banner

## Symptom

Every calibrate cycle printed two banners, with counters that disagreed:

```
[WARMUP 1/1] ──────    ← the actual warmup cycle
...
=== Calibrate: 5 cycle(s) — measuring boot time (ceiling 360s) ===
[CAL 1/5] ──────
[WARMUP 1/5] ──────    ← same cycle, second banner
```

The log reads as if warmup and calibration were interleaved, and as if warmup
ran twice with different totals (`1/1` then `1/5`). An operator cannot tell
from the log how many cycles of each phase actually ran.

## Root cause

`run_one_cycle()` took an `is_warmup: bool`, and `_run_calibrate_phase()` had to
pass `is_warmup=True` because that flag was the only way to say "this is not a
counted cycle". But the flag's *only* actual use was choosing the banner:

```python
if is_warmup:
    log.info("[WARMUP %d/%d] ...", n, _total)
else:
    log.info("─── Cycle %d / %d ...", n, _total)
```

So the calibrate loop printed `[CAL c/5]` itself and then `run_one_cycle`
printed `[WARMUP c/5]` for the same cycle. One name, two meanings.

`reboot.py` is unaffected — its `run_one_cycle()` has a different signature and
prints no phase banner of its own.

## Fix

Replace the overloaded bool with the thing it was standing in for:

```python
phase: str = "main",   # "main" | "warmup" | "calibrate"
```

`run_one_cycle()` now prints exactly one banner, chosen by phase, and
`_run_calibrate_phase()` no longer prints its own.

## Verification

`src/python/cycle_banner_unittest.py` — one banner per cycle for each phase,
plus an end-to-end run of the real calibrate loop asserting two cycles produce
two `[CAL n/2]` banners and zero lines containing `WARMUP`.

```bash
cd src/python && python3 -m unittest cycle_banner_unittest -v
```
