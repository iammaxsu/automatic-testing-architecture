---
id: BUG0061
status: resolved
created: 2026-08-12
closed: 2026-08-12
os: [Ubuntu 24.04 LTS]
related_requirements: [NET009, NET007, NET018]
related_bugs: [BUG0051]
---

# BUG0061 — the TCP pass threshold was above the physical maximum

## Symptom

Session `20260812T132556`, with every earlier defect fixed and parallel streams
enabled. Every speed still failed, by a strikingly consistent margin:

| Speed | Measured | Threshold (95%) | Measured / line rate |
|---|---|---|---|
| 25000 | 23500 | 23750 | **94.0 %** |
| 50000 | 47100 | 47500 | **94.2 %** |
| 100000 | 94200 | 95000 | **94.2 %** |
| 200000 | 182000 | 190000 | 91.0 % |

Three speeds landing within 0.2 percentage points of each other is not a
hardware characteristic. It is a ceiling.

## Root cause

The threshold compared iperf3's number against the nominal **link speed**, but
the two measure different things:

- **link speed** is the wire rate — every bit the PHY transmits;
- **iperf3 reports goodput** — TCP payload only.

Everything between them is invisible to goodput and unavoidable on the wire:

| Per frame | Bytes |
|---|---|
| Preamble + SFD | 8 |
| Ethernet header | 14 |
| FCS | 4 |
| Inter-frame gap | 12 |
| IP header | 20 |
| TCP header | 20 |
| TCP timestamps (Linux default) | 12 |

At MTU 1500 a frame occupies `1500 + 38 = 1538` bytes of wire to carry
`1500 - 52 = 1448` bytes of payload:

```
1448 / 1538 = 94.15 %
```

**The maximum achievable is 94.15 % of line rate, and the threshold asked for
95 %.** No hardware could ever have passed at MTU 1500. The measured 94.0-94.2 %
is 99.8-100.1 % of what the wire physically allows — these NICs were performing
at the limit and being reported as failures.

The defect was masked for as long as the framework had larger problems. Only
once BUG0051 (nonsense speeds), BUG0056 (link never up) and BUG0060 (ARP loss)
were fixed, and parallel streams removed the single-stream CPU ceiling, did the
measurements get close enough to the wire limit for the threshold itself to
become the binding constraint.

## Fix

The threshold is now a percentage of **achievable goodput**, not of line rate:

```bash
_goodput_efficiency() {   # (mtu - l3l4) / (mtu + framing)
  awk -v m="${mtu}" -v o="${_net_frame_overhead_bytes:-38}" \
      -v h="${_net_l3l4_overhead_bytes:-52}" \
      'BEGIN{ if (m <= h) { print "1.0000"; exit } printf "%.4f", (m - h) / (m + o) }'
}
threshold = link_speed × efficiency × pct / 100
```

`95 %` now means "95 % of what this link can physically deliver", which is a
meaningful engineering target instead of an impossible one. The overhead terms
are configurable, since the L3/L4 figure depends on the OS's default TCP options.

Effect on the reported measurements:

| Speed | Measured | Old threshold | New threshold | Verdict |
|---|---|---|---|---|
| 25000 | 23500 | 23750 | 22361 | PASS |
| 50000 | 47100 | 47500 | 44721 | PASS |
| 100000 | 94200 | 95000 | 89442 | PASS |
| 200000 | 182000 | 190000 | 178885 | PASS |

An underperforming link still fails: 20000 on a 25G link, 60000 on 100G, and
150000 on 200G all remain FAIL.

The reason string now names the ceiling it used, so the number cannot look
arbitrary:

```
TCP fwd 23500M and rev 23500M both >= 22361M
  (95% of the 0.9415 goodput ceiling on 25000M at MTU 1500)
```

## Verification

`src/bash-shell/test_net_threshold.sh` — the MTU 1500 ceiling is 0.9415 and the
MTU 9000 ceiling is 0.9900; an MTU below the header size degrades to 1.0 rather
than going negative; all four reported measurements pass; **the previous formula
is shown to have failed all four**, so the fix is not cosmetic; genuinely slow
links still fail; and the threshold is confirmed never to exceed the ceiling at
any speed from 1G to 400G.

## Note

This also explains why NET018's jumbo-frame test matters beyond MTU support: at
MTU 9000 the ceiling rises to 99.00 %, because the same 38 bytes of framing are
amortised over six times the payload.
