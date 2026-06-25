---
id: BUG0032
status: resolved
created: 2026-06-25
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR012, SET007]
related_bugs: []
---

# BUG0032 — GRUB menu can block unattended Linux reboot tests

## Symptom

During a Linux `reboot.py` run, the DUT occasionally parks at the GRUB boot menu
instead of proceeding straight to the OS, with no operator present to press Enter.
It does not happen on every cycle.

## Root cause

While the DUT is sitting at the GRUB menu, the kernel has not loaded and no network
stack exists, so `reboot.py`'s ping/SSH liveness poll cannot succeed — this is dead
time, not a valid "alive" state. `wait_until_alive()` is bounded by
`BOOT_TIMEOUT_SEC` (default 120 s); if the menu waits longer than that (or
indefinitely), the cycle is recorded as `NO_BOOT` even though the DUT is otherwise
fine.

Two independent GRUB settings can each cause this, and `setup_dut.sh` configured
neither:

- `GRUB_TIMEOUT` — the normal "show menu for N seconds" countdown. Ubuntu's stock
  default is 10 s, well under `BOOT_TIMEOUT_SEC`, so this alone would not usually
  cause a `NO_BOOT` — but it does waste ~10 s of every cycle's boot-time measurement
  on a static splash with no information value.
- `GRUB_RECORDFAIL_TIMEOUT` (Ubuntu-specific) — overrides `GRUB_TIMEOUT` and
  defaults to **-1 (wait forever, no auto-boot)** whenever the previous boot did not
  reach the "boot ok" marker. A power-cycle or reboot test that doesn't always shut
  down perfectly cleanly will intermittently trip this, which matches the observed
  "only sometimes" behaviour exactly.

## Fix

`setup_dut.sh` v00.00.02 adds step 7/9 — "GRUB: unattended boot": sets
`GRUB_TIMEOUT=0` and `GRUB_RECORDFAIL_TIMEOUT=0` in `/etc/default/grub` (idempotent;
only rewrites the file and runs `update-grub`/`grub-mkconfig` when a value actually
changes), so every boot proceeds straight to the default entry regardless of how the
previous boot ended. Skips cleanly on non-GRUB systems (`/etc/default/grub` absent).

This is treated as permanent framework infrastructure (like the SSH key and sudoers
rules already installed by this script), not a temporary test-only setting, so it is
not reverted by `setup_dut.sh --restore`.

## Verification

Still pending: run `setup_dut.sh` on a Linux DUT, confirm
`grep -E 'GRUB_(TIMEOUT|RECORDFAIL_TIMEOUT)=' /etc/default/grub` shows both at `0`,
then run several `reboot.py` cycles (ideally including at least one preceded by an
unclean shutdown, to exercise the recordfail path) and confirm the DUT never parks at
the GRUB menu and `boot_time_sec` no longer includes menu wait time.
