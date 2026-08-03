---
id: BUG0042
status: resolved
created: 2026-08-03
closed: 2026-08-03
os: [Ubuntu 24.04 LTS, Ubuntu 26.04 LTS]
related_requirements: [LOG001, LOG025, LOG026]
related_bugs: []
---

# BUG0042 — Python tests wrote logs/ relative to the working directory

## Symptom

The Python half of the framework created its `logs/` tree in whatever
directory the operator happened to be standing in, not beside the scripts:

```
$ cd /tmp/anywhere
$ python3 /home/adlink/Downloads/power_cycle.py --dry-run --host 10.0.0.9
$ find . -name meta.json
./logs/10.0.0.9/power_cycle_20260803T021049/meta.json     ← in /tmp/anywhere
```

The bash and PowerShell halves anchor to the script instead, so the same
deployment produced log trees in two different places depending on which
runner was used and where it was launched from.

Two consequences, both silent:

1. **Invisible second log tree.** Results land somewhere the operator does
   not think to look, and are not picked up by the Ansible fetch step, which
   collects `{{ deploy_dir }}/logs`.
2. **`rm -rf logs/` clears the wrong tree.** Deleting `logs/` in the deploy
   directory is the established way to force a clean start (session state
   lives only under `--out`, LOG025). Launched from elsewhere, the run
   resolves a *different* `logs/`, so the deletion has no effect on it and
   an old session is resumed anyway — presenting as "I deleted logs/ and it
   still resumed".

Not previously hit in practice only because operators habitually `cd` into
the script directory first, and because the Ansible playbooks explicitly run
`cd {{ deploy_dir }} && ./{{ test_script }}`.

## Root cause

`config.py` defaulted the output paths to bare relative strings:

```python
LOG_DIR    = "./logs"
REPORT_DIR = "./logs"
```

`Path("./logs")` resolves against the **process working directory**, not the
module's location. `function.py`'s `_COUNTER_FILE = "counter.log"` and
`run_tests.sh`'s `OPT_OUT="logs"` had the same defect.

LOG001 already required a `logs/` directory "in the script working
directory" — wording that reads either way, which is how the Python
implementation drifted from the bash one without tripping a review.

## Fix

Anchor the defaults to the directory containing the scripts, matching
`function.sh`'s `_tool_path` (`function.sh:189`) and the PowerShell scripts'
`$_script_root`:

```python
_TOOL_PATH = _os.path.dirname(_os.path.abspath(__file__))
LOG_DIR    = _os.path.join(_TOOL_PATH, "logs")
REPORT_DIR = _os.path.join(_TOOL_PATH, "logs")
```

Same treatment for `function._COUNTER_FILE`, and `run_tests.sh` now defaults
`OPT_OUT="$SCRIPT_DIR/logs"`.

An explicit `--out` / `--report` is still honoured verbatim, and a relative
one still resolves against the working directory: the operator typed it, so
it means what they typed. Only the *default* is anchored.

LOG001's statement was tightened to say which directory it means, so the
ambiguity cannot produce this divergence again.

## Verification

`src/python/output_path_unittest.py` — five cases, including a subprocess
launched from an unrelated `cwd` asserting that `config.LOG_DIR`,
`config.REPORT_DIR` and `function._COUNTER_FILE` are unchanged and that
nothing is created in that foreign directory.

```bash
cd src/python && python3 -m unittest output_path_unittest -v
```
