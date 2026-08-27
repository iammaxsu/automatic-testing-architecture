---
id: BUG0028
status: resolved
created: 2026-06-08
os:
  - Windows 11 (English / en-US)
  - Windows 11 (Traditional Chinese / zh-TW)
related_requirements: [SLP002, SLP003]
related_bugs: []
---

# BUG0028 — `sleep_test.ps1 -Detect` crashes with `PropertyNotFoundException` when no sleep state is supported

## Symptom

Running the freshly-downloaded `sleep_test.ps1` on a real DUT (Windows 11,
**English** UI) fails immediately, both in `-Detect` and `-OneShot` mode:

```
PS> .\sleep_test.ps1 -Detect
sleep_test.ps1 v00.00.01
         Loaded config : C:\Users\nimitz4\Downloads\powershell\config.ps1
sleep_test.ps1 : The property 'Count' cannot be found on this object.
Verify that the property exists.
    + FullyQualifiedErrorId : PropertyNotFoundStrict,sleep_test.ps1
```

`powercfg /a` on that DUT shows it supports **no** sleep state at all
(S1/S2/S3, Hibernate and S0 are all "not available — the system firmware does
not support this state"). So the correct detection result is "zero states";
the crash is in how that empty result is handled, not in the detection value.

## Root cause

The actual crash trigger (defect 1) and a separate latent defect (defect 2):

1. **Empty array collapses to `$null` through `return`** — the real crash.
   When the DUT supports no sleep state, `Get-SupportedSleepStates` returned an
   empty `string[]` via `return $states.ToArray()`. PowerShell's pipeline
   unwraps a zero-element array emitted through `return`/`Write-Output` into
   **no objects at all**, so the caller's
   `$supported = Get-SupportedSleepStates` received `$null`, not `@()`. The next
   line, `if ($supported.Count) {...}`, accessed `.Count` on `$null` under
   `Set-StrictMode -Version Latest`, raising exactly the
   `PropertyNotFoundException` ("The property 'Count' cannot be found on this
   object") in the symptom — a well-known PowerShell strict-mode trap, not a
   missing member on an array. This fires on **any** DUT with zero supported
   states, regardless of UI language; the English DUT above hit it because it
   genuinely supports nothing. `Resolve-States` had the identical
   `return $sel` hazard feeding `$selected.Count` later.

2. **Locale-dependent text parsing of `powercfg /a`** — a latent defect that
   would give *wrong* results (not a crash) on a non-English Windows. The
   original `Get-SupportedSleepStates` matched English section headers
   (`'are available on this system'`, `'are not available'`) to decide which
   half of the output to scan. On a Traditional Chinese Windows those headers
   are translated (`此系統有以下幾種睡眠狀態:` / `此系統缺乏以下幾種睡眠狀態:`),
   so the regex never matched and `$inAvail` stayed `$false` for the whole
   output — every state would be misreported as unsupported even when the DUT
   actually supports it (e.g. a zh-TW machine with Hibernate + S0 available).

## Fix

- **Detect via a locale-independent binary capability struct.** Replaced the
  `powercfg /a` text parsing entirely with `CallNtPowerInformation`
  (`SystemPowerCapabilities`, level 4) added to the existing `SleepNative`
  P/Invoke class. It fills a `SYSTEM_POWER_CAPABILITIES` struct of plain
  `BOOLEAN`/`BYTE` fields (no strings), read here as a raw byte buffer at fixed
  offsets: `[5]`=SystemS3, `[6]`=SystemS4 (hibernate), `[20]`=AoAc (S0 Modern
  Standby), plus S1/S2/HiberFile. Identical bytes on every UI language. We then
  synthesise our **own** canonical English labels from those booleans, so a
  report reads "S3: not supported" the same way on an English or a Traditional
  Chinese DUT (answers the cross-locale question that prompted this fix). This
  also supersedes the earlier (v00.00.02) `IsPwrSuspendAllowed` /
  `IsPwrHibernateAllowed` probes, which could not distinguish S1/S2/S3 nor
  detect S0 Modern Standby.
- **Stop empty arrays collapsing to `$null`.** Changed every
  `return <possibly-empty-array>` in `Get-SupportedSleepStates` and
  `Resolve-States` to `return ,<array>` (unary comma operator). Both functions
  now always return a `string[]` — empty or not — so `.Count` is safe under
  strict mode.
- **Richer `-Detect` output.** Now prints S1/S2/S3/S4/S0 support as canonical
  English lines, and when neither S3 nor S4 is available it says so explicitly
  (noting S0 Modern Standby if present, which the S3/S4 endurance test cannot
  drive via `SetSuspendState`).
- Bumped `$_script_ver` to `00.00.03`.

## Verification

Re-run on both DUTs:

```
.\sleep_test.ps1 -Detect
.\sleep_test.ps1 -OneShot -State S3 -WakeAfter 10
```

- English DUT (supports nothing): `-Detect` must complete without
  `PropertyNotFoundException` and report S1/S2/S3/S4/S0 all "not supported",
  i.e. "the S3/S4 endurance test cannot run on this DUT". `-OneShot -State S3`
  must exit cleanly with the "not supported" message (exit code 3), not crash.
- Traditional Chinese DUT (Hibernate + S0 available, S3 not): `-Detect` must
  report `S4 (Hibernate): supported` and `S0 (Modern Standby): supported`,
  matching the content of that DUT's native-language `powercfg /a` output,
  proving the detection is locale-independent.
