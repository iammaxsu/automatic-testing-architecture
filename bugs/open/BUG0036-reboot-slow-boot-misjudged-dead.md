---
id: BUG0036
status: in-progress
created: 2026-06-30
os:
  - Ubuntu 24.04 LTS
related_requirements: [PWR012, PWR013, FWK031]
related_bugs: [BUG0034]
---

# BUG0036 — `reboot.py` misjudges a slow-booting DUT as dead

## Symptom

A 10-cycle `reboot.py` run against a Linux DUT that was powered OFF at start
(`python ./reboot.py --cycle 10 --ssh-user adlink --host 10.0.0.157`,
`reboot_20260630T134819.log`) aborts during the init phase, before any cycle
runs:

```
13:48:25 init_dut: DUT offline — issuing power-on (ATX) ...
13:50:28 WARNING liveness: DUT did not come online within 120 s
13:50:28 WARNING init_dut: DUT still offline after power-on — forcing a full power cycle
13:53:36 WARNING liveness: DUT did not come online within 120 s
13:53:36 ERROR   init_dut: DUT did not come up after a forced power cycle — DUT may be dead
13:53:36 ERROR   reboot: Init failed (method=dead) — cannot start reboot test.
```

The DUT is **not** dead. The `power_cycle.py` run started immediately afterward
against the same DUT (`power_cycle_20260630T135337.log`) brought it up fine and
measured its actual boot time at **145.8–256.2 s** (median ~201 s) across the
calibrate + 10 counted cycles.

The same `reboot.py` invocation succeeded in the past against a Windows DUT,
because that DUT booted in ~98–101 s — comfortably under the 120 s default.

## Root cause

Two related shortcomings, both rooted in `reboot.py` using a single fixed
boot-wait ceiling (`--boot-timeout`, default `config.BOOT_TIMEOUT_SEC` = 120 s)
for a DUT whose real boot time it does not know in advance:

1. **Init declares "dead" too early.** `reboot.py` passes `boot_timeout`
   (120 s) to `function.init_dut()` for its power-on waits. This DUT needs
   ~200 s, so init's Step 2 (power-on press) times out at 120 s, escalates to
   Step 3 (force-off + power-on) — which *interrupts a healthy in-progress
   boot* — and that 120 s also expires, yielding the false `dead` verdict.

2. **No boot-time calibration.** `power_cycle.py` runs a calibrate phase
   (`CALIBRATE_CYCLES` cycles, `BOOT_CEILING_SEC` = 360 s ceiling) to *measure*
   the DUT's boot time and set `boot_timeout = max(observed) ×
   CALIBRATE_SAFETY_FACTOR` automatically. `reboot.py` had no equivalent, so
   it could only ever use the static 120 s value. Even if init had passed,
   every counted cycle's `wait_until_alive(120)` would then have hit `NO_BOOT`
   on this DUT.

The net effect is an OS-independent timing-configuration gap that happens to
bite slow-booting Linux DUTs while sparing fast-booting Windows ones.

## Fix

Bring `reboot.py` to parity with `power_cycle.py`:

1. Add `--boot-ceiling` (default `config.BOOT_CEILING_SEC`) and `--calibrate`
   (default `config.CALIBRATE_CYCLES`) options.
2. Pass `boot_ceiling` — not the short `boot_timeout` — to `init_dut()`, so a
   slow-but-healthy boot is not force-cycled and misjudged as dead.
3. Add a calibrate phase that, after init brings the DUT online, measures the
   reboot round-trip boot time over N cycles and sets `boot_timeout =
   max(observed) × CALIBRATE_SAFETY_FACTOR`, capped at the ceiling. Calibrate
   cycles are not counted in the main summary.
4. Persist the calibration result (per-cycle measured boot times and the
   resulting `boot_timeout`) into `result.json` under a `calibrate` key, and
   **render it in the HTML report** so the auto-measured boot time of each DUT
   is visible and comparable across DUTs.

## Verification

Re-run `python ./reboot.py --cycle 10 --ssh-user adlink --host 10.0.0.157`
against the same OFF Linux DUT (no `--boot-timeout` override). Expect:

- init powers the DUT on and waits up to the ceiling (no false `dead`);
- the calibrate phase logs the measured boot times and the derived
  `boot_timeout`;
- all 10 counted cycles run, and the report shows a "Calibration" section with
  the measured boot times and the boot timeout that was set.
