---
id: BUG0027
status: resolved
created: 2026-06-08
os:
  - Windows 11
related_requirements: [PWR012, PWR011]
related_bugs: []
---

# BUG0027 — `reboot.py` `boot_time_sec` does not measure the reboot round-trip

## Symptom

A 300-cycle `reboot.py` run against a Windows 11 DUT (`reboot_20260606T103112.report.html`,
2026-06-06 10:32–19:26, overall verdict PASS, 300/300 PASS) reports `boot_time_sec`
statistics that are implausibly tight and uniform for a real OS reboot round-trip:

| Stat | Value |
|------|-------|
| Min | 1.0 s |
| Median | 1.0 s |
| Mean | 1.0 s |
| p95 | 1.0 s |
| p99 | 1.1 s |
| Max | 1.1 s |
| Std-dev | 0.0 s |

Every one of the 300 cycles records `boot_time_sec` in the narrow band 1.03–1.08 s.
By contrast, the same DUT's `power_cycle.py` boot-time statistics from the
immediately preceding and following stages of the same chained run
(`power_cycle_report_20260605T162532.html`, `power_cycle_report_20260606T192643.html`)
show a real, varying boot duration: median 45.6 s, mean 45.4 s, max 45.8 s,
std-dev 2.0 s. A software reboot (shutdown + POST + boot) cannot plausibly complete
in ~1 second, and certainly not with zero variance across 300 cycles.

## Root cause

`run_one_cycle()` in `reboot.py` (lines ~221–243) structures each cycle as:

1. `time.sleep(config.REBOOT_SETTLE_SEC)` — settle after issuing the SSH reboot (5 s)
2. `checker.wait_until_dead(config.DEAD_TIMEOUT_SEC)` — poll until DUT goes offline
3. `time.sleep(args.off_time)` — **fixed** sleep, default `OFF_TIME_SEC` = 60 s
4. `checker.wait_until_alive(args.boot_timeout)` — poll until DUT is back online;
   **`boot_time_sec` is set to the elapsed time of this call** (`reboot.py:241-243`)

This four-phase shape is copied from `power_cycle.py`, where step 3 ("off-time")
is meaningful: the DUT is physically powered off by a relay and must stay off for a
settle period before `power_cycle.py` powers it back on and immediately calls
`wait_until_alive()` (`power_cycle.py:170`) — so its `boot_time_sec` genuinely
measures power-on → alive (median 45.6 s, std-dev 2.0 s, as seen above).

A software reboot has **no equivalent "off" phase to wait through deliberately**:
once the SSH reboot command is issued, the DUT autonomously proceeds through
shutdown → POST → boot on its own continuous timeline — `reboot.py` does not
control when it powers back on. Inserting a *fixed* 60-second sleep before
starting to poll for "alive" means that whenever the DUT's actual reboot
completes faster than `(time to detect offline) + 60 s` — which it evidently
always does on this hardware — `wait_until_alive()` finds the DUT already back
online on its very first poll and returns almost immediately: ~1.0–1.1 s is
simply the latency of one `ping` + TCP check, not a boot duration. The real
boot time is silently absorbed into the fixed `off_time` sleep and never
measured.

Net effect: `reboot.py`'s `boot_time_sec` does not measure "time for the DUT to
come back online after the reboot command" as PWR012 intends, and as PWR011
explicitly defines for `reboot.ps1` ("the reboot **round-trip** … = shutdown +
POST + boot", PWR011 §3). It instead reports a near-constant ~1 s
liveness-check latency, regardless of actual boot performance — useless for
trend analysis, regression detection, or for deriving timeout parameters
empirically (see PWR012 Implications #6).

## Fix

Implemented 2026-06-25, doing both compatible directions from the original
analysis:

1. **Removed the fixed pre-poll sleep.** `run_one_cycle()` no longer does
   `time.sleep(args.off_time)` between `wait_until_dead()` and
   `wait_until_alive()`. `wait_until_alive()` is now called immediately after
   `wait_until_dead()` returns, mirroring `power_cycle.py`'s immediate
   `wait_until_alive` call right after its power-on action.
2. **`--off` / `OFF_TIME_SEC` is now strictly an inter-cycle delay.** It runs
   *after* the cycle's verdict is recorded, at the end of `run_one_cycle()` —
   the same placement `power_cycle.py` uses at `power_cycle.py:240` — instead
   of before the boot-time poll. It no longer affects the measurement.
3. **`boot_time_sec` is now `t_online - t_reboot_cmd`** in practice: tracked
   via a `time.monotonic()` pair captured right when the SSH reboot command
   is issued and right when `wait_until_alive()` returns, rather than trusting
   that call's own internally-measured elapsed time. This matches PWR011's
   round-trip definition verbatim and stays correct regardless of internal
   polling structure or sleep placement, by construction.

Verified in-sandbox with a fake `LivenessChecker` that simulates a
`wait_until_dead` + `wait_until_alive` sequence with non-trivial delays at
each step: `boot_time_sec` reflects the sum of all elapsed phases (settle +
offline-detect + boot-poll), not just the final poll call's own elapsed time
as before. End-to-end `--dry-run --no-check` run still completes and renders
an HTML report via `report.py`.

## Verification

Still pending: re-run `reboot.py --cycles N --ssh-user … --host …` against
real Windows hardware and confirm:
- `boot_time_sec` values show realistic variance (tens of seconds), comparable
  in order of magnitude to `power_cycle.py`'s boot-time statistics on the same
  hardware (here: median ~45.6 s, std-dev ~2.0 s) — not a near-constant ~1 s.
- `boot_time_sec` for each cycle equals `t_online - t_reboot_cmd` (within
  rounding), confirming it represents the full round-trip per PWR011 §3.
