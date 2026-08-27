---
id: BUG0067
status: resolved
created: 2026-08-17
os:
  - Windows
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR010, PWR009, PWR016, LOG023, FWK028]
related_bugs: [BUG0066, BUG0068, BUG0036]
---

# BUG0067 — boot and shutdown times are quantised, and "offline" is not "off"

## Symptom

A 100-cycle run reported shutdown-time statistics of min 15.6 s, median 15.7 s,
p95 16.7 s, max 16.8 s, σ 0.5 s, and boot times clustered on 90.1 / 90.2 s. The
consistency looks like a well-behaved DUT. It is mostly an artefact of how the
figures are taken.

## Root cause

Two separate problems, both invisible in the artefacts:

**1. The measurement is quantised to the poll interval.** Phase 1 and phase 3
both end when a probe notices the state changed, and the probe ran every 5.0 s
(`liveness.wait_until_alive` / `wait_until_dead`). Every `boot_time_sec` and
`shutdown_time_sec` therefore carries up to 5 s of positive error, and any real
variation smaller than 5 s is erased. A σ of 0.5 s across 61 shutdowns is not
evidence that the DUT is consistent to half a second; it is evidence that the
ruler has 5 s graduations.

**2. "Offline" is the network's death, not the DUT's power-down.** The OS drops
its network stack early in a shutdown and the machine keeps working afterwards —
flushing, stopping services, cutting power. That tail is not observable from the
control node at all (BUG0066), so `shutdown_time_sec` systematically
under-reports the real power-down time by an unknown amount that differs between
OSes and between DUTs. `OFF_TIME_SEC` (fixed 60 s) exists to absorb it.

A third, smaller point: the Windows command is `shutdown /s /t 5`, so 5 s of
every Windows measurement is a countdown the framework itself asked for, while
Linux uses `shutdown -h now` and has no such offset. Windows and Linux shutdown
figures are not directly comparable.

None of this was stated anywhere in the artefacts, so a reader had no way to
know the resolution of the numbers they were reading — the same class of gap as
BUG0063, where the rule that produced a verdict was not recorded with it.

## Fix

**1. The probe, not just the interval.** Lowering the interval alone would have
achieved little: `ping -c 2` spaces its echoes a second apart and waits `-W 2`
per unanswered one, so the standard probe costs about 1 s against a live host
and about 4 s against a dead one. With a 1 s interval the loop would still have
resolved to roughly 5 s. The polling loops now use a single echo with a 1 s
deadline (`PING_COUNT_POLL`, `PING_TIMEOUT_POLL_SEC`); the standard probe is
unchanged everywhere else.

One dropped packet would then look like death and end the phase early, so
`wait_until_dead` confirms with a second probe before believing it. A lone
missed echo costs one extra probe; a real shutdown is confirmed immediately.

`wait_until_alive` also stopped pinging twice per iteration — it used to call
`is_alive()` (ping + TCP) and then `ping()` again just to log which half had
failed, doubling the loop's own contribution to every recorded boot time.

**2. The interval.** `LIVENESS_POLL_SEC` is 1.0 (was 5.0). Decided by Max:
accuracy over comparability with earlier runs. Figures taken at 1.0 s are not
comparable with runs recorded at 5.0 s, and the recorded `liveness_poll_sec` is
what tells the two apart.

**3. The description.** `LIVENESS_POLL_SEC` is recorded in `result.json` as
`config.liveness_poll_sec`; the report renders the resolution beside the
statistics it applies to; the shutdown statistics carry an explicit definition
of what they measure, with the unmeasurable tail named; and `wait_until_dead`'s
docstring no longer lets a reader assume power-down.

The Windows-only `/t 5` countdown that also sat inside these figures is BUG0068.

Making the *second* problem measurable needs the power-state input described in
BUG0066; no polling interval can fix it.

## Verification

Pending. Once decided:

1. `result.json` carries `config.liveness_poll_sec` and the report states it
   beside both statistics blocks.
2. On the bench: with the interval at 1.0 s and the single-echo probe, the
   shutdown-time spread across a run should widen visibly compared with the
   5.0 s run — if it does not, the DUT really is that consistent and the earlier
   figures happened to be honest.
3. `shutdown_method` should stay `ssh` on passing cycles; a shift to `atx` would
   mean the cheaper probe or the immediate shutdown command (BUG0068) changed
   the timing enough to lose the transport race.
