#!/usr/bin/env python3
"""
Generates STATUS.html — a self-contained, interactive dashboard.

Reads the same canonical sources as stats.py (requirements/**/*.md,
bugs/**/*.md), but renders a richer view: Chart.js pie/bar charts
served from CDN, hover tooltips, light/dark mode aware, no build step.

This is FWK028 in action: same canonical source, second derived view.
The HTML is regenerable from canonical; do not hand-edit.

Usage:
    python scripts/make_dashboard.py > STATUS.html
"""

import re
import sys
import json
import collections
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("Install PyYAML first:  pip install pyyaml\n")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
REQ_DIR = REPO_ROOT / "requirements"
BUG_DIR = REPO_ROOT / "bugs"

# Base URL for linking to source files on GitHub.
# Set to None to use relative paths (works locally but not on GitHub Pages).
GITHUB_BLOB_BASE = "https://github.com/iammaxsu/automatic-testing-architecture/blob/main"

REQ_STATUSES = ["proposed", "implementing", "implemented", "verified", "withdrawn"]
BUG_STATUSES = ["open", "in-progress", "resolved", "closed", "invalid", "wont-fix"]
STATUS_COLORS = {
    "proposed":    "#F2A623",  # amber
    "implementing":"#3B8BD4",  # blue
    "implemented": "#7BB661",  # light green
    "verified":    "#1D9E75",  # teal/green
    "withdrawn":   "#888780",  # gray
    "open":        "#E24B4A",  # red
    "in-progress": "#F2A623",  # amber
    "resolved":    "#7BB661",
    "closed":      "#1D9E75",
    "invalid":     "#888780",
    "wont-fix":    "#5F5E5A",
}

FM_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
H1_RE = re.compile(r"^#\s+\S+\s*[—\-]\s*(.+)$", re.MULTILINE)


def parse_md(path: Path):
    text = path.read_text(encoding="utf-8")
    m = FM_RE.match(text)
    if not m:
        return None
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        return None
    title_m = H1_RE.search(text[m.end():])
    meta["_title"] = title_m.group(1).strip() if title_m else "(untitled)"
    meta["_path"] = path.relative_to(REPO_ROOT).as_posix()
    return meta


def load_all(d: Path):
    if not d.exists():
        return []
    return [m for m in (parse_md(p) for p in sorted(d.rglob("*.md"))) if m]


def section_of(s):
    m = re.match(r"^([A-Z]+)", str(s))
    return m.group(1) if m else "?"


def chart_data(counter, order, colors):
    labels, values, bg = [], [], []
    for key in order:
        v = counter.get(key, 0)
        if v:
            labels.append(key)
            values.append(v)
            bg.append(colors.get(key, "#888"))
    return {"labels": labels, "values": values, "colors": bg}


def main():
    reqs = load_all(REQ_DIR)
    bugs = load_all(BUG_DIR)
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    req_status_data = chart_data(
        collections.Counter(r.get("status", "?") for r in reqs),
        REQ_STATUSES, STATUS_COLORS)
    bug_status_data = chart_data(
        collections.Counter(b.get("status", "?") for b in bugs),
        BUG_STATUSES, STATUS_COLORS)

    by_section = collections.Counter(section_of(r.get("id", "?")) for r in reqs)
    section_data = {
        "labels": sorted(by_section),
        "verified": [],
        "in_progress": [],
        "todo": [],
    }
    for sec in section_data["labels"]:
        sec_reqs = [r for r in reqs if section_of(r.get("id", "")) == sec]
        section_data["verified"].append(
            sum(1 for r in sec_reqs if r.get("status") == "verified"))
        section_data["in_progress"].append(
            sum(1 for r in sec_reqs
                if r.get("status") in ("implemented", "implementing")))
        section_data["todo"].append(
            sum(1 for r in sec_reqs if r.get("status") == "proposed"))

    def file_url(rel_path):
        if GITHUB_BLOB_BASE:
            return f"{GITHUB_BLOB_BASE}/{rel_path}"
        return rel_path

    open_bugs = [
        {"id": b["id"], "title": b["_title"], "created": str(b.get("created", "")),
         "os": b.get("os") or [], "path": file_url(b["_path"])}
        for b in bugs if b.get("status") in ("open", "in-progress")
    ]
    open_bugs.sort(key=lambda b: b["created"])

    must_todo = [
        {"id": r["id"], "title": r["_title"], "status": r.get("status", "?"),
         "path": file_url(r["_path"])}
        for r in reqs
        if r.get("priority") == "Must"
        and r.get("status") in ("proposed", "implementing")
    ]
    must_todo.sort(key=lambda r: r["id"])

    data = {
        "generated": now,
        "totals": {"reqs": len(reqs), "bugs": len(bugs),
                   "open_bugs": len(open_bugs), "must_todo": len(must_todo)},
        "req_status": req_status_data,
        "bug_status": bug_status_data,
        "section": section_data,
        "open_bugs": open_bugs,
        "must_todo": must_todo,
    }

    print(HTML_TEMPLATE.replace("__DATA__", json.dumps(data, ensure_ascii=False)))


HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Project Status</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #ffffff; --fg: #1a1a1a; --muted: #6b6b6b;
    --card: #fafaf7; --border: #e5e3dc; --accent: #3b8bd4;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#1a1a1a; --fg:#e5e3dc; --muted:#9c9a92;
            --card:#242422; --border:#3a3a37; --accent:#5da5e8; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px; font:14px/1.6 -apple-system,BlinkMacSystemFont,
         "Segoe UI",sans-serif; background:var(--bg); color:var(--fg); }
  h1 { font-size:22px; font-weight:500; margin:0 0 4px; }
  h2 { font-size:16px; font-weight:500; margin:24px 0 12px;
       padding-bottom:6px; border-bottom:1px solid var(--border); }
  .timestamp { color:var(--muted); font-size:12px; margin-bottom:24px; }
  .kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr));
          gap:12px; margin-bottom:24px; }
  .kpi { background:var(--card); border:1px solid var(--border);
         border-radius:8px; padding:14px; }
  .kpi-label { font-size:11px; color:var(--muted); text-transform:uppercase;
               letter-spacing:0.5px; }
  .kpi-value { font-size:28px; font-weight:500; margin-top:4px; }
  .kpi-value.warn { color:#E24B4A; }
  .charts { display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr));
            gap:16px; }
  .chart-card { background:var(--card); border:1px solid var(--border);
                border-radius:8px; padding:16px; }
  .chart-card h3 { font-size:13px; font-weight:500; margin:0 0 12px;
                   color:var(--muted); text-transform:uppercase;
                   letter-spacing:0.5px; }
  .chart-wrap { position:relative; height:240px; }
  table { width:100%; border-collapse:collapse; margin-top:8px; }
  th, td { text-align:left; padding:8px 12px; border-bottom:1px solid var(--border);
           font-size:13px; }
  th { font-weight:500; color:var(--muted); font-size:11px;
       text-transform:uppercase; letter-spacing:0.5px; }
  tr:last-child td { border-bottom:none; }
  a { color:var(--accent); text-decoration:none; }
  a:hover { text-decoration:underline; }
  .table-card { background:var(--card); border:1px solid var(--border);
                border-radius:8px; padding:8px 0; margin-bottom:16px; }
  .table-card h2 { margin:8px 16px 4px; border:none; padding:0; }
  .empty { color:var(--muted); font-style:italic; padding:12px 16px; }
  code { background:var(--border); padding:1px 6px; border-radius:3px;
         font-size:12px; }
</style>
</head>
<body>

<h1>Project Status</h1>
<div class="timestamp">Generated <span id="gen"></span> ·
  regenerate with <code>python scripts/make_dashboard.py &gt; STATUS.html</code>
</div>

<div class="kpis">
  <div class="kpi"><div class="kpi-label">Requirements</div><div class="kpi-value" id="kpi-reqs">–</div></div>
  <div class="kpi"><div class="kpi-label">Bugs (total)</div><div class="kpi-value" id="kpi-bugs">–</div></div>
  <div class="kpi"><div class="kpi-label">Open bugs</div><div class="kpi-value warn" id="kpi-open">–</div></div>
  <div class="kpi"><div class="kpi-label">Must-priority TODO</div><div class="kpi-value warn" id="kpi-todo">–</div></div>
