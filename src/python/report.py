# report.py — HTML report generator for power_cycle result.json
#
# Generates a self-contained HTML file (Chart.js from CDN) with:
#   1. Summary cards (total / pass / fail / overall verdict)
#   2. Cycle timeline — one coloured dot per cycle (scatter chart)
#   3. Boot time trend — line chart of boot_time_sec for passing cycles
#   4. Failure detail table — one row per failed cycle

import json
import logging
from pathlib import Path

log = logging.getLogger(__name__)

# Colour map: verdict → CSS colour
_COLOUR = {
    "PASS":          "#4caf50",
    "NO_BOOT":       "#f44336",
    "CRASH":         "#ff9800",
    "HANG_SHUTDOWN": "#9c27b0",
    "RELAY_ERROR":   "#607d8b",
    "RUNNING":       "#2196f3",
}

_VERDICT_ORDER = ["PASS", "NO_BOOT", "CRASH", "HANG_SHUTDOWN", "RELAY_ERROR"]


def _verdict_colour(v: str) -> str:
    return _COLOUR.get(v, "#999")


def generate_report(result: dict, output_path: str) -> None:
    """Render result dict to a self-contained HTML file at output_path."""
    try:
        html = _render(result)
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(html)
        log.info("Report written: %s", output_path)
    except Exception as exc:
        log.error("Failed to write report: %s", exc)


# ── data preparation ──────────────────────────────────────────────────────────

def _timeline_datasets(cycles: list) -> str:
    """Return Chart.js datasets JS for the timeline scatter chart."""
    datasets = {}
    for v in _VERDICT_ORDER:
        datasets[v] = []
    for c in cycles:
        v = c.get("verdict", "RELAY_ERROR")
        datasets.setdefault(v, []).append({"x": c["n"], "y": 1})

    parts = []
    for v in _VERDICT_ORDER:
        pts = datasets.get(v, [])
        if not pts:
            continue
        pts_js = json.dumps(pts)
        col    = _verdict_colour(v)
        parts.append(
            f'{{label:"{v}",data:{pts_js},'
            f'backgroundColor:"{col}",pointRadius:6,pointHoverRadius:8}}'
        )
    return "[" + ",".join(parts) + "]"


def _boottime_data(cycles: list) -> str:
    """Return Chart.js data JS for boot-time line chart (passing cycles only)."""
    pts = []
    for c in cycles:
        if c.get("verdict") == "PASS" and c.get("boot_time_sec") is not None:
            pts.append({"x": c["n"], "y": c["boot_time_sec"]})
    return json.dumps(pts)


def _fail_rows_html(cycles: list) -> str:
    rows = []
    for c in cycles:
        v = c.get("verdict", "")
        if v == "PASS":
            continue
        col   = _verdict_colour(v)
        cycle = c["n"]
        t_on  = c.get("t_power_on") or "—"
        boot  = f'{c["boot_time_sec"]:.1f}s' if c.get("boot_time_sec") is not None else "—"
        notes = c.get("notes") or ""
        rows.append(
            f'<tr>'
            f'<td>{cycle}</td>'
            f'<td style="color:{col};font-weight:600">{v}</td>'
            f'<td>{t_on}</td>'
            f'<td>{boot}</td>'
            f'<td>{notes}</td>'
            f'</tr>'
        )
    if not rows:
        return '<tr><td colspan="5" style="text-align:center;color:#888">No failures</td></tr>'
    return "\n".join(rows)


# ── main renderer ─────────────────────────────────────────────────────────────

