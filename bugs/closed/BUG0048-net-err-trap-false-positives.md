---
id: BUG0048
status: resolved
created: 2026-08-05
closed: 2026-08-05
os: [Ubuntu 24.04 LTS]
related_requirements: [NET008, NET017, LOG015, FWK028]
related_bugs: [BUG0037, BUG0047]
---

# BUG0048 — ERR trap reported 32 phantom aborts and wrote 32 duplicate result records

## Symptom

Session `20260805T103640`. One pair, one iteration, one speed tier (10 Mbps).
The main log carried 32 lines of:

```
[Pair 0] ERROR — worker aborted (exit 1) at line 283: tail -n1
[Pair 0] ERROR — worker aborted (exit 1) at line 292: raw="$(_extract_rate "$f")"
```

and `result.json` carried **32 entries in `speeds[]`, every one of them
`speed_mbps: 10`**, for what was a single 10 Mbps iteration:

```json
"summary": { "total": 34, "passed": 0, "failed": 0, "unknown": 0, "skipped": 2, "error": 32 }
```

Two claims in that output are false:

1. **The worker never aborted.** After each "aborted" message it carried on —
   IPv4 ping, IPv6 ping, TCP reverse, TCP forward, UDP reverse, UDP forward,
   bidirectional — and finished the iteration.
2. **`total: 34` counts trap firings, not tests.** One pair × one speed ×
   one iteration is one test. 32 of the 34 were the same test recorded 32 times.

The genuine finding was buried underneath: the two NICs could not reach each
other at all.

```
4 packets transmitted, 0 received, 100% packet loss
iperf3: error - unable to connect to server … : Connection timed out
```

## Root cause

### Why the trap fired

`net_test.sh` runs under `set -Eeuo pipefail` with an `ERR` trap
(`_pair_abort`) whose stated purpose is to surface a failure that would
otherwise kill a pair worker silently. But it fired on commands that fail
**by design** and are handled on the following line:

| Line | Command | Why it exits non-zero | Where it is handled |
|---|---|---|---|
| 270, 273 | `ping … \| tee "$tmpf" >> "$logfile"` | `ping` exits 1 on 100% loss; `pipefail` propagates it | the next line: `grep -q " 0% packet loss" && echo PASS \|\| echo FAIL` |
| 283 | `printf … \| grep -oE '…bits/sec' \| tail -n1` | `grep` exits 1 when the iperf3 log has no rate line | `_extract_mbps_num`: `[[ -z "${raw}" ]] && { echo 0; return; }` |
| 292, 761 | `raw="$(_extract_rate "$f")"` | command substitution inherits the above | same line: `[[ -z … ]] && …="N/A"` |

A ping that loses every packet and an iperf3 client that cannot connect are
exactly what this test exists to detect. Treating their exit status as a
framework crash inverts that.

The three sibling extractors (`_extract_retr`, `_extract_udp_jitter`,
`_extract_udp_loss`) are `awk`-only and already exit 0 when they find nothing.
`_extract_rate` was the outlier because it uses `grep`.

### Why `trap - ERR` did not stop the repeats

`_pair_abort` disarms itself on entry. That looks sufficient and is not:

```bash
_pair_abort() {
  local _rc=$? …
  trap - ERR   # never recurse if a command below also fails
```

Most of these failures happen inside **command substitutions**. With `set -E`,
each substitution subshell inherits its own copy of the trap; disarming it there
affects only that subshell, which exits microseconds later, leaving the worker's
copy armed. Hence the firings arrive in pairs — line 283 inside `_extract_rate`'s
subshell, then line 292 in its caller's subshell — visible throughout the log.

### Why each firing produced a result record

`_pair_abort` appends a `speeds[]` entry on every invocation. 32 invocations →
32 records. Their `ipv4_ping` / `ipv6_ping` fields differ (`N/A` → `FAIL` →
`FAIL`) because each is a snapshot of the worker's variables at that instant,
not an independent measurement.

## Fix

1. **`_ping_check`** — `|| true` on both ping pipelines. The verdict comes from
   the captured output, never from ping's exit status.
2. **`_extract_rate`** — `|| true` on the `grep | tail` pipeline. No match is a
   valid answer, and every caller already handles the empty string.
3. **`_pair_abort` dedupes per (iteration, speed)** via a marker file beside the
   pair's tmp JSON. A marker file is the only state that survives a subshell, so
   the `trap - ERR` self-disarm cannot be made to work here. Markers are removed
   with the tmp JSON at merge time.
4. **The message no longer claims an abort** it cannot know happened:
   `unhandled command failure (exit N) at line L: CMD`.

The trap's original purpose is preserved: a genuinely unhandled failure still
produces one visible, diagnosable ERROR record per speed.

## Verification

`src/bash-shell/test_net_error_trap.sh` — seven cases driving the real
extractors under `set -Eeuo pipefail` with an announcing ERR trap, against a
captured iperf3 log from a link that never came up:

- a no-rate log does not trip the trap, and still yields `""` / `0 Mbps`
- a healthy log still parses to 936 Mbps
- a 100%-loss ping yields `FAIL` without tripping the trap
- the `|| true` guards, the dedupe, and the reworded message are still in source
  (each is one "tidy-up" away from silently regressing, and only shows on hardware)

```bash
./src/bash-shell/test_net_error_trap.sh
```

Checked non-vacuous: reverting the `_extract_rate` guard alone fails three
cases and reports `TRAP:6:r="$(_extract_rate …)"` — the reported symptom.

## Note for the operator

This bug was in the reporting, not in the measurement. The run's actual result
stands: **`enp12s0` and `enp12s2` could not exchange a single packet** — 100%
ICMP loss on both IPv4 and IPv6, and every iperf3 connection timed out, at the
lowest speed tier. That is a cabling or link-state problem between the two
ports, not a software fault. With this fix the same run reports one ERROR per
speed with that diagnosis, instead of 32 phantom aborts on top of it.
