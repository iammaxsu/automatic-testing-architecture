# CLAUDE.md — Automatic Testing Architecture

This file is read at the start of every Claude Code session. Read it before
touching anything else in the repository.

---

## What this project is

A test framework for hardware DUTs (devices under test) running Ubuntu —
currently 24.04 LTS and 26.04 LTS, with additional OS releases on the
roadmap. The framework is a collection of bash scripts (`config.sh`,
`function.sh`, `disk_test.sh`, `net_test.sh`, `dev_detect.sh`, etc.)
orchestrated by Ansible from a control node onto remote DUTs.

The work is in two layers:

1. **The framework itself** — bash scripts that execute on DUTs.
   Currently lives in a separate `Test-Automation` repository; will be
   migrated into `src/` here over time.
2. **The specification** — requirements in `requirements/` and bugs in
   `bugs/`, both as markdown with YAML frontmatter. This is where you
   (Claude Code) will spend most of your time.

The original spec lives in a Google Sheets spreadsheet at
`https://docs.google.com/spreadsheets/d/1RTbbWfzz5knsdV6nJ7z5hb0BV5mDWQGsmGLztQTaPFM`
— treat the per-file MDs in this repo as the source of truth once content
has been migrated. Do not edit the spreadsheet directly.

---

## Core principle: FWK028

Read [`requirements/FWK028.md`](requirements/FWK028.md) once before
making any decision about file format, output, or representation.

The short version: every artefact has a **machine-readable canonical
form** as its single source of truth. Human-readable views (HTML
reports, overview tables, dashboards) are **rendered** from the
canonical form, never the reverse. Bidirectional dependency between
canonical and derived forms is prohibited.

Concretely:
- `result.json` (canonical) → `<test>_report.html` (rendered)
- `requirements/**/*.md` with frontmatter (canonical) → `STATUS.md`,
  `STATUS.html` (rendered)
- `bugs/**/*.md` with frontmatter (canonical) → bug indexes,
  traceability tables (rendered)

Never hand-edit a derived file. Fix the canonical source and
regenerate.

---

## Repository layout

```
.
├── CLAUDE.md                    ← this file
├── STATUS.md                    ← generated; do not hand-edit
├── STATUS.html                  ← generated; do not hand-edit
├── Makefile                     ← `make stats` regenerates STATUS.*
├── .gitattributes               ← enforces LF for shell/python/md
├── requirements/                ← canonical: one .md per requirement
│   ├── FWK028.md
│   └── …
├── bugs/                        ← canonical: one .md per bug
│   ├── open/                    ← status: open or in-progress
│   ├── closed/                  ← status: closed or resolved
│   └── invalid/                 ← status: invalid or wont-fix
├── scripts/
│   ├── stats.py                 ← generates STATUS.md
│   └── make_dashboard.py        ← generates STATUS.html
├── docs/                        ← prose docs, architecture decisions
├── src/                         ← bash test framework (to be migrated)
└── .claude/
    └── skills/                  ← Claude Code skills for this repo
```

---

## Conventions

### Requirement frontmatter schema

```yaml
---
id: FWK028                              # required, unique, matches filename
priority: Must | Should                  # required
verification: Code Review | Automated Test | "—"   # required
status: proposed | implementing | implemented | verified | withdrawn
introduced: 2026-05-25                   # YYYY-MM-DD
related:
  requirements: [LOG015, LOG018]
  bugs: [BUG0001, BUG0018]
---
```

Section structure inside each requirement file, in this order:

1. `# {ID} — {Title}` (one H1, em-dash separator)
2. `## Statement` — the actual rule, terse, normative ("shall …")
3. `## Rationale` — why this rule exists
4. `## Scope` — where it applies, table if useful
5. `## Implications` — concrete consequences, numbered list
6. `## Verification` — how to confirm the requirement is met
7. `## Related` — cross-references using relative markdown links

`scripts/stats.py` parses these section names; do not rename them
without updating the script.

### Bug frontmatter schema

```yaml
---
id: BUG0019                              # required, unique, matches filename
status: open | in-progress | resolved | closed | invalid | wont-fix
created: 2026-05-07                      # YYYY-MM-DD
closed: 2026-05-07                       # only if status is terminal
os: [Ubuntu 26.04 LTS]                   # OS(es) where reproduced
related_requirements: [LOG015, FWK027]
related_bugs: [BUG0018]
---
```

Body sections (adapt as needed): `## Symptom`, `## Root cause`,
`## Fix`, `## Verification`. Invalid bugs may have only
`## Resolution`.

Filename: `BUG{NNNN}-{short-slug}.md` (e.g.
`BUG0019-result-json-metadata.md`). Place the file in the subfolder
matching its current status:

| Status                  | Subfolder        |
|-------------------------|------------------|
| open, in-progress       | `bugs/open/`     |
| resolved, closed        | `bugs/closed/`   |
| invalid, wont-fix       | `bugs/invalid/`  |

**When a bug's status transitions across these groups, `git mv` the
file to the new subfolder in the same commit.** The folder location
is the visible-in-GitHub statement of the bug's status; do not let
it drift from the frontmatter `status` field.

### ID prefix system

Requirements use a 3-letter prefix + 3-digit number:

| Prefix | Domain                            |
|--------|-----------------------------------|
| DOC    | documentation conventions         |
| FWK    | framework-wide rules              |
| LOG    | logging, result artefacts         |
| SET    | settings / config                 |
| FUN    | shared helper functions           |
| NET    | network tests                     |
| DSK    | disk / storage tests              |
| DET    | device detection                  |
| SLP    | sleep / suspend tests             |
| CMP    | OS compatibility                  |

