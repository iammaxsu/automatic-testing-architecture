---
id: BUG0039
status: resolved
created: 2026-07-27
closed: 2026-07-27
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [DET002, FWK037]
related_bugs: []
---

# BUG0039 — A populated-but-unusable DIMM is not detected as a failure

## Symptom

On a DUT with **6 × 32 GB** DIMMs installed, the system boots normally into
Ubuntu (power_cycle and reboot both PASS), but the memory is not all usable:

- `dmidecode -t memory` shows **6 populated slots** (→ 192 GB expected).
- `cat /proc/meminfo` (`MemTotal`) shows only **~128 GB**.
- The BIOS setup screen also shows only **4 DIMMs / 128 GB**.

So two DIMMs are physically populated (SPD readable, hence visible to
`dmidecode`) but were not trained/enabled by the memory controller, and are
therefore not usable by the OS. `dev_detect`'s current RAM detection reports the
DMI/`dmidecode` view and would treat this as a normal 6-DIMM machine — it does
**not** flag the 64 GB shortfall, so a defective DIMM/slot/seating passes
silently.

## Root cause

RAM detection trusts a single source (`dmidecode` / DMI/SPD), which reflects
what is *physically populated*, not what the system can *actually use*. A DIMM
that fails memory training still appears populated in SPD/DMI. Without
cross-checking against the OS-usable total (`/proc/meminfo` `MemTotal`), the
discrepancy is invisible to the test.

## Fix

Per the expanded DET002: report both the DMI-populated total (`dmidecode`) and
the OS-usable total (`/proc/meminfo` MemTotal), and FAIL when the usable total is
short of the populated total by more than a reserved-memory tolerance (i.e. a
whole DIMM or more is missing). Implement equivalently on Windows
(`Win32_PhysicalMemory` populated vs `Win32_ComputerSystem.TotalPhysicalMemory`
usable) per FWK036. Report the gap and a human-readable reason.

## Verification

Reproduce with the affected DUT (6×32 GB, only 128 GB usable): the test must
FAIL with a reason naming the ~64 GB gap / two unusable DIMMs. On a fully-healthy
DUT the same check must PASS (usable ≈ installed within tolerance), and normal
reserved-memory shrinkage must not cause a false FAIL.
