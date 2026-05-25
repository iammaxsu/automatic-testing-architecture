#!/usr/bin/env python3
"""
Project status report generator.

Walks requirements/ and bugs/, parses YAML frontmatter from each .md file,
and emits a STATUS.md dashboard. This is the canonical-to-derived pipeline
in action (FWK028): per-requirement and per-bug .md files are the source
of truth; STATUS.md is regenerable from them at any time.

Usage:
    python scripts/stats.py > STATUS.md
"""

import re
import sys
import collections
from datetime import datetime, date
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("Install PyYAML first:  pip install pyyaml\n")
    sys.exit(1)


REPO_ROOT = Path(__file__).resolve().parent.parent
REQ_DIR = REPO_ROOT / "requirements"
BUG_DIR = REPO_ROOT / "bugs"

REQ_STATUS_ORDER = ["proposed", "implementing", "implemented",
                    "verified", "withdrawn"]
BUG_STATUS_ORDER = ["open", "in-progress", "resolved",
                    "closed", "invalid", "wont-fix"]

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
HEADLINE_RE = re.compile(r"^#\s+\S+\s*[—\-]\s*(.+)$", re.MULTILINE)


def parse_md(path: Path) -> dict | None:
    text = path.read_text(encoding="utf-8")
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        sys.stderr.write(f"YAML error in {path}: {e}\n")
        return None
    title_match = HEADLINE_RE.search(text[m.end():])
    meta["_title"] = title_match.group(1).strip() if title_match else "(untitled)"
    meta["_path"] = path.relative_to(REPO_ROOT).as_posix()
    return meta


def load_all(directory: Path) -> list[dict]:
    if not directory.exists():
        return []
    return [m for m in (parse_md(p) for p in sorted(directory.rglob("*.md"))) if m]


def section_of(req_id: str) -> str:
    m = re.match(r"^([A-Z]+)", str(req_id))
    return m.group(1) if m else "?"


def md_table(headers: list, rows: list) -> str:
    if not rows:
        return "_(none)_\n"
    out = ["| " + " | ".join(str(h) for h in headers) + " |",
           "| " + " | ".join(["---"] * len(headers)) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out) + "\n"


def mermaid_pie(title: str, data: list) -> str:
    """Emit a mermaid pie chart. data = [(label, count), ...]; zeros skipped."""
    rows = [(lbl, n) for lbl, n in data if n]
    if not rows:
        return ""
    lines = ["```mermaid", f"pie showData title {title}"]
    for label, count in rows:
        lines.append(f'    "{label}" : {count}')
    lines.append("```")
    return "\n".join(lines) + "\n"


def main():
    reqs = load_all(REQ_DIR)
    bugs = load_all(BUG_DIR)

    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    print(f"# Project Status\n")
    print(f"_Generated {now} · "
          f"regenerate with `python scripts/stats.py > STATUS.md`_\n")

    # ─── Requirements ──────────────────────────────────────────
    print(f"## Requirements\n")
    print(f"**Total:** {len(reqs)}\n")

    by_priority = collections.Counter(r.get("priority", "?") for r in reqs)
    by_status = collections.Counter(r.get("status", "?") for r in reqs)
    by_section = collections.Counter(section_of(r.get("id", "?")) for r in reqs)

    print("### By priority\n")
    print(md_table(["Priority", "Count"], by_priority.most_common()))

    print("### By status\n")
    print(md_table(
        ["Status", "Count"],
        [[s, by_status.get(s, 0)] for s in REQ_STATUS_ORDER if by_status.get(s, 0)]
    ))
    print(mermaid_pie("Requirements by status",
                      [(s, by_status.get(s, 0)) for s in REQ_STATUS_ORDER]))

    print("### By section\n")
    sec_rows = []
    for sec in sorted(by_section):
        sec_reqs = [r for r in reqs if section_of(r.get("id", "")) == sec]
        verified = sum(1 for r in sec_reqs if r.get("status") == "verified")
        todo = sum(1 for r in sec_reqs
                   if r.get("status") in ("proposed", "implementing"))
        sec_rows.append([sec, len(sec_reqs), verified, todo])
    print(md_table(["Section", "Total", "Verified", "Not done"], sec_rows))

    # Must-priority not implemented
    must_todo = [r for r in reqs
                 if r.get("status") in ("proposed", "implementing")
                 and r.get("priority") == "Must"]
    print("### Must-priority requirements not yet implemented\n")
    print(md_table(
        ["ID", "Status", "Title"],
        [[f"[{r['id']}]({r['_path']})", r.get("status", "?"), r["_title"]]
         for r in sorted(must_todo, key=lambda r: str(r.get("id", "")))]
    ))

    # ─── Bugs ──────────────────────────────────────────────────
    print(f"## Bugs\n")
    print(f"**Total:** {len(bugs)}\n")

    by_bstatus = collections.Counter(b.get("status", "?") for b in bugs)
    by_os = collections.Counter()
    for b in bugs:
        for o in (b.get("os") or []):
            by_os[o] += 1

    print("### By status\n")
    print(md_table(
        ["Status", "Count"],
        [[s, by_bstatus.get(s, 0)] for s in BUG_STATUS_ORDER if by_bstatus.get(s, 0)]
    ))
    print(mermaid_pie("Bugs by status",
                      [(s, by_bstatus.get(s, 0)) for s in BUG_STATUS_ORDER]))

    print("### By OS\n")
    print(md_table(["OS", "Count"], by_os.most_common()))

    open_bugs = [b for b in bugs if b.get("status") in ("open", "in-progress")]
    print("### Open bugs (oldest first)\n")
    open_bugs.sort(key=lambda b: b.get("created") or date(9999, 1, 1))
    print(md_table(
        ["ID", "Created", "Status", "Title"],
        [[f"[{b['id']}]({b['_path']})",
          b.get("created", "?"),
          b.get("status", "?"),
          b["_title"]]
         for b in open_bugs]
    ))

    # ─── Traceability ─────────────────────────────────────────
    print("## Traceability\n")
    req_to_bugs = collections.defaultdict(list)
    for b in bugs:
        for rid in (b.get("related_requirements") or []):
            req_to_bugs[rid].append(b)

    print("### Requirements with associated bugs\n")
    rows = []
    for rid in sorted(req_to_bugs):
        for b in req_to_bugs[rid]:
            rows.append([rid,
                         f"[{b['id']}]({b['_path']})",
                         b.get("status", "?")])
    print(md_table(["Requirement", "Bug", "Bug status"], rows))

    # Reqs with NO bug yet — useful "have I tested this?" hint
    reqs_with_bug = set(req_to_bugs)
    reqs_without_bug = [r for r in reqs
                        if r.get("priority") == "Must"
                        and r.get("status") in ("implemented", "verified")
                        and r["id"] not in reqs_with_bug]
    print("### Implemented Must-priority requirements with no associated bug\n")
    print("_(may indicate untested code paths — worth a review)_\n")
    print(md_table(
        ["ID", "Status", "Title"],
        [[f"[{r['id']}]({r['_path']})", r.get("status", "?"), r["_title"]]
         for r in sorted(reqs_without_bug, key=lambda r: str(r.get("id", "")))]
    ))


if __name__ == "__main__":
    main()
