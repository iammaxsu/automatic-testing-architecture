# dev_detect — flags, JSON sidecar, exit codes

Cross-script reference for `src/bash-shell/dev_detect.sh` and
`src/powershell/dev_detect.ps1`. This is the integration contract a
caller (human, or an orchestrator like `power_cycle.py`) needs; each
script's own `--help`/`-Help` only documents that one script. Canonical
requirement: [`DET013`](../requirements/DET013.md).

## Run modes

| Mode | `dev_detect.sh` | `dev_detect.ps1` |
|------|-----------------|------------------|
| Standalone (default) | Owns its own persistent loop: installs a systemd autorun unit, reboots/powers off itself between passes until the target pass count is reached. | Performs one pass and exits. Has no self-triggered reboot/poweroff of its own — repetition across boots is driven entirely by the Task Scheduler entry registered via `setup_dut.ps1`. |
| Snapshot (`--snapshot-only` / `-SnapshotOnly`) | Runs exactly one pass. Does **not** install autorun and does **not** reboot/poweroff — loop count and power-cycling belong to the external orchestrator. The golden reference is kept in a process/session-independent location (`<logs>/golden/`, not the per-session subdir) so it survives across separate invocations. | Behaves the same as standalone mode (it already does a single pass with no self-reboot). The flag exists for parity with `dev_detect.sh` and is recorded in the JSON sidecar's `mode` field. |

Both scripts accept the flag without disturbing their default
(no-flag) behaviour — it is purely additive.

## Exit codes

Both scripts use the same four-state exit code on every pass, in both
modes:

| Code | Meaning | Notes |
|------|---------|-------|
| `0` | Pass | Output matches an existing golden reference — a verified check. |
| `1` | Fail | Output deviates from an existing golden reference. |
| `2` | Error | Detection could not run (e.g. a required tool is missing, or a check threw). |
| `3` | INIT | No golden existed yet; one was just created from the current machine. **Not** a verified pass — exclude from pass/fail statistics, since nothing was actually compared. |
| `64` | Usage | An unrecognized command-line argument was given. No pass was run, no golden/log/sidecar written. Deliberately outside the `0`–`3` verdict range so an orchestrator never mistakes a typo for a verdict. |

When a run does multiple checks/components and they disagree (e.g. one
component Fails while another is still INIT), precedence is
**Fail > INIT > Pass** for the overall result and exit code.

Both scripts also reject any flag/argument they do not recognize
instead of silently ignoring it (`dev_detect.sh`'s `--vpu-*` parser and
`dev_detect.ps1`'s `param()` binding both used to swallow unknown
tokens and run a normal pass anyway — fixed on both sides).

## JSON sidecar

Each pass writes one JSON file next to its existing human-readable log,
without altering or replacing that log. This file is the canonical,
machine-readable record of the pass (FWK028); the `.log`/`.txt`/`.diff`
files remain the human-readable view.

Minimum fields (both scripts):

```json
{
  "schema_version": "2.0",
  "session_id": "...",
  "k": 1,
  "m": 1,
  "result": "Pass | Fail | Error | INIT",
  "timestamp": "2026-06-23T09:15:23Z",
  "components": {
    "cpu_model": {
      "result": "Pass | Fail | Error | INIT",
      "current": "<derived comparison scalar>",
      "golden":  "<golden scalar, or null on INIT>"
    }
  }
}
```

- `k` / `m` — pass index / target pass count. `dev_detect.ps1` has no
  fixed target count of its own, so `m` is `null` there.
- `components` — per-component comparison breakdown. Each entry is a
  `{ result, current, golden }` triple: `result` is the same four-state
  tag as the top-level (`Pass`/`Fail`/`Error`/`INIT`); `current` is the
  scalar this pass derived for that component; `golden` is the baseline
  it was compared against, and is `null` on an INIT pass (nothing was
  compared — the golden was just created). The overall top-level
  `result` is the Fail > INIT > Pass rollup over all components.
- **Common-core components** present and identically named on both
  scripts: `cpu_model` (DET001), `memory_total_gb` (DET002),
  `nic_model_counts` (DET003), `usb_passmark_count` (DET004, scoped to
  the PassMark loopback-plug count), `storage_model_bus_counts`
  (DET005). Each OS may add **extra** components it alone can probe
  (e.g. `dev_detect.sh`'s `pcie_gpu`); an orchestrator should rely only
  on the common five and treat any other key as opaque OS-specific
  detail. The per-component shape ships on both scripts (2026-06-24);
  `dev_detect.sh` still keeps a whole-file snapshot/golden/diff as a
  human-readable artefact (`snapshot_path`/`golden_path`/`diff_path`
  below), but the top-level `result` is driven by the per-component
  rollup, not that whole-file diff
  (see [`contract-alignment-plan.md`](contract-alignment-plan.md)
  Layer 2).
- `schema_version` is `"2.0"`: the `components` value shape changed from
  the `1.0` `"<name>": "<tag>"` string map to the `"<name>":
  { result, current, golden }` object map. A `1.0` consumer reading a
  component as a bare string would break, hence the major bump.
- `dev_detect.sh` additionally includes `snapshot_path`, `golden_path`,
  and `diff_path` (`null` when there is no diff, e.g. on INIT).
- `dev_detect.ps1` additionally includes `log_path` (the per-run `.log`
  this sidecar corresponds to) and `mode` (`standalone` or `snapshot`).

## Orchestrator integration (e.g. `power_cycle.py`)

After confirming the DUT is alive, an orchestrator may SSH-invoke the
script with `--snapshot-only` / `-SnapshotOnly`, read the process exit
code to get the pass/fail/error/init outcome without parsing any text,
and optionally pull the JSON sidecar back to fold into its own
`result.json`. The orchestrator side of this integration is not yet
implemented — this document only fixes the contract the script side
exposes.
