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
      cite one shared statement per check. (DET001–DET006 read in full
      2026-06-24 to ground the Layer 2 schema below in real requirement
      IDs; they are currently stub bodies — `## Statement` +
      `## Rationale` only, no `related:` cross-links yet. Closing this
      item means filling out the remaining five sections per CLAUDE.md's
      schema and wiring `related.requirements` between DET001–DET006 and
      this plan/`dev_detect.md`. Left open; the schema work below does
      not require it to be closed first.)

**Layer 1 status: substantively complete.** Flags, exit-code semantics
(including the new `64`/usage carve-out), and sidecar structure are now
identical in shape on both scripts; the only remaining Layer 1 item is
the documentation audit above, which is bookkeeping, not a behavioural
gap.

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

### Component-key mapping (DET001–DET006)

Today the two `components` maps don't actually line up:

| Key today | `dev_detect.sh` source | `dev_detect.ps1` source | DET id |
|---|---|---|---|
| `cpu_model` | `detect_cpu` (whole-file diff only — not a separate component yet) | `cpu_model` check | DET001 |
| `memory_total_gb` | `detect_ram` (ditto) | `memory_total_gb` check | DET002 |
| `nic_model_counts` | `detect_pcie_ethernet` (PCIe NICs only; ditto) | `nic_model_counts` check (all NICs, not just PCIe) | DET003 |
| `usb_passmark_count` | `detect_usb` (ditto) | `usb_passmark_count` check — narrower than DET004: counts PassMark loopback plugs specifically, not "USB device model/count/speed" in general | DET004 |
| `storage_model_bus_counts` | `detect_storage` (ditto) | `storage_model_bus_counts` check | DET005 |
| *(none)* | `detect_pcie_gpu` (bash-only, no DET id) | *(none)* | — (Layer 3 extra, not core) |
| *(none)* | PCIe link speed/width shown as free text inside `detect_pcie_ethernet`/`detect_storage`, never compared | PCIe link speed/width shown as free text inside the NIC/storage tables, never compared | DET006 |

Decisions to close this gap, so the schema below has a fixed key set:

- Keep the five existing key names (`cpu_model`, `memory_total_gb`,
  `nic_model_counts`, `usb_passmark_count`, `storage_model_bus_counts`)
  rather than renaming — they're already shipped and tested on the
  PowerShell side. DET001–DET005's eventual frontmatter audit should
  cite these names, not the other way around.
- `usb_passmark_count` stays scoped to the PassMark-loopback-plug count
  (a `dev_detect.ps1`-specific capability per Layer 3 — there is no
  Linux equivalent fixture today). If general USB device model/speed
  reporting (the literal DET004 wording) needs its own golden check
  later, that is a new key (e.g. `usb_device_list`), not a rename of
  this one.
- DET006 (PCIe link speed/width) does **not** get its own top-level
  component. PCIe link state is a property *of* a NIC or storage
  device, not an independent inventory item, so it becomes per-device
  sub-fields inside `nic_model_counts` and `storage_model_bus_counts`
  (see `pcie_link` field below) instead of a sixth top-level key.
- `detect_pcie_gpu` has no DET id and no Windows counterpart. It stays
  bash-only free text for now (Layer 3 territory: OS-specific extra
  detail), not part of the common-core schema.

### Proposed `components` schema (draft — not yet implemented)

Replaces today's flat `{ "<name>": "<result_tag>" }` map with one
object per component carrying a per-field breakdown plus a rolled-up
result (precedence Fail > INIT > Pass, per the rule already in the
exit-codes section of `dev_detect.md`):

```json
"components": {
  "cpu_model": {
    "result": "Pass",
    "fields": {
      "model":           { "current": "Intel(R) Core(TM) Ultra 7", "golden": "Intel(R) Core(TM) Ultra 7", "result": "Pass" },
      "physical_cores":  { "current": 8,  "golden": 8,  "result": "Pass" },
      "threads":         { "current": 16, "golden": 16, "result": "Pass" }
    }
  },
  "memory_total_gb": {
    "result": "Pass",
    "fields": {
      "total_gb":       { "current": 32, "golden": 32, "result": "Pass" },
      "dimm_populated": { "current": 2,  "golden": 2,  "result": "Pass" }
    }
  },
  "nic_model_counts": {
    "result": "Pass",
    "fields": {
      "model_counts": { "current": {"I225-V": 1, "E610-XT4": 4}, "golden": {"I225-V": 1, "E610-XT4": 4}, "result": "Pass" },
      "pcie_link":    { "current": {"E610-XT4": "Gen4 x4"}, "golden": {"E610-XT4": "Gen4 x4"}, "result": "Pass" }
    }
  },
  "usb_passmark_count": {
    "result": "Pass",
    "fields": {
      "loopback_count": { "current": 4, "golden": 4, "result": "Pass" }
    }
  },
  "storage_model_bus_counts": {
    "result": "Pass",
    "fields": {
      "model_bus_counts": { "current": {"...": "..."}, "golden": {"...": "..."}, "result": "Pass" },
      "pcie_link":         { "current": {"...": "Gen4 x4"}, "golden": {"...": "Gen4 x4"}, "result": "Pass" }
    }
  }
}
```

Notes:

- `pcie_link` is only present for devices that are actually PCIe-attached
  (a USB NIC or SATA disk simply omits the key for that entry) — no
  fabricated data for OSes/devices that can't report it (Layer 3 rule).
- The top-level `result` for a component is the same Fail > INIT > Pass
  precedence rollup as the overall pass result, applied across that
  component's own fields.
- This is additive to the sidecar shape in `dev_detect.md`, not a
  breaking change to the four top-level required fields
  (`schema_version`, `session_id`, `k`/`m`, top-level `result`,
  `timestamp`) — only `components`' internal shape changes, and
  `schema_version` should bump (e.g. `"1.0"` → `"2.0"`) once
  implemented, since old consumers reading `components.<name>` as a
  bare string would break.
- Implementation order once this schema is confirmed: `dev_detect.ps1`
  first (it already computes per-field data internally for each check,
  it just discards it down to one scalar before golden comparison), then
  port the same per-field shape to `dev_detect.sh`'s six `detect_*`
  functions, then update both `test_dev_detect.*` harnesses to assert on
  `components.<name>.fields.<field>.result` instead of the top-level tag
  alone.

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
