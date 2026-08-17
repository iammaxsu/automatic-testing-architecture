# The Ethernet goodput ceiling

Background note for [`requirements/NET009.md`](../requirements/NET009.md), which
is the normative source. This explains *why* the rule there has the shape it
has; where the two disagree, NET009 wins.

An interactive version with a per-MTU calculator is published as an artifact —
ask Max for the link.

---

## The distinction everything rests on

**iperf3 reports TCP payload. The link speed is wire rate.** Between them sits a
fixed, unavoidable cost that never appears in the payload figure.

## One frame at MTU 1500

| Item | Bytes | Where |
|---|---|---|
| Preamble + SFD | 8 | outside the MTU |
| Ethernet header | 14 | outside the MTU |
| IP header | 20 | inside the MTU |
| TCP header | 20 | inside the MTU |
| TCP options (timestamps) | 12 | inside the MTU |
| **TCP payload** | **1448** | inside the MTU |
| FCS | 4 | outside the MTU |
| Inter-frame gap | 12 | outside the MTU |
| **Total on the wire** | **1538** | |

```
1448 / 1538 = 94.15 %
```

The overhead falls into two groups, and that is where the formula's one-plus-one-minus
comes from:

- **38 bytes are added to the MTU** — preamble+SFD, Ethernet header, FCS, IFG
- **52 bytes are subtracted from inside it** — IP, TCP, TCP options

```
efficiency(MTU) = (MTU − 52) / (MTU + 38)
```

## The overhead is not negligible, it is per-frame

5.85 % looks small until it is priced in bandwidth. On a 1 Gb/s link:

```
frames per second = 1e9 / (1538 × 8)  = 81,274
spent on overhead = 81,274 × 90 × 8   = 58.5 Mb/s
left for payload                      = 941.5 Mb/s
```

941.5 Mb/s is the familiar "940 Mb/s" that gigabit NICs reach. It is the
**ceiling**, not a good score — and the old NET009 threshold of 95 % of line
rate sat above it, which is how BUG0061 went unnoticed for so long.

## The formula contains no speed term

The framing cost is the same *fraction* at 10 Mb/s and at 800 Gb/s. Once it is
modelled explicitly, a single pass percentage is correct at every link speed,
and a per-speed table has nothing left to correct for.

## MTU moves the ceiling; link speed does not

The same 90 bytes amortised over a larger payload:

| MTU | Payload | Wire | Overhead | Ceiling |
|---|---|---|---|---|
| 576 | 524 | 614 | 14.66 % | 85.34 % |
| **1500** | 1448 | 1538 | **5.85 %** | **94.15 %** |
| 2000 | 1948 | 2038 | 4.42 % | 95.58 % |
| 4000 | 3948 | 4038 | 2.23 % | 97.77 % |
| **9000** | 8948 | 9038 | **1.00 %** | **99.00 %** |
| 16000 | 15948 | 16038 | 0.56 % | 99.44 % |

On a 100 G link, moving from MTU 1500 to 9000 raises the achievable figure from
94,148 to 99,004 Mb/s — **4,856 Mb/s more, with no change to the hardware**.

Two consequences:

1. **The same number means opposite things at different MTUs.** 94 % at MTU 1500
   is perfection; 94 % at MTU 9000 is a five-point deficit. Reports taken at
   different MTUs are not comparable, which is why the MTU used is recorded in
   `result.json`.
2. **Jumbo frames make the test more sensitive.** With a 99 % ceiling, a real
   problem shows up as a real gap instead of hiding inside the framing cost.

## So how does a payload measurement judge the hardware?

Because **MTU is a controlled variable**. Both DUTs are measured at the same MTU,
so the ceiling is identical for both and cancels in the comparison. It sets how
many marks are available, not who scored what.

```
Ceiling at MTU 1500, timestamps off:  949.3 Mb/s

DUT A: 945 Mb/s = 94.5 % of line rate = 99.5 % of achievable  -> at the limit
DUT B: 850 Mb/s = 85.0 % of line rate = 89.5 % of achievable  -> 99 Mb/s missing
```

Those 99 Mb/s have nothing to do with MTU. Same cable, same MTU, same ceiling —
it is the DUT.

## Where a shortfall goes

The ceiling is physics, so falling short of it always has a cause, and the set of
causes is small. The framework already collects the evidence:

| Cause | Symptom in the report |
|---|---|
| Packet loss → TCP backs off | `retr` non-zero (NET017) |
| Physical-layer errors (CRC/FCS) | NIC error-counter delta (NET016) |
| Offloads disabled (TSO/GSO/GRO/checksum) | `retr` and errors both zero, throughput still low |
| Ring buffer too small → drops | rx_dropped rising |
| Interrupt handling / CPU bound | appears only at high speed |
| PCIe bandwidth or lane count | throughput caps at a fixed figure |
| Flow control / pause frames | periodic dips |

A report showing 850 Mb/s therefore does not just say "slow" — the neighbouring
columns say where to look.

## Two settings that change the ceiling

- **TCP timestamps.** Linux enables them by default, costing 12 bytes and giving
  a 94.15 % ceiling. With `net.ipv4.tcp_timestamps=0` the ceiling is 94.93 %.
  This is why `_net_l3l4_overhead_bytes` is configurable rather than a constant,
  and why two DUTs being compared should have the same setting.
- **Measurements slightly above the computed ceiling** are expected on NICs doing
  TSO/GRO; the model is deliberately conservative and is not an error.
