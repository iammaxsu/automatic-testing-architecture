---
id: BUG0053
status: resolved
created: 2026-08-11
closed: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [FWK038, NET007]
related_bugs: [BUG0050]
---

# BUG0053 — "(still running)" appeared on every transfer, so it stopped being a signal

## Symptom

Reported by the operator mid-run, at 400G:

```
  [########################################]  70s /  60s  P0 TCP Rev  ens18f0np0<-ens18f1np1 @400000M  (still running)
```

The `60s` denominator was reached on **every** transfer, and `(still running)`
appeared every time — including on completely healthy ones.

## Root cause

The progress bar was sized by `_net_iperf_time_sec`, passed straight through as
iperf3's `--time`:

```bash
_iperf3_progress "${label}" "${_iperf_time}" &
```

`--time` governs the **measured transfer**, not the step's wall clock. The step
is longer by construction:

- `--omit 3` runs an additional warm-up period whose seconds `--time` does not
  count;
- each direction pays TCP connection setup and a closing statistics exchange,
  which at 400G is not instant.

So a healthy 60 s transfer occupies roughly 68 s of wall clock, and the bar —
told the step would take 60 — declared an overrun on all of them.

This defeats BUG0050's fix rather than exposing a new failure. `(still running)`
was added there to mark the **abnormal** case: an iperf3 client blocking on a
connect timeout far past `--time`, where the console would otherwise go silent
and look hung. A marker that fires on every step carries no information, and the
operator correctly read it as suspicious rather than as reassurance.

## Fix

Size the bar by what the step is expected to take on the wall clock:

```bash
local _iperf_wall=$(( _iperf_time + _iperf_omit + ${_net_iperf_overhead_sec:-5} ))
```

`_net_iperf_overhead_sec` (config.sh, default 5) is the setup/teardown
allowance. It is used **only** to size the display — it never bounds the
transfer, and `_iperf3_progress` still keeps ticking past the denominator, which
is the BUG0050 behaviour that must not regress.

With the defaults the bar now reads `.. / 68s` and reaches 100% about when a
healthy step ends, so `(still running)` again means "this one is unusual".

## Verification

`src/bash-shell/test_broadcast_tty.sh` — the denominator is computed as
`time + omit + overhead`; no call site still passes `--time`; and the
denominator exceeds `time + omit`, leaving headroom for setup. The existing
BUG0050 cases still assert the bar ticks past its denominator and marks the
overrun, so the fix cannot be "simplified" into stopping at it.

## Note

`60s` was never wrong as a number — it was the right value for the wrong
quantity. The bar's denominator is a claim about how long the step should take,
and `--time` is only one component of that.
