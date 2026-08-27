---
id: BUG0064
status: resolved
created: 2026-08-17
os:
  - Windows
related_requirements: [SET005, SET007, PWR009, FWK036]
related_bugs: [BUG0032, BUG0036, BUG0046, BUG0066]
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

### Did the force-off work?

Not in the tail, and the log could not have told us. Every `NO_BOOT` cycle took
210 s to the second — but that is the script's own schedule (boot timeout 135 s
plus the force-off and off-time budget) and it holds whether or not any of those
actions reached the DUT, because relay control is open-loop (BUG0066). What the
log does establish is narrower: cycles 2, 12, 34, 40, 44 and 65 passed
immediately after a `NO_BOOT`, and a pass requires powering on from off, so the
relay path worked at those six moments.

**Bench evidence settles the rest.** An earlier version of this bug argued that the
≥4 s power-button override is PCH hardware and therefore works at the Recovery
screen, so a 5 s hold must have been effective and the intermittency had to be
the loop. The operator then watched cycles 97–100 stay on the Recovery screen
throughout, and tested by hand: **a 10 s press at that screen powers the DUT off
immediately.** So the override does work there — 5 s through the relay did not.

Two things follow. The platform is fine and the hold time was wrong:
`ATX_LONG_PRESS_SEC` is now 10.0, the value observed to work, escalating to 15 s
on a repeat (BUG0066). And what looked like force-off "working" earlier in the
run was something else: `setup_dut.ps1` sets the power button action to Shut
down, so at the Windows desktop *any* press starts a graceful shutdown and the
machine is gone long before the override matters. The override was only ever
exercised at the Recovery screen — the one place it was never given long enough.

Whether 5 s failed because the platform needs longer than the spec minimum, or
because the relay path delivers less than it is told to, is still open. A run at
10 s that still gets stuck would implicate the relay path.

The counter is incremented per boot attempt and cleared only when Windows
completes startup — practically, when the desktop is reached. A cycle that ends
in a normal graceful shutdown therefore clears it, which is why a healthy run
never trips this; only interrupted boots accumulate, and they accumulate across
cycles. Being force-offed *at* the Startup Repair screen does not clear it
either, because the OS never started.

Two secondary observations:

- **"Sometimes 5 s seems not to be enough."** Correct, and it is the reason the
  tail never broke: see above. `ATX_LONG_PRESS_SEC` is 10.0.
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