def _render(result: dict) -> str:
    cfg     = result.get("config", {})
    summary = result.get("summary", {})
    cycles  = result.get("cycles", [])

    overall      = result.get("overall_verdict", "—")
    overall_col  = _verdict_colour(overall)
    started      = result.get("started_at", "—")
    ended        = result.get("ended_at", "—")
    total_ran    = summary.get("total_ran", 0)
    total_target = summary.get("cycles_target", cfg.get("cycles_target", "—"))
    n_pass       = summary.get("pass", 0)
    n_fail       = summary.get("fail", 0)
    fb           = summary.get("fail_breakdown", {})

    timeline_ds  = _timeline_datasets(cycles)
    boottime_pts = _boottime_data(cycles)
    fail_rows    = _fail_rows_html(cycles)

    # Donut chart data (pass / each fail type)
    donut_labels = ["PASS"] + [k for k in _VERDICT_ORDER[1:] if fb.get(k, 0) > 0]
    donut_values = [n_pass] + [fb.get(k, 0) for k in _VERDICT_ORDER[1:] if fb.get(k, 0) > 0]
    donut_colours = [_verdict_colour(v) for v in donut_labels]

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Power Cycle Report — {started[:10]}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{font-family:sans-serif;background:#f4f6f8;color:#333;padding:20px}}
  h1{{font-size:1.6rem;margin-bottom:4px}}
  .subtitle{{color:#666;font-size:.9rem;margin-bottom:20px}}
  .cards{{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:24px}}
  .card{{background:#fff;border-radius:8px;padding:16px 20px;min-width:140px;
         box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  .card .label{{font-size:.75rem;color:#888;text-transform:uppercase;letter-spacing:.05em}}
  .card .value{{font-size:1.8rem;font-weight:700;margin-top:4px}}
  .verdict-badge{{display:inline-block;padding:4px 14px;border-radius:4px;
                  color:#fff;font-size:1rem;font-weight:600}}
  .charts{{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px}}
  .chart-box{{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  .chart-box h2{{font-size:.95rem;margin-bottom:10px;color:#555}}
  canvas{{max-height:260px}}
  .full-width{{grid-column:1/-1}}
  table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
         overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  th{{background:#37474f;color:#fff;padding:10px 14px;text-align:left;font-size:.85rem}}
  td{{padding:9px 14px;font-size:.85rem;border-bottom:1px solid #eee}}
  tr:last-child td{{border-bottom:none}}
  tr:hover td{{background:#fafafa}}
  .section-title{{font-size:1.1rem;font-weight:600;margin:24px 0 10px}}
  .meta{{color:#888;font-size:.8rem;margin-top:20px}}
</style>
</head>
<body>

<h1>Power Cycle Test Report</h1>
<p class="subtitle">
  {cfg.get("power_type","—")} &nbsp;|&nbsp;
  DUT: {cfg.get("dut_host") or "(liveness disabled)"} &nbsp;|&nbsp;
  Started: {started} &nbsp;|&nbsp; Ended: {ended}
</p>

<!-- Summary cards -->
<div class="cards">
  <div class="card">
    <div class="label">Overall</div>
    <div class="value">
      <span class="verdict-badge" style="background:{overall_col}">{overall}</span>
    </div>
  </div>
  <div class="card">
    <div class="label">Cycles ran</div>
    <div class="value">{total_ran} <span style="font-size:1rem;color:#888">/ {total_target}</span></div>
  </div>
  <div class="card">
    <div class="label">Pass</div>
    <div class="value" style="color:{_verdict_colour("PASS")}">{n_pass}</div>
  </div>
  <div class="card">
    <div class="label">Fail</div>
    <div class="value" style="color:{_verdict_colour("NO_BOOT")}">{n_fail}</div>
  </div>
  <div class="card">
    <div class="label">NO_BOOT</div>
    <div class="value">{fb.get("NO_BOOT",0)}</div>
  </div>
  <div class="card">
    <div class="label">CRASH</div>
    <div class="value">{fb.get("CRASH",0)}</div>
  </div>
  <div class="card">
    <div class="label">HANG_SHUTDOWN</div>
    <div class="value">{fb.get("HANG_SHUTDOWN",0)}</div>
  </div>
</div>

<!-- Charts -->
<div class="charts">
  <!-- Timeline -->
  <div class="chart-box full-width">
    <h2>Cycle Timeline — each dot = one cycle (hover for details)</h2>
    <canvas id="timelineChart"></canvas>
  </div>
  <!-- Boot time trend -->
  <div class="chart-box">
    <h2>Boot Time Trend (passing cycles)</h2>
    <canvas id="bootChart"></canvas>
  </div>
  <!-- Donut -->
  <div class="chart-box">
    <h2>Result Distribution</h2>
    <canvas id="donutChart"></canvas>
  </div>
</div>

<!-- Failure table -->
<div class="section-title">Failed Cycles Detail</div>
<table>
  <thead>
    <tr>
      <th>Cycle</th><th>Verdict</th><th>Power-ON time</th>
      <th>Boot time</th><th>Notes</th>
    </tr>
  </thead>
  <tbody>
    {fail_rows}
  </tbody>
</table>

<div class="meta">
  Generated from: {result.get("test_name","power_cycle")} &nbsp;|&nbsp;
  On-time: {cfg.get("on_time_sec","—")}s &nbsp;|&nbsp;
  Off-time: {cfg.get("off_time_sec","—")}s &nbsp;|&nbsp;
  Boot timeout: {cfg.get("boot_timeout_sec","—")}s
</div>

<script>
// ── Timeline chart ─────────────────────────────────────────────────────
new Chart(document.getElementById("timelineChart"), {{
  type: "scatter",
  data: {{ datasets: {timeline_ds} }},
  options: {{
    responsive: true,
    plugins: {{
      legend: {{ position: "top" }},
      tooltip: {{
        callbacks: {{
          label: ctx => `Cycle ${{ctx.parsed.x}} — ${{ctx.dataset.label}}`
        }}
      }}
    }},
    scales: {{
      x: {{ title: {{ display: true, text: "Cycle number" }} }},
      y: {{ display: false, min: 0, max: 2 }}
    }}
  }}
}});

// ── Boot time line chart ───────────────────────────────────────────────
new Chart(document.getElementById("bootChart"), {{
  type: "line",
  data: {{
    datasets: [{{
      label: "Boot time (s)",
      data: {boottime_pts},
      borderColor: "{_verdict_colour("PASS")}",
      backgroundColor: "{_verdict_colour("PASS")}22",
      fill: true,
      tension: 0.3,
      pointRadius: 3
    }}]
  }},
  options: {{
    responsive: true,
    plugins: {{ legend: {{ display: false }} }},
    scales: {{
      x: {{ title: {{ display: true, text: "Cycle number" }} }},
      y: {{ title: {{ display: true, text: "Seconds" }}, beginAtZero: true }}
    }}
  }}
}});

// ── Donut chart ────────────────────────────────────────────────────────
new Chart(document.getElementById("donutChart"), {{
  type: "doughnut",
  data: {{
    labels: {json.dumps(donut_labels)},
    datasets: [{{
      data: {json.dumps(donut_values)},
      backgroundColor: {json.dumps(donut_colours)},
      borderWidth: 2
    }}]
  }},
  options: {{
    responsive: true,
    plugins: {{ legend: {{ position: "bottom" }} }}
  }}
}});
</script>
</body>
</html>"""