Bugs use `BUG{NNNN}` — flat namespace, no domain prefix.

Numbering is sequential per prefix; never reuse a number, even after
withdrawal (withdrawn requirements remain as files for historical
reference). A higher number does not imply lower priority — priority
is the `priority:` field.

### Status vocabulary

**Requirements:**
- `proposed` — written but not implemented
- `implementing` — work in progress
- `implemented` — author believes the implementation satisfies it
- `verified` — confirmed by independent test (e.g. an Ansible e2e run)
- `withdrawn` — no longer applicable; file retained as historical record

**Bugs:**
- `open` — confirmed, not yet being worked on
- `in-progress` — actively being fixed
- `resolved` — fix written, awaiting independent verification
- `closed` — fix verified
- `invalid` — confirmed not actually a bug
- `wont-fix` — real but explicitly out of scope

---

## Tooling

### Generating the status dashboard

```bash
make stats
# equivalent to:
python scripts/stats.py > STATUS.md
python scripts/make_dashboard.py > STATUS.html
```

Run after any non-trivial change to `requirements/` or `bugs/`.
**Commit the regenerated `STATUS.md` and `STATUS.html` in the same
commit as the underlying change**, so the GitHub-rendered view never
lags behind the canonical source.

### Adding a new requirement

1. Pick the next available number for that prefix (check existing
   files in `requirements/`).
2. Create `requirements/{PREFIX}{NNN}.md` with the frontmatter schema
   above. Filename is exactly the ID — no slug.
3. Set `status: proposed`.
4. Fill in the seven body sections in order.
5. Add cross-references in `related:` to any requirements or bugs
   that motivate or constrain this one.
6. `make stats` and commit both the new file and the updated
   `STATUS.{md,html}`.

### Adding a new bug

1. Pick the next BUG number (check existing files across all of
   `bugs/`).
2. Create `bugs/open/BUG{NNNN}-{short-slug}.md`. Use a slug that
   makes the file identifiable from `ls` — e.g.
   `BUG0019-result-json-metadata.md`.
3. Fill in symptom immediately. Root cause and fix may come later as
   you diagnose; that's expected.
4. When fixed and independently verified, `git mv` the file to
   `bugs/closed/` and update the frontmatter `status:` and `closed:`
   fields in the same commit.
5. `make stats` and commit.

### Querying the spec from the command line

`scripts/stats.py` produces a summary; for ad-hoc queries during
work, plain grep on frontmatter is usually faster:

```bash
# All Must-priority requirements not yet implemented
grep -l "^priority: Must$" requirements/*.md | \
  xargs grep -l "^status: proposed$"

# All bugs referencing a specific requirement
grep -rl "NET011" bugs/

# Status distribution
grep -h "^status:" requirements/*.md | sort | uniq -c
```

---

## Current state (2026-05-25)

This repo is freshly scaffolded. Work ahead:

- [x] Repo structure created
- [x] FWK028 written
- [x] `stats.py` and `make_dashboard.py` working
- [x] `.gitattributes` configured
- [ ] **Migrate ~106 requirements** from the Google Sheets spreadsheet
      into `requirements/`. Suggested order (highest leverage first):
      LOG, FWK, NET, DSK, FUN, DET, SLP, CMP, SET, DOC.
- [ ] **Migrate ~24 bugs** from the same spreadsheet into `bugs/`.
- [ ] Bring the bash framework into `src/` (currently in the legacy
      `Test-Automation` work).
- [ ] **`docs/architecture.md`** — extract architectural decisions
      from the Claude.ai "Automatic Testing Architecture" project
      conversations and consolidate them here. See note below.

---

## External context not yet in this repo

There is a Claude.ai project called "Automatic Testing Architecture"
containing historical conversations about the bash framework's
design — decisions about counter file format, session lifecycle,
helper-function boundaries, Ansible orchestration patterns, log
file layout, and so on. These conversations have **not** been
migrated into this repo.

If you (Claude Code) encounter a question whose answer feels like it
should be obvious from project history but you cannot find a written
basis for it in this repo, **ask the human (Max) to share the
relevant decision** rather than guessing. The migration of that
context into `docs/architecture.md` is a planned but unfinished task.

Once a decision is extracted into `docs/architecture.md`, this
section should be updated to reference it specifically rather than
saying "look in the Project chats."

---

## Communication conventions

- **Language for code, frontmatter keys, IDs, filenames, commit
  messages:** English.
- **Language for requirement / bug body prose:** English by default;
  match surrounding content if a section is already in another
  language.
- **Language for conversing with the human (Max):** Traditional
  Chinese unless he switches first.
- **Commit messages:** imperative mood, first line ≤72 chars,
  reference IDs explicitly. Examples:
  - `Add FWK028: machine-readable canonical form first`
  - `Close BUG0019: fix counter_tick session_id leak`
  - `Migrate LOG section from spreadsheet (22 requirements)`
- **Generated artefacts** (`STATUS.md`, `STATUS.html`, anything else
  derived) are committed in the same commit as the canonical change
  that produced them.

---

## When in doubt

These conventions are new and will evolve. If you find yourself
about to do something that isn't explicitly covered above — picking
a new section name, inventing a new status value, deviating from
the filename pattern, adding a new top-level directory — **stop and
ask Max first**. A two-message clarification is much cheaper than
inconsistent files that have to be reformatted across the corpus
later.
