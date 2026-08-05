---
id: BUG0050
status: resolved
created: 2026-08-05
closed: 2026-08-05
os: [Ubuntu 24.04 LTS]
related_requirements: [FWK038, NET017]
related_bugs: [BUG0049]
---

# BUG0050 — the progress bar stopped while the step it was covering kept running

## Symptom

Found by audit against FWK038 after BUG0049, in the same run the operator
reported as "looks frozen".

`_iperf3_progress` counted to the transfer's **nominal** duration
(`_iperf_time`, 60 s by default), cleared itself, and exited. But the iperf3
client it was covering had not necessarily finished: a client that cannot reach
its server blocks on the TCP connect timeout — around two minutes — with
`--time` never coming into play, because no transfer ever starts.

The caller then did:

```bash
_iperf3_progress "${label}" "${_iperf_time}" &
_pp=$!
… iperf3 client …
wait "${_pp}" 2>/dev/null || true
```

so the sequence on a failing link was: bar runs 60 s → bar clears → **console
silent for ~67 s** → iperf3 gives up → retry. Three attempts per direction,
four directions, at every speed tier.

That silence is indistinguishable from a hang. It is exactly the window the
operator was looking at when they concluded the program was waiting for input.

## Root cause

The indicator was written as a **countdown of expected time** rather than as
**evidence of continued execution**. `while (( elapsed < total ))` treats the
nominal duration as a bound on the step, which it is not — it is a prediction,
and the interesting case is precisely when the prediction is wrong.

BUG0049 fixed a different mechanism destroying the same display (the `wall`
broadcast). Both had to be fixed for the console to be trustworthy; fixing only
the broadcast would have left this gap, which is longer.

## Fix

`_iperf3_progress` no longer stops at `total`. Past the nominal duration it
keeps redrawing once a second with the elapsed figure still climbing and an
explicit `(still running)` marker, so a slow step is never mistaken for a dead
one:

```
  [########################################]  87s /  60s  P0 TCP Fwd enp12s0->enp12s2 @10M  (still running)
```

Because it no longer self-terminates, `wait` on it would block until the
backstop. Both call sites now use a new `_progress_stop`, which kills it and
clears the line. A hard ceiling of `total * 5 + 600` seconds remains as a
backstop so an indicator orphaned by a killed worker cannot spin forever.

## Verification

`src/bash-shell/test_broadcast_tty.sh` — a step with a nominal duration of 3 s
driven for 6 s produces frames past the 3 s mark; those frames carry
`(still running)` and a rising elapsed count; `_progress_stop` terminates the
background job and leaves no residue on the line.

```bash
./src/bash-shell/test_broadcast_tty.sh
```

## Note

Like BUG0049, this changed nothing about measurement — only about whether the
operator can tell a slow run from a hung one. The practical stake is that the
reasonable response to a suspected hang is to kill the run, which on a
multi-hour endurance test destroys the results.
