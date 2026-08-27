---
id: BUG0060
status: resolved
created: 2026-08-12
closed: 2026-08-12
os: [Ubuntu 24.04 LTS]
related_requirements: [NET001, NET002, NET008]
related_bugs: [BUG0056]
---

# BUG0060 — the first ping after a speed change was lost to address resolution, failing a healthy link

## Symptom

Session `20260812T101233`. At every speed except the first, IPv4 failed while
IPv6 passed on the same link, moments apart:

| Speed | IPv4 | IPv6 | TCP measured immediately after |
|---|---|---|---|
| 25000 | PASS | PASS | 23.5 / 23.2 Gbit/s |
| 50000 | **FAIL** | PASS | 44.8 / 44.0 Gbit/s |
| 100000 | **FAIL** | PASS | 76.9 / 79.8 Gbit/s |
| 200000 | **FAIL** | PASS | 70.6 / 73.3 Gbit/s |

The ping output shows precisely what was lost:

```
PING 192.247.0.11 (192.247.0.11) 56(84) bytes of data.
64 bytes from 192.247.0.11: icmp_seq=2 ttl=64 time=0.366 ms
64 bytes from 192.247.0.11: icmp_seq=3 ttl=64 time=0.389 ms
64 bytes from 192.247.0.11: icmp_seq=4 ttl=64 time=0.325 ms
--- 192.247.0.11 ping statistics ---
4 packets transmitted, 3 received, 25% packet loss
```

`icmp_seq=1` and only `icmp_seq=1`, at every affected speed. The other three
arrive in a third of a millisecond, and tens of gigabits flow over the same link
seconds later.

## Root cause

Changing link speed drops carrier, which clears the peer's ARP/ND entry. The
first packet afterwards is consumed resolving the address, and `ping` counts it
as lost. `_ping_check` requires `" 0% packet loss"`, so 3-of-4 scored FAIL.

The IPv4/IPv6 asymmetry made it look like an IPv4-specific fault and is an
artefact of ordering: IPv4 runs first and pays for resolution; by the time IPv6
runs, the neighbour is already resolved.

It did not appear at 25000 because that is the first speed tested, where the
addresses were configured during namespace setup and the entry was already
present.

This is adjacent to BUG0056 but not the same. That fix made the framework wait
for **carrier**, which it now does correctly — the link really was up. What was
missing is that a freshly-up link has an empty neighbour cache, and the first
packet pays for it.

## Fix

Send one discarded packet before measuring:

```bash
local _png="ping"; [[ "$v6" == "1" ]] && _png="ping6 -6"
… ip netns exec "${ns}" ${_png} -c 1 -W 2 "${addr}" >/dev/null 2>&1 || true
```

The priming packet is not logged and does not enter the verdict. The measured
run is unchanged: four packets, requiring 0% loss.

This measures **steady-state reachability**, which is what the check is for.
Address resolution is a one-off cost of a link coming up, not a property of the
link, and folding it into a loss percentage measured over four packets turns a
single unavoidable event into a 25% failure.

Both families are primed with the same family-selected command, so the ordering
asymmetry cannot reappear on whichever runs first.

## Verification

`src/bash-shell/test_net_error_trap.sh` — a discarded priming packet precedes
the measurement; only the 4-packet run is logged and judged; priming and
measurement use the same family-selected command; and the reported
`4 transmitted, 3 received` line is confirmed to fail a `0% packet loss` check,
which is the mechanism being removed.

Full confirmation needs the DUT: IPv4 should now pass at 50000, 100000 and
200000, where the link demonstrably carried 44-80 Gbit/s of TCP.
