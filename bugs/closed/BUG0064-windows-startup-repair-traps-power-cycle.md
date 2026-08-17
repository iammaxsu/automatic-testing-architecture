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

The report attributed all 39 to a failed power-on and told the operator to check
the relay and the power-button press, which is the wrong place to look.

### The force-off did work

Worth stating explicitly, because the run's own data settles it:

- Every `NO_BOOT` cycle in the run took **210 s**, to the second, across all 27
  of the consecutive ones — the boot timeout (135 s) plus the force-off and
  off-time budget. The loop was executing the force-off path each time.
- More conclusively, cycles 2, 12, 34, 40, 44 and 65 **passed** immediately
  after a `NO_BOOT`. A pass requires the DUT to power on from off, so the
  force-off that preceded it must have cut power.

The ≥4 s power-button override is implemented in the PCH and is independent of
what the OS is doing, so it works at the Startup Repair screen as well as
anywhere else. `ATX_LONG_PRESS_SEC` stays at 5.0. What looks like a force-off
that did nothing is the DUT re-entering Startup Repair on the *next* power-on —
and, at the end of the run, the DUT simply being left at that screen with no
further cycles to power it off.

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

The counter is incremented per boot attempt and cleared only when Windows
completes startup — practically, when the desktop is reached. A cycle that ends
in a normal graceful shutdown therefore clears it, which is why a healthy run
never trips this; only interrupted boots accumulate, and they accumulate across
cycles. Being force-offed *at* the Startup Repair screen does not clear it
either, because the OS never started.

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

### The diagnosis wording

`power_cycle.py`, `reboot.py` and the report claimed a `NO_BOOT` with no ping at
all was a failed power-on. It is not distinguishable from the network: a DUT
that never powered on and a DUT stopped at a screen with no network are the same
silence. All three now report both possibilities and say to look at the DUT's
display.

The report additionally counts the longest **consecutive** run of them and, at
three or more, names the likely screen (OS-aware) and the reason the run is
unbroken: a power-on or relay fault is random, whereas a boot-blocking screen is
sticky because each force-off is itself another interrupted boot. On this run
that banner reads "27 of those NO_BOOT cycles are consecutive".

### Recovering a DUT that is already trapped

A DUT set up before this fix does **not** carry the two `bcdedit` settings — the
step did not exist when its `setup_dut.ps1` ran — so it has to be applied once,
and `bcdedit` needs a running Windows. For a DUT currently stuck at the screen:

1. At the Automatic Repair screen, **Advanced options → Continue to Windows**
   (or **Exit and continue**) and let it reach the desktop. That successful
   startup clears the counter.
2. In an elevated PowerShell / cmd, either re-run `setup_dut.ps1` (idempotent,
   applies everything else too) or just the two `bcdedit` commands above.
3. `bcdedit /enum {current}` to confirm.

After that the counter can no longer be armed, so the manual step is one-off.

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
