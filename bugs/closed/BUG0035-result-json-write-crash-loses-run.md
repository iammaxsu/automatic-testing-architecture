---
id: BUG0035
status: resolved
created: 2026-06-25
closed: 2026-06-25
os: [Windows 11]
related_requirements: [FWK028, PWR012, LOG023]
related_bugs: [BUG0027, BUG0033, BUG0034]
---

# BUG0035 — Transient `os.replace()` failure crashes the whole endurance run

## Symptom

300-cycle `reboot.py` run against a Windows 11 DUT (chained after `power_cycle.py`,
session `20260625T151059`). The DUT PASSed cycles 1-28, then got stuck at the BIOS
POST screen and stopped responding to ping; from cycle ~29 onward every cycle
correctly logged `SSH_ERROR — DUT not pingable before reboot` and moved on (expected:
`MAX_CONSECUTIVE_FAILS = 0` means mid-run consecutive failures do not auto-abort, by
design — see `config.py` comments — so the test kept characterising the hang across
the full run rather than stopping after the first failure). At cycle 173 the process
crashed with an unhandled exception and exited:

```
Traceback (most recent call last):
  File ".../reboot.py", line 565, in <module>
    sys.exit(main())
  File ".../reboot.py", line 514, in main
    function.write_result_json(str(json_path), result)
  File ".../function.py", line 434, in write_result_json
    write_json(path, data)
  File ".../function.py", line 420, in write_json
    os.replace(tmp, path)
FileNotFoundError: [Errno 2] No such file or directory: 'logs/reboot_20260625T151059.result.json.tmp' -> '....result.json'
```

The uploaded `result.json` only contains cycles 1-28 — every cycle recorded between
29 and 173 was held in memory but never reached disk before the crash discarded it.

## Root cause

`function.write_json()` (the FWK028 canonical atomic-write helper, used by both
`power_cycle.py` and `reboot.py` after every cycle) wrote a `.tmp` file and called
`os.replace(tmp, path)` with no error handling. Something external to the test
process (antivirus scan, cloud-sync client, backup job, or similar — the host
filesystem itself was not at fault, the rename target simply observed its `.tmp`
source vanish between creation and rename) made one `os.replace()` call raise
`FileNotFoundError`. Because the per-cycle write call in both scripts' main loops
had no `try/except`, that single transient hiccup was an unhandled exception that
propagated out of `main()` and killed the entire multi-hour run — silently
discarding every cycle recorded since the last successful write, with no resumable
session state pointing past cycle 28 either.

A momentary filesystem-level interruption should never be allowed to erase hours of
already-collected endurance-test data; it directly defeats FWK028's premise that
`result.json` is the durable canonical record.

## Fix

- `function.write_json()` now retries the tmp-write + rename step up to 3 times
  (0.2s, 0.4s backoff) on `OSError`, absorbing a momentary external lock/deletion of
  the `.tmp` file before giving up and re-raising.
- `power_cycle.py` and `reboot.py`'s per-cycle persistence calls
  (`write_result_json()` / session `write_json()`) are now wrapped in `try/except
  OSError`, logging a warning and continuing the loop instead of crashing if all
  retries are exhausted. `result["cycles"]` and `session` are kept in memory and
  re-serialised whole on the next cycle's write, so a failed write only delays
  persistence by one cycle — it never drops data, and it never aborts the run.

## Verification

- `python3 -m py_compile function.py reboot.py power_cycle.py`.
- Unit-level check: monkeypatched `os.replace` to raise `FileNotFoundError` on the
  first call only; confirmed `write_json()` retries and succeeds on the second
  attempt without raising.
- `reboot.py --dry-run --cycles 3 --ssh-user testuser --host 10.0.0.1 --no-check
  --new-session` still completes normally (PASS/PASS/PASS, `result.json` and
  rendered report written) with the new try/except in place.
- Real-hardware re-run under the same conditions that triggered the original crash
  is still pending (the triggering interference is external/intermittent and not
  reliably reproducible in this environment).
