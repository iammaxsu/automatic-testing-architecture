---
id: BUG0056
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [NET004, NET015, NET008]
related_bugs: [BUG0051]
---

# BUG0056 — a speed change was followed by a blind sleep, never a link check

## Symptom

In session `20260811T141916` on a 400G pair, four of five speeds reported:

```
"v4": "FAIL", "v6": "FAIL", "tf": 0, "tr": 0, "uf": 0, "ur": 0
"reason": "FAIL: IPv4 ICMP FAIL; IPv6 ICMP FAIL  [jumbo MTU 9000: FAIL]"
```

Zero throughput and both ICMP families failing is not a throughput result — it
is a link that never came up. But the report named ICMP, three layers above the
cause, and an unsupported speed was indistinguishable from a broken cable.

## Root cause

```bash
_set_speed "ns_${ev}" "${ev}" "${_netspd}"
_set_speed "ns_${od}" "${od}" "${_netspd}"
sleep 4
```

`ethtool -s` returns as soon as the driver accepts the request. Bringing the
link up is asynchronous, and on a high-speed DAC link with RS-FEC it can take
far longer than four seconds. Nothing then checked whether carrier had appeared,
or whether it had appeared at the requested speed, so every probe that followed
inherited a down link and reported its own symptom.

## Fix

`_wait_link_up` polls `ethtool` until `Link detected: yes`, up to
`_net_link_up_timeout_sec` (config.sh, default 30), and compares the negotiated
speed with the requested one. Three outcomes:

| Outcome | Meaning |
|---|---|
| 0 | carrier up at the requested speed |
| 1 | no carrier within the timeout — the NIC or cable may not support this speed |
| 2 | carrier up, but at a different speed than requested |

When the link did not come up as asked, the speed's reason now **leads** with
that, ahead of the ICMP failure it causes:

```
LINK: link did not come up at 25000M within 30s (ens18f0np0=down, ens18f1np1=down)
      -- the NIC/cable may not support this speed  |  FAIL: IPv4 ICMP FAIL; …
```

Outcome 2 is reported rather than treated as a fault: the link works, but the
row cannot honestly be judged against the speed it claims to be testing.

## Verification

`src/bash-shell/test_net_error_trap.sh` — the call sites wait for carrier and
the fixed `sleep 4` is gone from the source.

Full confirmation needs the DUT: a speed the cable cannot carry should now be
reported as a link failure naming the speed, not as an ICMP failure.
