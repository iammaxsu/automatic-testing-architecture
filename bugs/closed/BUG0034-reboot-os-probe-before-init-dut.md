---
id: BUG0034
status: resolved
created: 2026-06-25
os:
  - Windows 11
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [PWR012, FWK031, FWK035]
related_bugs: [BUG0030, BUG0033]
---

# BUG0034 — reboot.py probes DUT OS before init_dut() brings it online

## Symptom

In the same real run as BUG0033, the DUT is Windows 11 but the resolved reboot
command was the Linux `sudo reboot` (`config.ssh_cmd: "sudo reboot"` in
`result.json`, `SSH cmd : sudo reboot` in the log banner). Had the connection not
been blocked first by the changed host key, a Windows DUT would have been sent a
command it cannot execute.

## Root cause

`reboot.py main()` resolved `--dut-os auto` by calling `detect_dut_os()` **before**
`init_dut()` ran. The DUT in this run was powered off at start, so the OS probe's
SSH attempt failed (transport error), `detect_dut_os()` correctly returned
`"unknown"`, and the code fell back to `config.DUT_OS` (`"linux"`) — selecting
`sudo reboot`. `init_dut()` then powered the DUT on, but by that point the wrong OS
(and wrong command) was already locked in. The probe was simply ordered too early:
it ran against a machine that was not yet alive.

## Fix

Deferred the OS probe until **after** `init_dut()` reports the DUT online. When
`--dut-os auto` and the DUT is reachable (not dry-run / `--no-check`, and no
explicit `--ssh-cmd`), `reboot.py` now sets a `probe_os_after_init` flag and runs
`detect_dut_os()` immediately after a successful `init_dut()`, then derives
`ssh_cmd` from the detected OS. Cases that genuinely cannot probe (dry-run,
`--no-check`, missing ssh-user/host) still resolve from `config.DUT_OS` up front,
exactly as before. The detected `dut_os` is also recorded in `result.json`'s
`config` block so the HTML report shows the OS that was actually targeted.

This composes with BUG0033's fix: with `UserKnownHostsFile=/dev/null` the
post-init probe can actually reach a re-keyed DUT, so the OS is detected correctly
rather than failing back to the config default.

## Verification

Sandbox: `reboot.py --dry-run` still resolves `sudo reboot` from `config.DUT_OS`
(probe correctly skipped when SSH is unavailable); the file byte-compiles. The
deferred-probe path runs only against a live DUT.

Still pending on real hardware: run `reboot.py --dut-os auto` against a Windows 11
DUT that is powered **off** at start, and confirm that after `init_dut()` powers it
on, the probe detects `windows` and issues `shutdown /r /t 0` (not `sudo reboot`).
