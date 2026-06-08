---
id: BUG0028
status: resolved
created: 2026-06-08
os:
  - Windows 11 (Traditional Chinese / zh-TW)
related_requirements: [SLP002, SLP003]
related_bugs: []
---

# BUG0028 — `sleep_test.ps1 -Detect` crashes with `PropertyNotFoundException` on a localized Windows

## Symptom

Running the freshly-downloaded `sleep_test.ps1` on a real DUT (Windows 11,
Traditional Chinese UI) fails immediately, both in `-Detect` mode and
`-OneShot` mode:

```
PS> .\sleep_test.ps1 -Detect
sleep_test.ps1 v00.00.01
         Loaded config : C:\Users\nimitz4\Downloads\powershell\config.ps1
sleep_test.ps1 : The property 'Count' cannot be found on this object.
Verify that the property exists.
    + FullyQualifiedErrorId : PropertyNotFoundStrict,sleep_test.ps1
```

## Root cause

Two compounding defects in `sleep_test.ps1` v00.00.01:

1. **Locale-dependent text parsing of `powercfg /a`.** The original
   `Get-SupportedSleepStates` matched English section headers
   (`'are available on this system'`, `'are not available'`) to decide which
   half of the `powercfg /a` output to scan. On a Traditional Chinese Windows
   these headers are localized, so the regex never matched, `$inAvail` stayed
   `$false` for the whole output, and **zero** states were ever found —
   regardless of what the DUT actually supports.

2. **Empty array collapses to `$null` through `return`.** When
   `Get-SupportedSleepStates` found nothing, it executed
   `return $states.ToArray()` with an empty `string[]`. PowerShell's pipeline
   unwraps a zero-element array emitted through `return`/`Write-Output` into
   **no objects at all**, so the caller's `$supported = Get-SupportedSleepStates`
   received `$null`, not `@()`. The very next line,
   `if ($supported.Count) {...}`, then accessed `.Count` on `$null` under
   `Set-StrictMode -Version Latest`, which raises exactly the
   `PropertyNotFoundException` ("The property 'Count' cannot be found on this
   object") seen in the symptom — a well-known PowerShell strict-mode trap,
   not a missing member on the array.

`Resolve-States` had the identical empty-array-collapse hazard
(`return $sel`) feeding `$selected.Count` later in the script; it had not yet
been hit only because `Get-SupportedSleepStates` already crashed first.

## Fix

- Replaced `powercfg /a` text parsing with two locale-independent Win32
  capability probes from `powrprof.dll` — `IsPwrSuspendAllowed()` (S3) and
  `IsPwrHibernateAllowed()` (S4) — added to the existing `SleepNative`
  P/Invoke class (the same interop mechanism the script already uses for
  `SetSuspendState`/`CreateWaitableTimer`). These report exactly what the
  test needs (is S3/S4 available *and* enabled) with zero language dependency.
- Changed every `return <possibly-empty-array>` in `Get-SupportedSleepStates`
  and `Resolve-States` to `return ,<array>` (unary comma operator), which
  prevents PowerShell's pipeline from unwrapping a zero-element array into
  `$null`. Both functions are now guaranteed to return a `string[]` — empty
  or not — so `.Count` is always safe under strict mode.
- Removed the now-unreachable S0/S1/S2 fallback branch in `Resolve-States`
  (the new detection only ever probes for S3/S4, the two states this test
  targets, so that branch could never be exercised).
- Bumped `$_script_ver` to `00.00.02`.

## Verification

Re-run on the same Traditional Chinese Windows 11 DUT:

```
.\sleep_test.ps1 -Detect
.\sleep_test.ps1 -OneShot -State S3 -WakeAfter 10
```

Both must complete without `PropertyNotFoundException` and `-Detect` must
print the actual S3/S4 support of the DUT (cross-checked against
`powercfg /a`'s native-language output, matching by content rather than by
locale-specific header text).
