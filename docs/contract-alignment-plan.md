# Cross-OS contract alignment plan (Linux ↔ Windows)

**Status:** living / working plan — not a canonical requirement. Items
graduate into `requirements/` (DET-series) as they are pinned down.
**Started:** 2026-06-24
**Owner:** Max

This is the roadmap for making `src/bash-shell/dev_detect.sh` (Linux)
and `src/powershell/dev_detect.ps1` (Windows) present the *same
integration contract* to the Python orchestrator that will drive them
over SSH. It records a decision taken in conversation so it does not
drift; the concrete per-flag/per-code contract lives in
[`docs/dev_detect.md`](dev_detect.md), and the canonical requirement is
[`DET013`](../requirements/DET013.md).

The work is split into three layers, highest leverage first. Do the top
layer fully; the lower layers are progressively more optional.

## Layer 1 — Contract alignment (must do, highest leverage)

Unify the things the Python integration *cannot* work without:

- **Flags** — same surface on both sides (`--snapshot-only`, `--help`).
- **Exit-code semantics** — `0 Pass / 1 Fail / 2 Error / 3 INIT`
  identical on both OSes; usage errors stay *outside* that range.
- **Output structure** — same artefacts (per-run log, JSON sidecar,
  summary) with the same field meanings.

Rationale: Python integration needs this, and DET001–DET011 are still
mostly `proposed` — this is the moment to nail the shared contract
before the spec grows around a moving target.

**Progress so far:**
- [x] `dev_detect.ps1` accepts `--snapshot-only` (alias of
      `-SnapshotOnly`) and `--help` (alias of `-Help`/`-h`).
- [x] Unrecognized arguments now error with exit `64` (`EX_USAGE`) on
      **both** scripts instead of silently running a pass — keeps the
      `0/1/2/3` verdict range clean. (`dev_detect.sh`'s `--vpu-*`
      parser had the same silent-swallow defect as the PowerShell
      `param()` binding; fixing it surfaced a second, unrelated latent
      bug — see below.)
- [x] Both scripts emit a JSON sidecar + per-run log + summary with a
      `mode` field (`standalone` / `snapshot`).
- [x] Audited (2026-06-24): `dev_detect.sh`'s JSON sidecar `components`
      field is **always `{}`** — it never populates per-check results,
      unlike `dev_detect.ps1` which already fills `cpu_model` /
      `memory_total_gb` / `usb_passmark_count` / `nic_model_counts` /
      `storage_model_bus_counts`. Tracked as a Layer-2 deliverable below
      (the comment in `dev_detect.sh` already says it's a placeholder
      pending structured per-component comparison), not a Layer-1 gap
      to close separately.
- [ ] Audit DET001–DET011 frontmatter/wording so both implementations
      cite one shared statement per check.

**Side-finding while closing the unknown-argument gap:** fixing
`dev_detect.sh` exposed a pre-existing, unrelated bug — its EXIT trap
(`fix_log_permissions "${_log_dir:-}" deep`) referenced `_log_dir`
before it is ever assigned (`log_dir` runs later in the script). Any
exit occurring before that point — the new usage-error exit, but also
the pre-existing `check_api_versions` `exit 63` path — hit
`fix_log_permissions`'s own `"${1:-${_log_dir}}"` fallback, which read
the still-unbound `_log_dir` under `set -u` and silently replaced the
script's real exit code with `1`. Fixed by binding `_log_dir` to `""`
immediately after the trap is installed, so every early-exit path now
reports its actual code.

## Layer 2 — Test-semantics alignment (should do)

Unify the *granularity* of the golden comparison. Today the two sides
disagree:

- Linux: full-text `diff` of a normalized snapshot.
- Windows: scalar (single derived string) comparison.

Target: both move to **structured output (JSON) + per-field
comparison**. This solves three things at once:

1. Both OSes share one comparison semantic.
2. Satisfies [`FWK028`](../requirements/FWK028.md): JSON is canonical;
   text/HTML reports are *rendered* from it.
3. Python pulls the JSON back over SSH and writes it straight into
   `result.json` — no parsing of `PASS`/`FAIL` strings.

## Layer 3 — Detection-depth alignment (partial — do NOT do all)

Agree on a small set of **common core fields** — CPU model, RAM total,
storage model+bus, NIC model+count, USB — mapping to DET001–DET006.
Allow each OS to *add* platform-only detail it can actually obtain:

- Linux: VT-d, per-DIMM detail.
- Windows: PassMark loopback-plug count, per-DIMM part number, PCIe
  current/max link ability.

Do **not** force the field sets to be identical. Hardware-probing
ability genuinely differs by OS; forcing parity only makes one side
stuff in fake data.

## Explicitly out of scope of this plan

- **`dev_detect.sh N` (cross-reboot pass count).** The Linux script's
  positional `N` makes it own a persistent loop: install a systemd
  autorun unit and reboot/poweroff between passes until `N` passes have
  run. That repeat/reboot loop is an **orchestration-layer** concern,
  owned on Windows by Task Scheduler (registered via `setup_dut.ps1`)
  and, for either OS, by an external driver such as `power_cycle.py`.
  `dev_detect.ps1` therefore performs exactly one pass per invocation by
  design and does not accept `N`. Porting an in-script reboot loop to
  PowerShell is a separate, later piece of work — it is not part of the
  three layers above.

## Related

- [`docs/dev_detect.md`](dev_detect.md) — the concrete flag / exit-code
  / sidecar contract these layers converge on.
- [`DET013`](../requirements/DET013.md) — canonical requirement for the
  four-state exit code and per-pass sidecar.
- [`FWK028`](../requirements/FWK028.md) — canonical-form-first, the
  basis for Layer 2.
