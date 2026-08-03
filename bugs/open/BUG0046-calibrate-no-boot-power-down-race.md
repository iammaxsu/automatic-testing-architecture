---
id: BUG0046
status: open
created: 2026-08-03
os: [Windows 11]
related_requirements: [PWR004, PWR016, FWK013]
related_bugs: [BUG0036]
---

# BUG0046 — isolated NO_BOOT during calibration; off-time is measured from network-offline, not confirmed power-off

## Symptom

Session `20260803T113859`, DUT 10.0.0.142 (AXE-7400GRW, Windows 11 IoT
Enterprise LTSC). Calibrate cycle 5 of 5 failed:

```
11:56:38  [CAL 5/5]
11:56:38  relay: ATX press  duration=0.5 s
11:56:39  liveness: Waiting for DUT 10.0.0.142 (max 360s) …
          … no ping response, 33 consecutive probes …
12:02:46  liveness: DUT did not come online within 360 s
12:02:46  power_cycle: Cycle 5: NO_BOOT (no_power_on)
```

The DUT never answered a single ping in 360 s. Calibrate cycles 1–4 had each
booted in 92.1–92.2 s, and all 10 counted cycles afterwards passed. The run's
verdict was `PASS 10/10` — calibration failures are not counted, by design.

## Analysis (root cause NOT confirmed)

`no_power_on` is the framework's own classification for "never responded to
ping at all", as distinct from `slow_boot` ("pinged but SSH was not ready in
time"). So the DUT did not merely boot slowly — it never brought up a NIC.

Two candidate mechanisms, which the logs cannot distinguish:

1. **The power-button press landed before the DUT had finished powering down.**
   The framework confirms the DUT is off by *network liveness* and then waits a
   fixed `OFF_TIME_SEC` (60 s). Network death is not the same as powered off:
   Windows can spend a long time after the NIC drops — writing the page file,
   installing updates on shutdown — before the PSU actually turns off. An ATX
   momentary press applied to a still-on machine is an OFF request, not an ON
   request, so the press would have been consumed doing nothing (or requesting
   another shutdown), leaving the DUT off for the whole 360 s window.
   Supporting evidence: shutdown-to-offline in this run varied 15.2 s–27.4 s
   (cycle 3), so the tail of the power-down sequence is not constant.

2. **A genuine intermittent power-on failure** — the press did not register at
   the relay or at the DUT's power-button header, or the DUT's PSU/board failed
   to start once. This is exactly the class of failure the test exists to
   detect, and would be a real DUT finding rather than a framework defect.

The framework has no way to observe actual DUT power state (no current sensing,
no BMC power query on this unit), so it cannot currently tell these apart.

## Related observation: warmup boot times are discarded

Calibration derives the counted-test timeout from calibrate cycles only:

| Phase | Boot time |
|---|---|
| Warmup 1/1 | **110.4 s** |
| Calibrate 1–4 | 92.1–92.2 s |
| Counted cycle 1 | 56.3 s |
| Counted cycles 2–10 | 92.0–92.2 s |

The timeout was set from the calibrate maximum: `92.2 × 1.5 = 138 s`. But the
slowest boot actually observed in the whole session was the warmup's 110.4 s,
which the calculation never saw. Against that, 138 s is a ×1.25 margin, not the
×1.5 the safety factor implies. A warmup boot is a real measurement on the same
hardware and there is no evident reason to exclude it.

Also worth noting: boot time is **bimodal**, not noisy — 56.3 s once, 92.0–92.2 s
thirteen times, 110.4 s once. Thirteen boots within 0.2 s of each other suggests
a fixed gate in the DUT's boot path (a service or DHCP timeout) rather than
natural variation, and the two outliers are the boots that followed a force-off.

## Next steps

1. Watch for recurrence. A single event does not separate hypothesis 1 from 2;
   a pattern (e.g. always the cycle after an unusually long shutdown) points at 1.
2. If it recurs, raise `OFF_TIME_SEC` well beyond the worst observed
   shutdown tail and see whether it stops — cheap and decisive for hypothesis 1.
3. Consider feeding warmup boot times into the calibration statistics, so the
   safety factor applies to every boot the run actually observed.
4. Consider logging a prominent warning when any calibrate cycle fails. Today
   the failure appears only in the calibrate table; the run summary says
   `PASS 10/10` with no indication that a power-on was missed minutes earlier.

## Verification

None yet — this bug is a recorded observation, not a fix. Reproduction requires
the DUT.
