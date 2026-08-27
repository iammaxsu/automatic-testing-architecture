---
id: BUG0051
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [NET004, NET015, NET009]
related_bugs: [BUG0052]
---

# BUG0051 — ethtool lane count was parsed as part of the link speed

## Symptom

Report `net_report_20260811T120354.html`, a 400G NIC pair. Nine speeds were
tested, six of them nonexistent:

| Speed tested | Real mode | What happened |
|---|---|---|
| 25000 | `25000baseCR/Full` | correct |
| 50000 | `50000baseCR/Full` | correct |
| 100000 | `100000baseCR/Full` | correct |
| **500002** | `50000baseCR**2**/Full` | 50 G re-tested as a 500 Tb/s link |
| **1000002** | `100000baseCR**2**/Full` | duplicate of 100 G |
| **1000004** | `100000baseCR**4**/Full` | duplicate of 100 G |
| **2000002** | `200000baseCR**2**/Full` | 200 G never tested at 200000 |
| **2000004** | `200000baseCR**4**/Full` | duplicate |
| **4000004** | `400000baseCR**4**/Full` | 400 G never tested at 400000 |

Consequences beyond the wasted hour of bench time:

- **200 G and 400 G were never actually tested.** This NIC offers them only at
  CR2/CR4 lane widths, so both real speeds were absent from the run entirely.
- **Every row failed for the wrong reason.** NET009 derives the TCP threshold
  from the configured speed, so a 400 G link was judged against
  `95% of 4000004 Mbps = 3.8e+06 Mbps` — a target three orders of magnitude
  above anything the hardware can do. The report's own reason strings say so:
  `TCP fwd 79500M < 3.8e+06M threshold`.
- The verdict `FAIL` for the whole session was therefore meaningless.

## Root cause

```bash
ethtool "${ev}" | tr ' ' '\n' | grep '/Full' | sed 's/[^0-9]//g' | sort -n | uniq
```

`ethtool` names a link mode as `<speed>base<medium><lanes>`. `sed 's/[^0-9]//g'`
deletes every non-digit, which concatenates the speed with the lane count:
`100000baseCR4` → `1000004`. Modes with no lane suffix (`25000baseCR`) survived
by luck, which is why three of the nine speeds were right and hid the rest.

`sort -n | uniq` then could not collapse the duplicates, because after the
mangling they were no longer equal.

## Fix

Extract the digits that precede `base`, as a named, testable helper:

```bash
_supported_speeds() {
  local ns="$1" ifn="$2"
  echo "${_pwd}" | sudo -S ip netns exec "${ns}" ethtool "${ifn}" 2>/dev/null \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+base[^/]*/Full$' \
    | sed -E 's/^([0-9]+)base.*$/\1/' \
    | sort -n -u
}
```

The anchored pattern also drops half-duplex modes and any stray token that is
not a link mode. `sort -n -u` collapses a speed offered at several lane widths
into one test.

On the reported DUT this yields exactly `25000 50000 100000 200000 400000`.

## Verification

`src/bash-shell/test_net_speed_parse.sh`, driving the real helper against the
reported DUT's captured `ethtool` output: the lane count is not concatenated;
none of `500002` / `1000004` / `4000004` appears; a speed offered at several
lane widths is tested once; 200000 and 400000 — offered only as CR2/CR4 — are
present; a plain copper NIC still parses to `10 100 1000 2500` with half-duplex
modes excluded; an unreadable NIC yields an empty list so the caller's default
applies; and the old expression is gone from live code.

```bash
./src/bash-shell/test_net_speed_parse.sh
```
