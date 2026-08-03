# Branch and PR hygiene — known problem, deferred

Status: **open, deferred by decision (2026-08-03)**

Not filed under `bugs/` — that namespace is for framework defects observed
on a DUT, with an `os:` field and a reproduction. This is a repository
process problem, so it lives here.

## Problem

Branch `claude/gracious-allen-9o49b` (PR #21) accumulated **111 commits,
74 files, +12,744 / −526** across eight largely independent workstreams:

| Stream | Contents |
|--------|----------|
| SLP | Windows sleep/suspend endurance test (Python + PowerShell) |
| NET | multi-speed back-to-back network test, NET015–NET019 |
| DET | dev_detect Layer 1/2 golden comparison, snapshot mode, test harnesses |
| SET | `setup_dut.sh` / `.ps1`, SSH key install, DUT env restore |
| PWR | adaptive boot timeout, calibration, `--debug`, `--off auto`, firmware reporting |
| LOG | session layout and resume (LOG001, LOG023, LOG025, LOG026) |
| FWK | cross-language parity, system inventory, SSH options |
| — | HTML report corrections |

Plus 14 new requirements and 15 bug records.

Consequences:

1. **The PR cannot be meaningfully reviewed.** No reviewer can hold eight
   unrelated streams in mind at once, so in practice it merges unreviewed.
2. **All-or-nothing merge.** A problem found in any one stream blocks the
   other seven, none of which are related to it.
3. **The title can only list categories.** This was mistaken at first for a
   stale-title problem and the title was rewritten to cover the contents
   (PR #21, 2026-08-03) — an improvement in honesty, but it does not make
   the PR reviewable. Scope, not labelling, is the defect.
4. **Bisecting a regression** across 111 commits spanning eight subsystems
   is far more expensive than it needs to be.

## Why it is not being fixed retroactively

Splitting now means rewriting 111 commits of history. The streams are not
cleanly separable: LOG026 builds on LOG025's session layout, and BUG0042
depends on LOG026's banner to surface the resolved output path. The
rebase cost and the risk of dropping work exceed the benefit on a
single-maintainer repository where the PR is still a draft.

Decision: land PR #21 as-is, fix the process going forward.

## What to do instead, from the next piece of work

1. **One branch per stream.** A branch ends when its stream is done, not
   when the next idea arrives.
2. **Branch from `main`, not from the previous feature branch**, unless
   there is a real dependency — and if there is, say so in the PR body.
3. **Open the PR early as a draft**, so scope creep is visible while it is
   still cheap to split.
4. **A requirement or bug that motivates unrelated work is a signal to
   branch**, not to keep going on the current one.

## Revisit

Reconsider only if PR #21 stalls in review, or if a regression needs
bisecting across it. Neither has happened yet.
