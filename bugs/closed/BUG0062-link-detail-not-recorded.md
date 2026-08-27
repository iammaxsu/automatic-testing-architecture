---
id: BUG0062
status: resolved
created: 2026-08-12
closed: 2026-08-12
os: [Ubuntu 24.04 LTS]
related_requirements: [NET015, NET004, FWK037, LOG015]
related_bugs: [BUG0056]
---

# BUG0062 — how a link actually negotiated was never recorded, only in dmesg

## Symptom

BUG0056 made the framework report correctly that 400G never came up:

```
LINK: link did not come up at 400000M within 30s (ens18f0np0=down, ens18f1np1=down)
      -- the NIC/cable may not support this speed
```

True, and not enough. "may not support this speed" cannot distinguish a NIC
limit from a bad cable, a missing FEC configuration, or a cage/module mismatch —
and the operator's next question is always which of those it is.

Answering it required `sudo dmesg`, which is not part of any artefact, needs
root, and is a ring buffer that ages out:

```
ens18f0np0: NIC Link is Up, 200000 Mbps (PAM4 56Gbps) full duplex
ens18f0np0: FEC autoneg off encoding: Clause 91 RS(544,514)
```

That one line settles it: 200G over 4 lanes is **50 Gbps per lane**, and
400GBASE-CR4 needs **100 Gbps per lane**. Same port, same cable — the limit is
the signalling rate, not a fault. None of that reached the report.

## Root cause

The framework recorded *whether* a link came up and at what nominal speed, but
none of the parameters that explain how: lane count and active FEC encoding.
Both are available through `ethtool` without root beyond what the test already
uses, and both were simply never read.

FWK037 already establishes that a result should be self-describing — "these
numbers were produced on THIS hardware". A link result is not self-describing
while the negotiated lane count and FEC are missing from it.

## Fix

`_link_detail` reads lane count and active FEC encoding for a NIC and returns
`lanes=<n> fec=<encoding>`, with `?` for anything unavailable.

It is recorded for every speed, whether the link came up or not:

```
[INFO] link up at 200000M -- ens18f0np0: lanes=4 fec=Clause 91 RS(544,514) | ens18f1np1: lanes=4 fec=…
```

A link-up failure additionally names **the highest speed that did establish this
run**, so "cannot do 400G" is separable from "cannot do anything" without
re-reading the log:

```
link did not come up at 400000M within 30s (…); highest speed established so
far this run: 200000. ens18f0np0: lanes=4 fec=Off | ens18f1np1: lanes=4 fec=Off
```

`_last_linked_spd` is declared local to the pair worker, so it cannot leak
between pairs and `set -u` always has something to read.

## Verification

`./src/bash-shell/test_shell_scope.sh` and the full bash suite pass. Field
confirmation needs the DUT: a run should now log lane count and FEC at each
speed that links, and name the last good speed when one does not.

## Note — what the evidence showed on the reported DUT

Broadcom `bnxt_en`, 2-port, ports connected back to back with a
QSFP-400G-AC01 (QSFP112, 400G) cable:

| Speed | Result | Signalling |
|---|---|---|
| 25000 | up | NRZ |
| 50000 | up | NRZ |
| 100000 | up | NRZ |
| 200000 | up | **PAM4 56 Gbps**, RS(544,514) |
| 400000 | **never links** | — |

200G established as 4 lanes of PAM4 at ~56 Gbps raw, i.e. 50 Gbps of data per
lane. 400GBASE-CR4 requires ~112 Gbps raw per lane. The port therefore tops out
at 200G on this signalling, and `400000baseCR4` appearing in the driver's
supported-modes list is an advertised capability the hardware cannot establish.

The cable is not the limiting factor: a QSFP112 400G cable carries 100G lanes,
and it is the NIC end that is running them at 50G.

This is a finding about the DUT, not a framework defect — the framework's job
was to make it visible, which is what this change does.
