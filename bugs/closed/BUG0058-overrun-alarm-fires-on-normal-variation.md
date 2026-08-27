---
id: BUG0058
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [FWK038, NET007]
related_bugs: [BUG0050, BUG0053]
---

# BUG0058 — the overrun alarm fired on ordinary variation, not on trouble

## Symptom

Reported by the operator mid-run:

```
  [########################################]  88s /  68s  P0 UDP Rev  ens18f0np0<-ens18f1np1 @400000M  (still running)
```

68 s is the estimate BUG0053 introduced (`--time` 60 + `--omit` 3 + 5 s
setup allowance). The step took 88 s, and `(still running)` was raised — as it
would be for any step even one second past the estimate.

## Root cause

BUG0053 fixed the **estimate** but left the **alarm** keyed to it. The two are
different questions and were sharing one number:

- *How far along is this step?* — needs a best-effort estimate. It will
  sometimes be wrong; that is what an estimate is.
- *Is something wrong with this step?* — needs a threshold set past the range of
  normal variation.

Tying the second to the first means every imperfection in the estimate becomes
an alarm. And the estimate cannot be made perfect: UDP teardown at 400G is
legitimately ~20 s slower than any fixed allowance predicts, because the
receiver reports statistics for tens of millions of datagrams.

This is the third iteration of the same underlying mistake. BUG0050 had the bar
stop at the estimate; BUG0053 had it alarm at the estimate; both treated a
prediction as a boundary.

## Fix

Separate the two thresholds.

The bar's denominator stays the estimate, and past it the display simply reads
`88s / 68s` — which already tells the operator the step is slower than
predicted, without asserting anything is wrong.

`(still running)` now waits for `_net_iperf_overrun_grace_sec` (config.sh,
default 30) beyond the estimate. That is above the worst legitimate overrun
observed (~20 s) and well below a TCP connect timeout (~2 min), which is the
case the marker exists to catch.

## Verification

`src/bash-shell/test_broadcast_tty.sh` — a step inside the grace window keeps
ticking with no marker; past it the marker appears; and the alarm threshold is
confirmed to be a distinct expression in source rather than the denominator
reused. The BUG0050 cases still assert the bar itself never stops.
