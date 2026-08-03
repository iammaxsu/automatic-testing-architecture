---
id: BUG0045
status: resolved
created: 2026-08-03
closed: 2026-08-03
os: [Windows 11]
related_requirements: [FWK028, PWR016, LOG015]
related_bugs: [BUG0044]
---

# BUG0045 — report presented a boot timeout as a measured boot time

## Symptom

A calibrate cycle that failed with `NO_BOOT` was rendered in the HTML report's
calibration table as though 360 s of boot time had been measured:

| Calibrate cycle | Verdict | Boot time |
|---|---|---|
| 5 | NO_BOOT | **360.0s** |

The log, for the same cycle, printed `boot: — s`. The rendered view and the
canonical log therefore contradicted each other, and the report's number was
the ceiling the framework gave up waiting at — not a measurement of anything.

## Root cause

`report.py`'s calibrate-table helper formatted whatever was in
`boot_time_sec`, checking only for `None`:

```python
def _cal_boot_str(c):
    bt = c.get("boot_time_sec")
    return f"{bt:.1f}s" if bt is not None else "—"
```

`run_one_cycle()` records `boot_time_sec` as the elapsed wait even when the wait
ended in failure, so a `NO_BOOT` carries the ceiling as its "boot time". The
summary cards were already correct — they filter on `verdict == "PASS"` — so
only the per-cycle table was wrong.

`power_cycle.py`'s own log line had a related weakness: it suppressed the number
using `boot_t < args.boot_ceiling` rather than the verdict, so a failure that
gave up fractionally under the ceiling would have printed a number too.

## Fix

Both sites now key off the verdict, which is what actually decides whether a
boot time exists:

```python
if bt is None or c.get("verdict") != "PASS":
    return "—"
```

This is FWK028's rule applied to a small case: the rendered view must not assert
something the canonical record does not say.

## Verification

`src/python/cycle_banner_unittest.py` — `PASS`/`NO_BOOT`-with-a-number/
`NO_BOOT`-with-`None` render as `92.2s` / `—` / `—`; the log line for a failed
calibrate cycle contains `boot: — s`; and a guard asserting `report.py` still
tests the verdict, so the helper cannot be simplified back to a bare `None`
check.
