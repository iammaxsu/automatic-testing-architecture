---
id: BUG0065
status: resolved
created: 2026-08-17
closed: 2026-08-17
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [DET002, DET013, FWK028]
related_bugs: [BUG0038, BUG0039]
---

# BUG0065 — dev_detect harness left failing by two behaviour changes

## Symptom

`src/bash-shell/test_dev_detect.sh` reported `33 passed, 3 failed` while every
other suite was green, so a broken harness was sitting unnoticed beside working
tests:

```
[FAIL] second --snapshot-only pass exit code (expected 0, got 3)
[FAIL] sidecar result == Pass (expected Pass, got INIT)
[FAIL] autorun_setup attempted a systemd-related sudo call
```

## Root cause

`git bisect` attributes the three failures to two separate commits, neither of
which updated the harness:

1. **`92787cf` (BUG0038 refinement)** gated `autorun_setup` on `_m > 1`, so a
   one-shot `dev_detect.sh` deliberately installs no systemd unit. The harness
   still asserted that a single run *does* attempt the systemd call — it was
   pinning the behaviour the commit had just removed.
2. **`5595d5c` (DET002 / BUG0039)** added the memory-usability component.
   `dmidecode` is not present in the CI container, so `mem_usability_check`
   returns `UNKNOWN`, which by design rolls up like `INIT` and must never be a
   silent Pass. Every scenario therefore ended `INIT` / exit 3, and the second
   snapshot pass could no longer reach `Pass`.

Neither failure is a defect in `dev_detect.sh`: the first assertion was stale,
and the second was the harness measuring the absence of `dmidecode` rather than
the behaviour of the script.

## Fix

- The harness gains a `dmidecode` mock alongside the existing `sudo` / `reboot`
  / `poweroff` shims. It reports one DIMM rounded up from the running kernel's
  `MemTotal`, so `installed >= usable` with a gap far below the 2 GiB tolerance
  floor — a healthy machine, deterministic on any host, and the tool's real
  absence is no longer confused with a hardware verdict.
- The single-run scenario now asserts the opposite: no systemd unit is
  installed, citing BUG0038 for why.
- A new scenario runs a two-loop campaign and asserts that autorun *is*
  installed and that a reboot is issued, so the multi-boot path that
  `autorun_setup` exists for stays covered rather than being dropped along with
  the stale assertion.

## Verification

`bash src/bash-shell/test_dev_detect.sh` — 39 passed, 0 failed. The suite is
included in the pre-commit run of every bash suite from now on; it had been
absent from that list, which is how it stayed red across two commits.
