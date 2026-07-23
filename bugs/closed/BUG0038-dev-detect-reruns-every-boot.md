---
id: BUG0038
status: resolved
created: 2026-07-22
closed: 2026-07-22
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [DET013, DET012, FWK013]
related_bugs: []
---

# BUG0038 — `dev_detect` runs at every boot and never self-disables

## Symptom

After running `setup_dut.sh` on a Linux DUT and rebooting, `dev_detect` runs on
**every** boot: two `wall` broadcasts appear each time —

```
!! TEST IN PROGRESS — DO NOT POWER OFF !!   Script: dev_detect  Progress: [####] 1/1
dev_detect completed 1/1. Safe to power off.
```

A manual `sudo systemctl poweroff` + reboot reproduces it again. The operator had
only run `setup_dut.sh` — never `dev_detect.sh` — yet the detection kept running
and re-announcing "1/1 complete" forever. (It does not actually power off; the
messages are informational only.)

## Root cause

Two independent problems compound:

1. **`setup_dut.sh` enabled the boot service at setup time.** Step 8 registered
   `dev-detect.service` and immediately `systemctl enable`d it, so merely running
   the *installer* caused `dev_detect` to execute at the next boot. This violates
   the principle that "setup" prepares the DUT but does not start testing.

2. **`autorun_disable_if_done` never disabled the service.** Once `dev_detect`
   reaches its target loop count (default `1`, i.e. `1/1`), it is supposed to
   `systemctl disable --now` its own boot service. But `autorun_disable_if_done`
   recomputed the counter-file path from `_log_dir`
   (`${_log_dir}/session_state/counter.dev`), whereas `counter_init` writes the
   counter using a **cached** `_session_state_dir` (and `counter_init` runs before
   `log_dir()`). When the two paths differ, the disable check reads a
   non-existent/empty counter, sees `__m=0`, concludes "not done", and skips the
   disable. Combined with `counter_init`'s rule that a *finished* counter is reset
   to `0/target` on the next run, the service stayed enabled and re-ran fully on
   every boot, re-announcing "1/1 complete" each time.

## Fix

- **`setup_dut.sh` (step 8):** install the `dev-detect.service` unit file but do
  **not** enable it; also actively `systemctl disable` it (idempotent, and undoes
  older setup_dut versions that enabled it). Boot-time execution is now turned on
  only by `dev_detect.sh` itself (`autorun_setup`) when the operator starts a
  campaign, and turned off again when the target count is reached.
- **`function.sh` `autorun_disable_if_done`:** read the counter from the exact
  file `counter_init` cached (`${_counter_file:-<recomputed>}`), so "done" is
  detected reliably and the service is actually disabled.
- **`dev_detect.sh`:** only call `autorun_setup` (boot persistence) for a
  multi-loop campaign (`_m > 1`). A single run (`_m == 1`, the default) now runs
  purely in the foreground and touches no systemd unit — `autorun_setup` exists
  to protect a multi-boot campaign from missing persistence, a risk that does not
  apply to a one-shot detection.

## Verification

- Reproduced the path mismatch in isolation: with the counter written to the
  cached path but `_log_dir` pointing elsewhere, the old recompute-only logic
  read an empty counter and did **not** disable; the fixed logic (using
  `_counter_file`) read `1/1` and disabled correctly.
- `bash -n` passes for `setup_dut.sh` and `function.sh`.

On hardware: re-run `sudo ./setup_dut.sh`; reboot — `dev_detect` should NOT run
and no broadcasts should appear. Then run `dev_detect.sh` once; after it reports
`1/1` complete, reboot — it should NOT run again (service disabled). Immediate
manual remedy for an already-affected DUT:
`sudo systemctl disable --now dev-detect.service`.
