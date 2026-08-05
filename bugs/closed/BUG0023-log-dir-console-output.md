---
id: BUG0023
status: resolved
created: 2026-05-14
closed: 2026-08-05
os:
  - Ubuntu 24.04 LTS
  - Ubuntu 26.04 LTS
related_requirements: [LOG001, FWK029]
related_bugs: []
---

# BUG0023 — log_dir() console output: stray path, duplicated announcement

## Symptom

As originally filed: two `echo "[INFO] …"` statements in `log_dir()` were
written on one physical line, so they printed as a single joined message.

That much was fixed in passing. Two further defects in the same function were
visible in a `net_test.sh` run on 2026-08-05 and are what this bug now covers:

```
[INFO] log dir: /home/adlink/Downloads/logs
[INFO] session log dir: /home/adlink/Downloads/logs/session_20260805T094807_3611
/home/adlink/Downloads/logs                    ← stray bare path
[DEBUG] counter_init: …
[INFO] log dir: /home/adlink/Downloads/logs    ← the whole block again
[INFO] session log dir: /home/adlink/Downloads/logs/session_20260805T094807_3611
/home/adlink/Downloads/logs
```

1. **A bare, untagged path on stdout.** Every other line the framework emits
   carries an `[INFO]` / `[DEBUG]` / `[WARN]` tag; this one did not, so it read
   like stray output from a command that had leaked through.
2. **The announcement printed twice**, making it look as though a second session
   had started between the two blocks.

## Root cause

**Stray path.** `log_dir()` ended with `printf '%s\n' "${_log_dir}"`, intended
as a return channel for `x=$(log_dir …)`. No caller ever used it — all five
(`config.sh:setup_session`, `net_test.sh`, `disk_test.sh`, `dev_detect.sh`,
`slp_test.sh`) call it bare and read the exported `${_log_dir}` /
`${_session_log_dir}`. The channel was also broken by construction: the two
`[INFO]` lines go to stdout as well, so a capturing caller would have received
three lines and produced a nonsense path.

**Duplicate announcement.** `net_test.sh` and `slp_test.sh` call `log_dir "" 1`
directly — they need `${_session_log_dir}` before `setup_session()` runs — and
`setup_session()` then calls `log_dir "" 1` again. The second call is a harmless
no-op for the paths themselves (they are set with `: "${var:=…}"`), but the
announcement was unconditional. `disk_test.sh` and `dev_detect.sh` call it once
and were unaffected.

## Fix

- The trailing `printf` is removed. `log_dir()` now prints nothing to stdout
  beyond its tagged messages, and a comment records why re-adding it would be
  wrong.
- The announcement is guarded by `_log_dir_announced`, holding the last
  announced `"${_log_dir}|${_session_log_dir}"`. A repeated call with the same
  resolved paths is silent; a call that genuinely resolves elsewhere announces
  again.
- `return 0` is explicit, preserving the success status callers depend on
  (`log_dir "" 1 || return 1`) that the removed `printf` used to supply.

### Adjacent hardening (found while testing, never observed in the field)

`fix_log_permissions()` read `local _real_user="${SUDO_USER:-${USER}}"`. The
fallback is itself unguarded, so with **both** variables unset and `set -u`
active — function.sh sets `set -Eeuo pipefail` — the script aborts here with
`USER: unbound variable`. A systemd unit starts with `USER` unset, which is
exactly how `dev_detect.sh` runs in the autorun path, as does `su -c`. Now
falls back to `id -un`, which always answers.

## Verification

`src/bash-shell/test_log_dir.sh` — seven cases: each path announced once;
no untagged line on stdout; a repeated identical call is silent; a changed path
is announced again; the exported variables carry the contract; success status
preserved; and survival with `USER`/`SUDO_USER` unset.

```bash
./src/bash-shell/test_log_dir.sh
```

Checked non-vacuous by reverting each fix in turn: restoring the `printf` fails
exactly one case and prints the stray line it found; reverting the `USER` guard
fails six, reporting the unbound-variable abort.
