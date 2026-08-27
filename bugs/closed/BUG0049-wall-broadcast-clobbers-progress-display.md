---
id: BUG0049
status: resolved
created: 2026-08-05
closed: 2026-08-05
os: [Ubuntu 24.04 LTS]
related_requirements: [FWK032, NET017, LOG013]
related_bugs: [BUG0022, BUG0007]
---

# BUG0049 — the "test in progress" broadcast scrolled away the operator's own progress bar

## Symptom

Reported by the operator mid-run: after

```
[INFO] Pair 0 (enp12s0<->enp12s2) launched (PID 18285)
```

the console appeared to stop. It stayed that way for a long time; **pressing
Enter made it continue**, so it looked as though the script was blocked on
input.

It was not. The test ran throughout. The evidence is in the operator's own
paste:

```
                                        np12s2 @10M
  [##############                          ]  20s /  60s  P0 TCP Fwd  enp12s0->enp12s2 @10M
```

The bar reads `20s / 60s` — it was counting. And `np12s2 @10M` above it is the
unerased tail of a previous, longer redraw.

## Root cause

Two independent display defects, compounding.

### 1. `wall` writes to the operator's own terminal

`test_progress_set()` / `test_progress_clear()` broadcast the "TEST IN PROGRESS
— DO NOT POWER OFF" banner with:

```bash
echo "${msg}" | wall 2>/dev/null || true
```

`wall(1)` writes to **every** logged-in TTY, including the one running the test.
The banner is about ten lines, so it scrolled the console. `_iperf3_progress()`
then kept redrawing its bar with a bare `\r`, which returns to the start of
whatever line the cursor is now on — no longer the line the bar had been using.
The result is a display that stops changing while the test runs normally.
Pressing Enter scrolled the terminal and revealed the live bar, which is why the
keypress looked causal. It was not: nothing in the path reads stdin.

The message exists to stop **other** users powering the machine off mid-test.
The person who started the test does not need telling, and is precisely the one
whose display it destroys.

### 2. The progress bar never erased to end of line

```bash
printf "\r  [%-40s] %3ds / %3ds  %s" … "${label}"
```

`\r` repositions but erases nothing. A label shorter than its predecessor leaves
the difference on screen — the reported `np12s2 @10M` fragment, the tail of
`… enp12s0->enp12s2 @10M`. The final clear had the mirror problem: it blanked a
hard-coded 78 columns, which is both too much on a narrow terminal (the padding
wraps and eats another line) and too little on a wide one.

## Fix

`_adlink_broadcast()` replaces both `wall` calls: it writes to every terminal
`who(1)` lists **except** the invoking one.

The invoking TTY is captured once at source time, not inside the function.
By the time a broadcast runs it may be called from a background subshell with
redirected stdio, where `tty(1)` answers "not a tty" and the exclusion would
silently stop working. If no TTY can be determined at all — a cron or systemd
run — nothing is excluded, which is correct: there is no operator console to
protect.

The status file and the MOTD hook are untouched, so a user logging in during a
run still sees the warning.

`_iperf3_progress()` now appends `\033[K` (erase to end of line) to each redraw,
and clears with `\r\033[K` instead of padding to an assumed width.

## Verification

`src/bash-shell/test_broadcast_tty.sh` — eight cases:

- the invoking terminal receives nothing, while another terminal does
- with no TTY of our own, nothing is excluded
- no bare `wall(1)` call remains, and the TTY is captured at source time
- the bar and the final clear both use the erase sequence
- rendered directly: a long label followed by a short one leaves
  `enp12s2 @10M` behind without the erase, and cannot with it

```bash
./src/bash-shell/test_broadcast_tty.sh
```

Checked non-vacuous by reverting the source-time TTY capture, which fails the
corresponding case.

## Note

Nothing about the measurements changed. This was purely the console display of
a run that was proceeding correctly the whole time.
