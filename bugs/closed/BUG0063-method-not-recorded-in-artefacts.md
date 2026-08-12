---
id: BUG0063
status: resolved
created: 2026-08-12
closed: 2026-08-12
os: [Ubuntu 24.04 LTS]
related_requirements: [NET009, FWK028, LOG015]
related_bugs: [BUG0061]
---

# BUG0063 — the standard behind a verdict was not recorded with the verdict

## Symptom

A report stated `FAIL: TCP fwd 94200M < 95000M threshold` and nothing else. To
judge whether that verdict was correct a reader needed to know, from outside the
artefact:

- which framework version produced it, and what formula that version used;
- the MTU the throughput runs used;
- how many parallel streams were in force;
- whether UDP loss or NIC error counters were gating;
- whether any per-speed override applied.

None of it was in the report or in `result.json`. The threshold appeared as a
bare number with no derivation.

The cost was concrete: the threshold was **wrong** — above the physical ceiling
at every speed (BUG0061) — and nothing in any artefact made that checkable. It
took a hardware investigation, and several hours of bench time, to notice that
three speeds all landing at 94.0-94.2 % was a ceiling rather than a coincidence.

## Root cause

FWK028 was applied to the measurements but not to the **rule** that judged them.
`result.json` was canonical for "what was measured" and silent on "what it was
measured against".

A verdict is a claim of the form *measurement × rule → outcome*. Recording only
the measurement and the outcome makes the claim unverifiable and any later
dispute unresolvable, because the rule may have changed in between and nothing
says which one was applied.

## Fix

`result.json` gains `.details.method`, written by the run that produced the
verdicts:

```json
{ "requirement": "NET009",
  "tcp_threshold": {
    "formula": "threshold = link_speed x (mtu - l3l4_overhead) / (mtu + frame_overhead) x pct / 100",
    "mtu_bytes": 1500, "frame_overhead_bytes": 38, "l3l4_overhead_bytes": 52,
    "goodput_efficiency": 0.9415, "pass_pct": 95, "pass_pct_tiers": "",
    "note": "pct is a share of ACHIEVABLE goodput, not of line rate…" },
  "iperf_streams": { "setting": "auto", "auto_from_mbps": 25000, "auto_streams": 8,
    "note": "A single TCP stream is bounded by one core…" },
  "udp_loss": { "cap_pct": 1, "gates_verdict": false, "note": "…" },
  "nic_error_counters": { "gates_verdict": false } }
```

Every threshold in the report is reproducible from that record alone.

The HTML report renders a **Method and thresholds** section from it — never
hand-written, so the standard shown beside a verdict is by construction the one
that produced it. Each entry carries not just the value but why it holds: why
the threshold is not a share of line rate, why one percentage suffices at every
speed, why the stream count is part of the standard rather than a tuning
preference.

Each note is short enough to survive being read, and points at the requirement
for the full derivation.

## Verification

`src/bash-shell/test_net_method_record.sh` — every field needed to reconstruct a
verdict is present (checked without jq's `//`, which treats `false` as unset and
would have hidden the two gating booleans in their default state); the recorded
efficiency is the value the run actually computed rather than a restated
constant; a 100 G threshold is recomputed from the record alone and matches; the
report reads the efficiency from `result.json`; **the report does not hard-code
the ceiling**, since a stale constant beside a live verdict is precisely the
failure this is written against; and the stream policy resolves as documented.
