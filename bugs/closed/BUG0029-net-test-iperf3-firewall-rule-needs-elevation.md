---
id: BUG0029
status: resolved
created: 2026-06-11
os:
  - Windows 11
related_requirements: [NET006, NET008, NET009]
related_bugs: []
---

# BUG0029 — `net_test.ps1` iperf3 results are silently 0 Mbps when not run elevated

## Symptom

A `net_test.ps1 v00.00.17` run on `DESKTOP-QNQPTQS`
(`net_test_20260611T112401.*`) produced, for every advertised speed (100M and
1000M) and all four iperf3 combinations (TCP fwd/rev, UDP fwd/rev): `0 Mbps`,
verdict `UNKNOWN`, and per-run iperf3 logs all reading:

```
iperf3: error - unable to connect to server - server may have stopped
running or use a different port, firewall issue, etc.: Connection timed out
```

IPv4 and IPv6 ICMP both `PASS` at every speed. The main log
(`net_test_20260611T112401.log`) contains no mention of the firewall rule at
all — `New-NetFirewallRule`'s success/failure is only ever written via
`Write-Host` / `Write-Warning`, which do not appear in any log file.

Re-running the identical command as Administrator
(`net_test_20260611T114937.*`) on the same DUT produced real throughput
numbers at both speeds (100M: ~94–96 Mbps; 1000M: 757–957 Mbps), confirming
the cause was the elevation requirement of `New-NetFirewallRule`
(`net_test.ps1:952`), not the link or iperf3 itself.

## Root cause

1. `New-NetFirewallRule` requires an elevated (Administrator) process token.
   When `net_test.ps1` is run from a non-elevated shell, the call throws,
   the `catch` block (`net_test.ps1:956-957`) emits only a `Write-Warning`,
   and the script continues with **no inbound allow rule for iperf3**.
2. ICMP (ping) is unaffected by this missing rule, so connectivity checks
   pass while every iperf3 socket is silently dropped — "Connection timed
   out", not "refused", because the server side is reachable but its inbound
   traffic never arrives.
3. Because the firewall rule status is only logged via `Write-Host` /
   `Write-Warning` (console-only), the resulting `result.json` /
   `net_test_<ts>.log` give no indication of *why* every speed shows 0 Mbps —
   the operator cannot distinguish "firewall blocked everything" from "the
   link is genuinely too slow to reach the threshold" without re-running
   interactively and watching the console.

## Fix

`net_test.ps1` v00.00.18:

1. Add a second, port-based inbound allow rule (TCP+UDP 5201, `Profile Any`)
   alongside the existing program-scoped rule, since either can fail
   independently (e.g. a `Get-Command iperf3` resolution mismatch with the
   binary actually launched).
2. Record both rules' add/fail status via `Write-MainLog` (so it lands in
   `net_test_<ts>.log`) and in a new `diagnostics` block in `result.json`:
   `firewall_program_rule_added`, `firewall_port_rule_added`,
   `firewall_status`.
3. If neither rule could be added, emit a `Write-Warning` telling the
   operator to re-run as Administrator, and render a prominent banner in the
   HTML report explaining that the iperf3 results below are likely 0 Mbps due
   to the firewall, not link performance.
4. Both rules are removed on exit (existing cleanup pattern), scoped per run
   via `$_runTs`.

## Verification

- Run `net_test.ps1` from a non-elevated shell: `result.json.diagnostics`
  shows `firewall_status: "FAILED (not elevated?)"`, the main log contains a
  `[firewall] ... status=FAILED (not elevated?)` line, and the HTML report
  shows the firewall warning banner above the per-speed table.
- Run as Administrator: `firewall_program_rule_added` and
  `firewall_port_rule_added` are both `true`, `firewall_status: "added"`, no
  banner, and iperf3 throughput is measured normally (as in
  `net_test_20260611T114937.*`).
