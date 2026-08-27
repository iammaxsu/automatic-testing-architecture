---
id: BUG0052
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [NET015]
related_bugs: [BUG0051]
---

# BUG0052 — the pair's max link speed was reported as 0 on every run

## Symptom

The report's `Max` column, documented as "pair's max link speed (NET015)", read
`0M` for every row of every pair. `result.json` agreed: `"pair_max_mbps": 0`,
while the per-NIC `even_max_mbps` / `odd_max_mbps` beside it were populated.

## Root cause

```bash
if echo " ${_odd_speed_list} " | grep -q " ${_sp} " && (( _sp > _pair_max_mbps )); then
```

The intent is "is this speed also in the other NIC's list", padding with spaces
so a match cannot land mid-number. But `_odd_speed_list` comes from
`sort -n | uniq` and is **newline**-separated, not space-separated. `grep` works
a line at a time, so the padded string yields lines `" 25000"`, `"50000"`, …,
`"400000 "` — the first has no trailing space, the last no leading space, and
the middle entries have neither. No value could ever match, so the loop never
assigned and `_pair_max_mbps` kept its initial `0`.

The per-NIC maxima were computed by a plain numeric comparison in a `for` loop,
which word-splits on any whitespace including newlines — hence they worked, and
the failure looked like it was specific to the "pair" concept rather than to the
membership test.

## Fix

```bash
if grep -qxF -- "${_sp}" <<<"${_odd_speed_list}" && (( _sp > _pair_max_mbps )); then
```

`-x` anchors to the whole line, which is what the space padding was reaching
for, and works on the newline-separated list as it actually exists. `-F` because
a speed is a literal, not a pattern.

## Verification

`src/bash-shell/test_net_speed_parse.sh`: over a newline-separated list the
membership test now yields the highest speed both NICs support; an asymmetric
pair (400G against 50G) correctly yields the highest **common** speed rather
than either NIC's own maximum; and the previous space-delimited form is
exercised alongside to confirm it matches nothing, so the test is not vacuous.

## Note

`Max` and `Speed` are different quantities and the report now says so: `Max` is
the highest speed both NICs of the pair support, fixed for the pair; `Speed` is
the link speed each row was configured to and measured at.
