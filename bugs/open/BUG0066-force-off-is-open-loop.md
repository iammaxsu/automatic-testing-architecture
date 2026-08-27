---
id: BUG0066
status: in-progress
created: 2026-08-17
os:
  - Windows
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR001, PWR003, PWR009, PWR004, LOG023, FWK028]
related_bugs: [BUG0064, BUG0046, BUG0036]
---

# BUG0066 — the force-off is commanded, never confirmed

## Symptom

A `power_cycle.py` run against a Windows DUT recorded 27 consecutive `NO_BOOT`
cycles, each taking exactly 210 s. The regular timing was read as evidence that
the force-off between them was working. **It is not evidence of anything about
the DUT.** The operator watched the DUT's screen through cycles 97–100 and it
stayed on the Windows Automatic Repair screen the whole time — it was never
powered off.

## Root cause

`RelayController` drives one GPIO pin and reads nothing back
(`src/python/relay.py`):

```python
def atx_force_off(self, duration: float = 5.0) -> None:
    self._close()
    time.sleep(duration)
    self._open()
```

The whole power path is open-loop. The framework's only sensor is the network
(ping + SSH), and the network cannot see power state: a DUT that is off and a
DUT that is on but stopped at a screen with no network are the same silence.

So a `NO_BOOT` cycle takes 210 s — boot timeout, force-off hold, off-time,
power-on — **whether or not any of those actions reached the DUT**. The 210 s
regularity describes the script's own schedule. Reading it as DUT behaviour was
the mistake; the log had no such information in it to begin with.

What the run *does* show is narrower: cycles 2, 12, 34, 40, 44 and 65 passed
immediately after a `NO_BOOT`, and a pass requires powering on from off. That
establishes the relay path worked at those six moments. It says nothing about
cycles 74–100, and the operator's direct observation says it did not work there.

This also makes an artefact-integrity problem, not only a diagnostic one: the
records imply an outcome ("force-off issued before the next cycle") that was
never observed, which is exactly the kind of unearned claim FWK028 exists to
prevent.

## Fix

**Partial — the verification gap needs hardware and is not closed.**

1. The report no longer lets the timing imply DUT behaviour. When three or more
   `no_power_on` cycles run consecutively it states that the force-off is
   commanded and not confirmed, that a force-off the DUT ignored is
   indistinguishable from one that worked, and that watching the display or
   power LED is currently the only way to tell.
2. `_force_off()` returns the hold it commanded and the cycle record carries it
   as `force_off_sec` — what was asked for, explicitly not what happened.
3. Escalation: a force-off that follows a cycle which already failed to boot is
   held for `ATX_FORCE_OFF_ESCALATE_SEC` (`--force-off-escalate`, 0 disables)
   instead of the normal hold. This costs a few seconds only when something is
   already wrong.

**The hold time itself was wrong.** The bench test this bug asked for came back:
a 10 s press by hand powers the DUT off at the Windows Recovery screen, where 27
consecutive 5 s relay force-offs had done nothing. `ATX_LONG_PRESS_SEC` is now
10.0 — the value observed to work rather than the 4 s the ATX spec permits — and
the escalation is 15.0. That leaves one question the next run answers: a DUT
still stuck after a 15 s hold implicates the relay path (wiring, contact, GPIO
drive, effective hold at the pin) rather than the duration.

This does not close the bug. A working hold time is not a verified force-off;
the framework still cannot see the DUT's power state, and the next stuck run
would again be indistinguishable from a working one in the log.

### What would actually close it

A power-state input, so the control loop stops being open:

| Option | Notes |
|---|---|
| BMC power status (`ipmiutil`/IPMI chassis status) | Already installed by both setup scripts (PWR015); needs a reachable BMC — this DUT reported `BMC: N/A` |
| A GPIO input on the Pi sensing the DUT's power LED or PWROK | Cheap, works on any DUT, needs one wire |
| A current sensor on the DUT's mains lead | Most general, most intrusive |

With any of them, `_force_off()` can verify, retry with a longer hold, and
record a real outcome — and a `NO_BOOT` can finally be split into "did not power
on" and "powered on, no network", which is the distinction BUG0064 needed and
could not make.

## Verification

Pending on the bench. The immediate question is why a 5 s hold did not force the
DUT off at the Automatic Repair screen, which is answerable by hand:

1. Bring the DUT to the Automatic Repair screen.
2. Press the **physical** power button for 10 s.
   - Powers off → the platform's override works; the relay path is the suspect
     (wiring, contact, GPIO drive, effective hold at the pin).
   - Does not power off → the 4 s power-button override is not effective on this
     platform in this state. Check BIOS setup for a power-button / override
     option, and whether the front-panel button is mediated by the BMC or a CPLD
     rather than wired to PWRBTN# directly.
3. Repeat with the relay instead of a finger (`--dry-run` off, a single
   force-off) to separate the two paths.

Until that is answered, no code change can be verified — which is the point of
this bug.
