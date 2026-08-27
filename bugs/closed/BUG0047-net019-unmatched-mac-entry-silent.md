---
id: BUG0047
status: resolved
created: 2026-08-05
closed: 2026-08-05
os: [Ubuntu 24.04 LTS]
related_requirements: [NET019, NET012, FWK029]
related_bugs: []
---

# BUG0047 — a NET019 MAC-list entry that matches nothing was never reported

## Symptom

`net_test.sh` aborted on a DUT with four NICs and a two-entry whitelist:

```
: "${_net_include_macs:=C4-12-F5-30-B4-48,C4-12-F5-30-B4-CF}"
```

```
[INFO] NIC 'enp12s2' (c4:12:f5:30:b5:cf) not in _net_include_macs (NET019) — will not be tested.
[INFO] NIC 'enp45s0' (00:30:64:7f:95:02) not in _net_include_macs (NET019) — will not be tested.
[INFO] NIC 'enp48s0' (00:30:64:7f:95:03) not in _net_include_macs (NET019) — will not be tested.
[DEBUG] After MAC filter (NET019): enp12s0
[FATAL] Need at least 2 testable NICs; found 1 after filtering.
```

The second whitelist entry was a typo: `…B4-CF` where the NIC is `…b5:cf` —
one character, in the fifth octet.

Nothing in the output said so. The operator was shown three rejected NICs and
the whitelist, and had to compare four MAC addresses against two entries by eye
to find a single wrong hex digit. The two NICs on the card differ only in their
last two octets (`b4:48` / `b5:cf`), which makes the mistake particularly easy
to make and particularly hard to see.

## Root cause

The filter reported only what it **rejected**, never that a list entry had
matched **nothing**. Those are different facts: "this NIC is not in your list"
is expected and usually benign, while "your list names something that does not
exist here" is almost always a typo.

The second failure mode is worse than the observed one. Had the DUT carried one
more matching NIC, the run would have found its two testable NICs and proceeded
— **testing a different pair than the operator asked for, with no warning at
all**. The abort here was luck, not a safety net.

## Fix

`__mac_report_unmatched()` in `function.sh`: after the MAC filter, every entry
in `_net_include_macs` / `_net_exclude_macs` that matches no NIC present on the
machine is named, with the nearest MAC that is actually there:

```
[WARN] _net_include_macs (whitelist) entry 'c4:12:f5:30:b4:cf' matches no NIC on this machine.
       Closest unclaimed NIC: enp12s2 (c4:12:f5:30:b5:cf) — differs in 1 octet(s). Typo?
```

Three details that make the suggestion trustworthy rather than noise:

1. **Claimed NICs are excluded from the suggestion.** Both `…b4:48` and
   `…b5:cf` are one octet from the typo `…b4:cf`. The first is already matched
   by the whitelist's other entry, so it cannot be what this entry meant;
   without that filter the tie broke arbitrarily and pointed at the NIC that
   already worked.
2. **A genuine tie lists every candidate** instead of guessing.
3. **No suggestion beyond two differing octets** — the nearest of several
   unrelated MACs is not a hint.

It warns unconditionally, not only when the run is about to abort, so the
silent wrong-pair case is covered too.

## Verification

`src/bash-shell/test_net_mac_filter.sh` — seven cases against a faked
`/sys/class/net` reproducing the reported DUT's four NICs: the typo is named;
the suggestion skips the already-claimed NIC; a correct list is silent; mixed
separators and case normalise; an unrelated MAC gets no bogus suggestion; a
genuine tie lists all candidates; an empty list is a no-op.

```bash
./src/bash-shell/test_net_mac_filter.sh
```

## Note

The framework behaved correctly in the reported run — it tested exactly the
NICs it was told to and refused to continue with one. This bug is about the
diagnostic, not the filtering.
