---
id: BUG0028
status: resolved
created: 2026-08-04
closed: 2026-08-04
os: [Ubuntu 24.04 LTS]
related_requirements: [PWR010, PWR014]
related_bugs: []
---

# BUG0028 — power.robot powered on with no OFF_TIME and never re-issued the command

## Symptom

First real-hardware run of `src/robot/ipmi/power.robot` against the ADLINK BMC
(10.0.0.124) failed both tests:

```
chassis power did not reach 'on' within 120.0s (last='off')
```

`chassis power off` worked (the board went off), but the board never came back
on. The second test then failed as a consequence: `chassis power cycle` was
issued against an already-off system, which is a no-op, so it too timed out
waiting for `on`. The run left the DUT powered off.

## Root cause

Two defects in the suite, both absent from the equivalent Python runner:

1. **No OFF_TIME wait.** The test issued `chassis power on` immediately after
   confirming the board was off. PWR010 defines a four-phase cycle whose
   phase 4 is a *fixed* `OFF_TIME_SEC` wait (`config.py` default 60 s) before
   the next power-on, precisely because boards need real off-time; a power-on
   arriving during the off transition is accepted (rc=0) but has no effect.
2. **Single-shot power-on.** `Set Chassis Power on` was issued once and then
   `Wait For Chassis Power on` polled passively. If that one command was
   swallowed, the wait could only time out — no retry, no diagnostic.

A third, latent issue was found while fixing: `Wait For Chassis Power on`
immediately after `chassis power cycle` could return 0.0 s because the board
had not yet dipped off, so the cycle test was not really verifying recovery.

## Fix

- `bmc.resource`: add `${POWER_OFF_TIME}` (60 s, matching PWR010 /
  `config.py OFF_TIME_SEC`) and `${POWER_TRANSITION_TIMEOUT}`; raise
  `${POWER_ON_TIMEOUT}` to 180 s.
- `power.robot`: wait `${POWER_OFF_TIME}` after the board is off, before
  powering on; normalise the DUT to powered-on before the cycle test (a cycle
  on an off system is a no-op); after a cycle, tolerate-wait for the off dip
  before confirming recovery; add a suite teardown that leaves the DUT powered
  on when any test failed.
- `BMCLibrary.py` v00.00.06: new `ensure_chassis_power_on`, which re-issues
  `chassis power on` every `reissue_after` seconds until the state is on, logs
  each retry, and reports the attempt count on timeout.

## Verification

Mock-level: a mock BMC that ignores the first `power on` command now recovers
via the re-issue path, and the suite passes; the read-only suite is unchanged.

Pending independent verification on the real DUT: re-run
`src/robot/ipmi/power.robot` with `-v POWER_TESTS_ENABLED:True`. If the board
still fails to power on after the fixed off-time and repeated commands, the
fault is in the DUT/firmware rather than the test, and this bug should be
reopened with that evidence.