</div>

<h2>Distribution</h2>
<div class="charts">
  <div class="chart-card">
    <h3>Requirements by status</h3>
    <div class="chart-wrap"><canvas id="c-req"></canvas></div>
  </div>
  <div class="chart-card">
    <h3>Bugs by status</h3>
    <div class="chart-wrap"><canvas id="c-bug"></canvas></div>
  </div>
  <div class="chart-card">
    <h3>Requirements by section</h3>
    <div class="chart-wrap"><canvas id="c-sec"></canvas></div>
  </div>
</div>

<div class="table-card">
  <h2>Open bugs (oldest first)</h2>
  <div id="t-open"></div>
</div>

<div class="table-card">
  <h2>Must-priority requirements not yet implemented</h2>
  <div id="t-todo"></div>
</div>

<script>
const D = __DATA__;
const dark = matchMedia('(prefers-color-scheme: dark)').matches;
const gridColor = dark ? '#3a3a37' : '#e5e3dc';
const textColor = dark ? '#9c9a92' : '#6b6b6b';
Chart.defaults.color = textColor;
Chart.defaults.borderColor = gridColor;

document.getElementById('gen').textContent = D.generated;
document.getElementById('kpi-reqs').textContent = D.totals.reqs;
document.getElementById('kpi-bugs').textContent = D.totals.bugs;
document.getElementById('kpi-open').textContent = D.totals.open_bugs;
document.getElementById('kpi-todo').textContent = D.totals.must_todo;

function pie(canvasId, data) {
  new Chart(document.getElementById(canvasId), {
    type: 'doughnut',
    data: {
      labels: data.labels,
      datasets: [{
        data: data.values,
        backgroundColor: data.colors,
        borderColor: dark ? '#1a1a1a' : '#fff',
        borderWidth: 2,
      }]
    },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: { legend: { position: 'right', labels: { boxWidth: 12, font: { size: 12 } } } },
      cutout: '60%'
    }
  });
}

pie('c-req', D.req_status);
pie('c-bug', D.bug_status);

new Chart(document.getElementById('c-sec'), {
  type: 'bar',
  data: {
    labels: D.section.labels,
    datasets: [
      { label: 'Verified', data: D.section.verified, backgroundColor: '#1D9E75' },
      { label: 'Implemented / in progress', data: D.section.in_progress, backgroundColor: '#3B8BD4' },
      { label: 'Proposed', data: D.section.todo, backgroundColor: '#F2A623' },
    ]
  },
  options: {
    responsive: true, maintainAspectRatio: false,
    scales: {
      x: { stacked: true, grid: { display: false } },
      y: { stacked: true, beginAtZero: true, ticks: { stepSize: 1 } }
    },
    plugins: { legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 12 } } } }
  }
});

function table(elId, rows, columns) {
  const el = document.getElementById(elId);
  if (rows.length === 0) { el.innerHTML = '<div class="empty">None.</div>'; return; }
  const thead = '<tr>' + columns.map(c => `<th>${c.label}</th>`).join('') + '</tr>';
  const tbody = rows.map(r => '<tr>' +
    columns.map(c => `<td>${c.render(r)}</td>`).join('') +
  '</tr>').join('');
  el.innerHTML = `<table><thead>${thead}</thead><tbody>${tbody}</tbody></table>`;
}

table('t-open', D.open_bugs, [
  { label: 'ID',      render: r => `<a href="${r.path}">${r.id}</a>` },
  { label: 'Created', render: r => r.created },
  { label: 'OS',      render: r => (r.os || []).join(', ') },
  { label: 'Title',   render: r => r.title },
]);

table('t-todo', D.must_todo, [
  { label: 'ID',     render: r => `<a href="${r.path}">${r.id}</a>` },
  { label: 'Status', render: r => r.status },
  { label: 'Title',  render: r => r.title },
]);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
