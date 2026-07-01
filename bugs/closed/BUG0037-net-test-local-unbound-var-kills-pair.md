---
id: BUG0037
status: resolved
created: 2026-07-01
closed: 2026-07-01
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [NET016, FWK011, NET006]
related_bugs: []
---

# BUG0037 — `net_test.sh` pair worker aborts before iperf3 (`local` + `set -u`)

## Symptom

Every `net_test.sh` pair produced NO iperf3 throughput results. The pair ran the
IPv4/IPv6 ICMP pings (which passed) and then vanished: no `iPerf3_*.log` files
were created, the pair was missing from `net_summary`, and the HTML report showed
the pair as `NOT_TESTED` (later `ERROR`) with the whole run ~12 s instead of the
minutes iperf3 needs. Reproduced across multiple DUTs and NIC types (onboard
Intel `enp*`, USB `enx*`, multi-port `enp181s0f*`).

Once the ERR-trap diagnostic (v00.00.17) was added, the exact failing command
surfaced:

```
[Pair 0] ERROR — worker aborted (exit 1) at line 601:
_err_before_ev="$(_nic_err_snapshot "ns_${ev}" "${ev}" || true)"
```

with the underlying shell error:

```
ifn: unbound variable
```

## Root cause

`_nic_err_snapshot()` (NET016 error-counter snapshot) began with:

```bash
local ns="$1" ifn="$2" b="/sys/class/net/${ifn}/statistics" v
```

In a single `local` (or `declare`) statement, the shell expands ALL the
right-hand sides while building the builtin's argument list, **before** any of
the assignments take effect. So `${ifn}` in `b="…/${ifn}/…"` is expanded while
`ifn` is still unset. The script runs under `set -Eeuo pipefail`; with `set -u`
(nounset) that unset reference is a fatal "unbound variable" error, which fires
the `ERR` trap and kills the pair worker.

Crucially the `|| true` guard did **not** help: the failure is a `set -u` fatal
error raised while expanding the command-substitution arguments, and with
`set -E` (errtrace) the `ERR` trap fires regardless of the outer `|| true`.

Because the NET016 snapshot runs immediately after the pings and before the
iperf3 server is started, the worker died there every time — which is why no
iperf3 log was ever created and the pings' own result (written only at the end
of the speed iteration) was lost too.

The default `_net_err_counter_check=1` means this hit every run.

A second, latent instance of the same pattern existed in
`function.sh:__move_back_to_root`:

```bash
local ifn="$(__sanitize_if "$1")" ns="ns_${ifn}"
```

It only triggers when `netns_del` has leftover `ns_*` namespaces to clean, so it
had not yet been observed, but it would fail identically under `set -u`.

## Fix

Split each offending declaration so the referenced variable is assigned in its
own statement first:

```bash
# _nic_err_snapshot
local ns="$1" ifn="$2"
local b="/sys/class/net/${ifn}/statistics" v

# __move_back_to_root
local ifn; ifn="$(__sanitize_if "$1")"
local ns="ns_${ifn}"
```

Also retained from v00.00.17: the `_pair_abort` ERR trap that records a failing
pair as `ERROR` (with the failing line + command) into `result.json` and the
summary, so any future silent death is visible rather than a vanished pair.

## Verification

Reproduced the abort and confirmed the fix in isolation:

- The original single-`local` form under `set -Eeuo pipefail` raises
  `ifn: unbound variable` and fires the ERR trap even with `… || true`.
- The split form returns `0 0 0 0` and exits 0 with no trap.

On hardware: re-run `sudo ./net_test.sh`; expect the pairs to proceed past the
NET016 snapshot into the iperf3 TCP/UDP runs and produce throughput numbers and
a PASS/FAIL verdict (not ERROR/NOT_TESTED).
