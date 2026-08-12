---
id: BUG0057
status: open
created: 2026-08-11
os: [Ubuntu 24.04 LTS]
related_requirements: [LOG023, LOG015, LOG001]
related_bugs: []
---

# BUG0057 — a re-run is labelled with the previous invocation's session id

## Symptom

One reported test produced **two** summary logs and two `net_test` logs:

| File | Content |
|---|---|
| `net_summary_20260811T141916.log` | header row only, no data |
| `net_summary_20260811T142517.log` | all nine result rows |

and the HTML report was titled `session_20260811T141916_24272` while containing
the data from the 14:25:17 run.

The operator's reading — "the test ran twice" — is correct at the script level,
but the artefacts do not say so, and the natural next reading — "each speed was
tested twice" — is wrong (that was BUG0055).

## Analysis

Two `net_test.sh` invocations, about six minutes apart. The first wrote its
summary header and produced no results; the second did the full run.

`_session_ts` is set once per invocation (`: "${_session_ts:=$(now_ts)}"`), and
every artefact filename derives from it — hence two sets of files. The **session
id**, however, is sticky: `ensure_session_id` persists it in
`session_state/session.id` and reuses it, so the second invocation adopted the
first one's id and wrote into the same session directory.

The report's elapsed time confirms which run produced the data: `02:27:59`
against a 16:53:17 report is a 14:25:17 start — the second invocation. So the
report carries the second run's measurements under the first run's identity.

Sticky sessions are deliberate and useful (a resumed run must keep its identity).
What is wrong is that a **fresh** invocation silently inherits it, so:

1. the report's session id does not identify the run that produced it;
2. two runs' artefacts interleave in one directory, distinguished only by a
   timestamp embedded in filenames;
3. an abandoned first attempt leaves an empty summary that looks like a result.

## Not yet fixed — needs a decision

Options, none obviously right:

- **A.** A new invocation always starts a new session unless resume is explicitly
  requested. Matches LOG026's reasoning for power_cycle, but changes existing
  behaviour for every bash test.
- **B.** Keep stickiness, but stamp each artefact set with its own run id and
  make the report title carry the run, not the session.
- **C.** Expire the sticky id like LOG026 expires a resumable session.

Option A is closest to what LOG026 concluded for the Python side, and B is the
smallest change that removes the misleading label. Deferred pending Max's call,
since it changes session semantics for four scripts.

## Workaround

`_session_force_new=1` starts a fresh session, and deleting
`logs/session_state/session.id` has the same effect.
