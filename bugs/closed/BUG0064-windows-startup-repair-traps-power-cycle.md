---
id: BUG0064
status: resolved
created: 2026-08-17
os:
  - Windows
related_requirements: [SET005, SET007, PWR009, FWK036]
related_bugs: [BUG0032, BUG0036, BUG0046]
---

# BUG0064 — Windows Startup Repair traps a power-cycle run

## Symptom

During a `power_cycle.py` endurance run against a Windows DUT, the DUT sometimes
boots into the **Automatic Repair / Startup Repair** screen instead of Windows.
No network stack is brought up there, so the framework records `NO_BOOT`.

On the reference run (`power_cycle_report_20260817T085350`), 39 of 100 cycles
were `NO_BOOT`, distributed as:

```
1, 11, 33, 35-39, 41-43, 64, 74-100
```

Sporadic at first, then clustered, then **27 consecutive from cycle 74 to the
end of the run**. The operator also observed that the power button sometimes
appeared to need a longer press than the usual 5 s to force the DUT off while
this screen was displayed.

## Root cause

Windows maintains a **consecutive unsuccessful-boot counter**. A boot that does
not reach the "boot succeeded" marker increments it; after **two** consecutive
failures the boot manager stops booting the OS and displays Automatic Repair
instead. A hard power-off applied while Windows is still booting or shutting
down is exactly such a failure.

A power-cycle test does that by design. `ATX_LONG_PRESS_SEC = 5.0` force-off is
how the framework establishes a known state after a `NO_BOOT`, so:

```
NO_BOOT  ->  force-off during boot  ->  counter += 1
             (twice)                ->  next boot = Startup Repair
Startup Repair  ->  no network      ->  NO_BOOT  ->  force-off  ->  ...
```

**The failure is self-reinforcing.** Once the DUT reaches Startup Repair, every
subsequent cycle re-arms the condition that put it there, which is why the tail
of the run is unbroken rather than intermittent. The early sporadic failures
(cycles 1, 11, 33) had some other trigger — a genuinely slow boot exceeding
`BOOT_TIMEOUT_SEC`, cf. BUG0036 — but each one seeded the counter, and the
seeding is cumulative until a clean boot resets it.

Two secondary observations, both explained by the same loop:

- **"Sometimes 5 s seems not to be enough."** The ≥4 s power-button override is
  implemented in the chipset (PCH), not in Windows, and cuts power regardless of
  what the OS is doing — including at the Startup Repair screen. A press that
  works at cycle 30 and appears not to work at cycle 80 is far better explained
  by the DUT re-entering Startup Repair immediately after the force-off than by
  the press duration changing. `ATX_LONG_PRESS_SEC` is left at 5.0.
- **"Does Startup Repair have its own watchdog?"** No. It waits for an operator
  indefinitely; when it does appear to move on by itself it is because a repair
  attempt finished and rebooted, not because a timer expired. An unattended
  bench cannot rely on it clearing itself.

## Fix

`setup_dut.ps1` gains **step 7b / 12 — "Startup Repair (unattended boot)"**,
applied before auto-logon:

```powershell
bcdedit /set {default} recoveryenabled No
bcdedit /set {default} bootstatuspolicy IgnoreAllFailures
```

`recoveryenabled No` stops the boot manager from launching the recovery
environment; `bootstatuspolicy IgnoreAllFailures` stops the failed-boot counting
that arms it. Both are applied, because either alone leaves a path back to the
screen. Each `bcdedit` exit code is checked and a failure is reported as a
warning naming the command, so an unelevated run does not silently leave the
bench exposed.

This is prevention, not detection: the framework cannot recover a DUT that is
already sitting at Startup Repair, because nothing on that screen is reachable
over the network. It is the exact Windows counterpart of BUG0032's GRUB
`GRUB_TIMEOUT` / `GRUB_RECORDFAIL_TIMEOUT` fix for Linux DUTs, and is treated
the same way — permanent bench infrastructure, not reverted by `--restore`. The
restore commands are recorded in a comment beside the step:

```powershell
bcdedit /set {default} recoveryenabled Yes
bcdedit /deletevalue {default} bootstatuspolicy
```

### Recovering a DUT that is already trapped

`setup_dut.ps1` runs inside Windows, so a DUT already stuck in the loop needs
one manual step first: at the Automatic Repair screen choose
**Advanced options → Continue to Windows** (or **Exit and continue**), let it
boot once, then run `setup_dut.ps1`. The clean boot resets the counter and the
`bcdedit` settings stop it from being armed again.

## Verification

Pending on the bench:

1. Run `setup_dut.ps1` on the Windows DUT and confirm step 7b reports both
   settings applied.
2. Confirm with `bcdedit /enum {default}` that `recoveryenabled` is `No` and
   `bootstatuspolicy` is `IgnoreAllFailures`.
3. Force the condition deliberately: power-cycle the DUT twice with a force-off
   part-way through boot, then let it boot normally — it must reach Windows
   rather than Startup Repair.
4. Re-run the 100-cycle `power_cycle.py` test and confirm the `NO_BOOT` tail is
   gone. Any residual isolated `NO_BOOT` is a different defect (BUG0036 /
   BUG0046), not this one.
