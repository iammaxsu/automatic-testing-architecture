---
id: BUG0067
status: open
created: 2026-08-17
os:
  - Windows
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR010, PWR009, PWR016, LOG023, FWK028]
related_bugs: [BUG0066, BUG0036]
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

Partial. The measurement is now *described* correctly; whether to make it
*finer* is a decision about comparability, not a defect fix:

- `LIVENESS_POLL_SEC` (5.0, unchanged) replaces the hard-coded interval in both
  polling helpers, is recorded in `result.json` as
  `config.liveness_poll_sec`, and the report renders the resolution beside the
  statistics it applies to.
- The shutdown statistics carry an explicit definition: time from the request
  until the DUT left the network, with the unmeasurable tail named.
- `wait_until_dead`'s docstring no longer lets a reader assume it measures
  power-down.

### Open decision

Lowering `LIVENESS_POLL_SEC` to 1.0 would cut the error five-fold at negligible
cost (one extra ping per second per waiting phase). It would also make new
figures incomparable with every run recorded so far, in the same way the NET009
threshold change did. Deferred to Max.

Making the *second* problem measurable needs the power-state input described in
BUG0066; no polling interval can fix it.

## Verification

Pending. Once decided:

1. `result.json` carries `config.liveness_poll_sec` and the report states it
   beside both statistics blocks.
2. With the interval at 1.0 s, the shutdown-time spread across a run should
   widen visibly compared with the 5.0 s run — if it does not, the DUT really is
   that consistent and the earlier figures happened to be honest.
