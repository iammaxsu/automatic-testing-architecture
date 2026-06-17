# report.py - HTML report generator for power_cycle / reboot result.json
#
# Renders a self-contained HTML file (Chart.js from CDN) from a canonical
# result.json (FWK028: result.json is the source of truth; this HTML is a
# derived view). The SAME renderer serves every endurance test that writes the
# shared result.json schema:
#   - power_cycle.py  (hardware power-loss recovery)
#   - reboot.py       (Pi-side SSH software reboot)
#   - reboot.ps1      (DUT-local reboot; writes result.json, rendered here)
#
# The report is built to surface ANOMALIES in large (1000+ cycle) runs at a
# glance, not just pass/fail counts:
#
#   1. Summary cards         - overall verdict, counts, and boot-time stats
#                              (min / median / p95 / p99 / max / std-dev),
#                              first-failure cycle, longest pass streak.
#   2. Boot-time chart        - raw per-cycle boot time, with:
#         * moving-average trend line   -> gradual degradation (thermal, FS,
#                                           journal bloat, leak across reboots)
#         * mean +/- 3 sigma band       -> instability / growing jitter
#         * red outlier points          -> one-off spikes (retry, fsck, DHCP)
#         * failure markers at baseline  -> do slow boots precede failures?
#   3. Boot-time histogram    - bimodal distribution (a fast path and a slow
#                              path that the mean would hide).
#   4. Failure-rate buckets   - per-bucket fail % + cumulative failures
#                              -> infant-mortality vs wear-out (bathtub),
#                                 and failure clustering in time.
#   5. Result distribution    - donut of pass / each failure type.
#   6. Failure detail table   - one row per failed cycle.
#
# Stdlib only (statistics, json) so it runs on a freshly installed Python on a
# Windows DUT with no extra packages.
#
# CLI:
#   python report.py <result.json> [output.html]
#   (output.html defaults to the result.json path with a .html suffix)

import json
import logging
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path

log = logging.getLogger(__name__)

# Colour map: verdict -> CSS colour. Covers every verdict any test emits.
_COLOUR = {
    "PASS":          "#4caf50",
    "NO_BOOT":       "#f44336",
    "CRASH":         "#ff9800",
    "HANG_SHUTDOWN": "#9c27b0",
    "RELAY_ERROR":   "#607d8b",
    "SSH_ERROR":     "#795548",
    "RUNNING":       "#2196f3",
    "FAIL":          "#f44336",
    "NO_DATA":       "#9e9e9e",
}

# Shutdown method colours: green = cleanest, orange = concerning, grey = unconfirmed.
_SHUTDOWN_METHOD_COLOUR = {
    "ssh":   "#4caf50",
    "atx":   "#2196f3",
    "force": "#ff9800",
    "time":  "#607d8b",
}

# Failure verdicts, in the order they appear in cards / donut / table.
_FAIL_ORDER = ["NO_BOOT", "CRASH", "HANG_SHUTDOWN", "RELAY_ERROR", "SSH_ERROR"]


def _verdict_colour(v: str) -> str:
    return _COLOUR.get(v, "#999")


def _format_duration(started: str, ended: str) -> str:
    """'Hh Mm Ss' between two LOG022-style timestamps ('-' if either is missing)."""
    try:
        delta_sec = (datetime.fromisoformat(ended) - datetime.fromisoformat(started)).total_seconds()
    except (TypeError, ValueError):
        return "-"
    if delta_sec < 0:
        return "-"
    h, rem = divmod(int(delta_sec), 3600)
    m, s   = divmod(rem, 60)
    return f"{h}h {m}m {s}s" if h else f"{m}m {s}s"


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
        raise


# -- analysis helpers ----------------------------------------------------------

def _pass_boot_series(cycles: list) -> list:
    """[(n, boot_time_sec)] for PASS cycles that recorded a boot time."""
    out = []
    for c in cycles:
        if c.get("verdict") == "PASS" and c.get("boot_time_sec") is not None:
            out.append((c["n"], float(c["boot_time_sec"])))
    return out


def _shutdown_series(cycles: list) -> list:
    """[(n, shutdown_time_sec)] for cycles that recorded a shutdown time (power_cycle only)."""
    out = []
    for c in cycles:
        if c.get("shutdown_time_sec") is not None:
            out.append((c["n"], float(c["shutdown_time_sec"])))
    return out


def _shutdown_method_counts(cycles: list) -> dict:
    """{method: count} for cycles that recorded a shutdown method (power_cycle only)."""
    counts: dict = {}
    for c in cycles:
        m = c.get("shutdown_method")
        if m:
            counts[m] = counts.get(m, 0) + 1
    return counts


def _boot_stats(values: list) -> dict:
    """Summary statistics for a list of boot-time floats. Empty-safe."""
    if not values:
        return {}
    s = {
        "count":  len(values),
        "min":    min(values),
        "max":    max(values),
        "mean":   statistics.mean(values),
        "median": statistics.median(values),
        "stddev": statistics.pstdev(values) if len(values) > 1 else 0.0,
    }
    # Percentiles need >= 2 points; fall back to max for tiny samples.
    if len(values) >= 2:
        q = statistics.quantiles(values, n=100, method="inclusive")
        s["p95"] = q[94]
        s["p99"] = q[98]
    else:
        s["p95"] = s["p99"] = values[0]
    return s


def _moving_average(series: list, window: int) -> list:
    """Centred-trailing moving average over [(n, y)] -> [(n, avg)]."""
    if not series:
        return []
    ys = [y for _, y in series]
    out = []
    for i, (n, _) in enumerate(series):
        lo = max(0, i - window + 1)
        chunk = ys[lo:i + 1]
        out.append((n, sum(chunk) / len(chunk)))
    return out


def _histogram(values: list, bins: int = 12) -> tuple:
    """Return (labels, counts) for a histogram of values."""
    if not values:
        return [], []
    lo, hi = min(values), max(values)
    if math.isclose(lo, hi):
        return [f"{lo:.1f}"], [len(values)]
    width = (hi - lo) / bins
    counts = [0] * bins
    for v in values:
        idx = int((v - lo) / width)
        if idx >= bins:
            idx = bins - 1
        counts[idx] += 1
    labels = [f"{lo + i * width:.1f}" for i in range(bins)]
    return labels, counts


def _failure_buckets(cycles: list, target_buckets: int = 20) -> dict:
    """Per-bucket fail %% and cumulative failures across the run timeline."""
    if not cycles:
        return {"labels": [], "fail_pct": [], "cumulative": []}
    total = len(cycles)
    size = max(1, math.ceil(total / target_buckets))
    labels, fail_pct, cumulative = [], [], []
    running_fail = 0
    i = 0
    while i < total:
        chunk = cycles[i:i + size]
        fails = sum(1 for c in chunk if c.get("verdict") != "PASS")
        running_fail += fails
        first_n = chunk[0]["n"]
        last_n  = chunk[-1]["n"]
        labels.append(f"{first_n}-{last_n}" if first_n != last_n else f"{first_n}")
        fail_pct.append(round(100.0 * fails / len(chunk), 1))
        cumulative.append(running_fail)
        i += size
    return {"labels": labels, "fail_pct": fail_pct, "cumulative": cumulative}


def _streaks(cycles: list) -> dict:
    """First-failure cycle, longest PASS streak, max consecutive failures."""
    first_fail = None
    longest_pass = cur_pass = 0
    max_fail = cur_fail = 0
    for c in cycles:
        if c.get("verdict") == "PASS":
            cur_pass += 1
            cur_fail = 0
            longest_pass = max(longest_pass, cur_pass)
        else:
            if first_fail is None:
                first_fail = c["n"]
            cur_fail += 1
            cur_pass = 0
            max_fail = max(max_fail, cur_fail)
    return {
        "first_fail":   first_fail,
        "longest_pass": longest_pass,
        "max_fail":     max_fail,
    }


# -- chart data builders (Chart.js JS literals) --------------------------------

def _boot_datasets(series: list, stats: dict, value_label: str = "Boot time (s)") -> str:
    """Datasets JS for a time-series chart (boot or shutdown): raw points
    (normal/outlier), moving average, and flat mean / +-3 sigma reference lines."""
    if not series:
        return "[]"

    mean = stats.get("mean", 0.0)
    sd   = stats.get("stddev", 0.0)
    hi3  = mean + 3 * sd
    lo3  = max(0.0, mean - 3 * sd)

    normal, outlier = [], []
    for n, y in series:
        pt = {"x": n, "y": round(y, 2)}
        if sd > 0 and (y > hi3 or y < lo3):
            outlier.append(pt)
        else:
            normal.append(pt)

    window = max(3, len(series) // 20)
    ma = [{"x": n, "y": round(y, 2)} for n, y in _moving_average(series, window)]

    xs = [n for n, _ in series]
    x_lo, x_hi = min(xs), max(xs)
    flat = lambda yv: json.dumps([{"x": x_lo, "y": round(yv, 2)},
                                  {"x": x_hi, "y": round(yv, 2)}])

    green = _verdict_colour("PASS")
    parts = [
        f'{{label:"{value_label}",type:"scatter",data:{json.dumps(normal)},'
        f'backgroundColor:"{green}",pointRadius:3,pointHoverRadius:5,order:3}}',
        f'{{label:"Moving avg (w={window})",type:"line",data:{json.dumps(ma)},'
        f'borderColor:"#2196f3",borderWidth:2,pointRadius:0,fill:false,'
        f'tension:0.25,order:1}}',
        f'{{label:"Mean",type:"line",data:{flat(mean)},borderColor:"#9e9e9e",'
        f'borderWidth:1,borderDash:[6,4],pointRadius:0,fill:false,order:2}}',
    ]
    if sd > 0:
        parts.append(
            f'{{label:"+3 sigma",type:"line",data:{flat(hi3)},borderColor:"#ff9800",'
            f'borderWidth:1,borderDash:[2,3],pointRadius:0,fill:false,order:2}}')
        parts.append(
            f'{{label:"-3 sigma",type:"line",data:{flat(lo3)},borderColor:"#ff9800",'
            f'borderWidth:1,borderDash:[2,3],pointRadius:0,fill:false,order:2}}')
    if outlier:
        parts.append(
            f'{{label:"Outlier (>3 sigma)",type:"scatter",data:{json.dumps(outlier)},'
            f'backgroundColor:"{_verdict_colour("NO_BOOT")}",pointRadius:6,'
            f'pointStyle:"rectRot",pointHoverRadius:8,order:0}}')

    # Failure markers are added separately by the caller (see _failure_markers,
    # concatenated in the chart's JS) so they overlay these datasets at y=0.
    return "[" + ",".join(parts) + "]"


def _failure_markers(cycles: list) -> str:
    pts = [{"x": c["n"], "y": 0} for c in cycles if c.get("verdict") != "PASS"]
    return json.dumps(pts)


def _fail_rows_html(cycles: list) -> str:
    rows = []
    for c in cycles:
        v = c.get("verdict", "")
        if v == "PASS":
            continue
        col   = _verdict_colour(v)
        cycle = c["n"]
        # Generic across tests: power_cycle uses t_power_on, reboot uses t_reboot_cmd.
        t_evt = c.get("t_power_on") or c.get("t_reboot_cmd") or c.get("t_start") or "-"
        boot  = f'{c["boot_time_sec"]:.1f}s' if c.get("boot_time_sec") is not None else "-"
        notes = c.get("notes") or ""
        rows.append(
            f'<tr>'
            f'<td>{cycle}</td>'
            f'<td style="color:{col};font-weight:600">{v}</td>'
            f'<td>{t_evt}</td>'
            f'<td>{boot}</td>'
            f'<td>{notes}</td>'
            f'</tr>'
        )
    if not rows:
        return '<tr><td colspan="5" style="text-align:center;color:#888">No failures</td></tr>'
    return "\n".join(rows)


# -- main renderer -------------------------------------------------------------

def _render(result: dict) -> str:
    cfg     = result.get("config", {})
    summary = result.get("summary", {})
    cycles  = result.get("cycles", [])

    test_name    = result.get("test_name", "endurance")
    title        = test_name.replace("_", " ").title() + " Test Report"
    overall      = result.get("overall_verdict", "-")
    overall_col  = _verdict_colour(overall)
    started      = result.get("started_at", "-")
    ended        = result.get("ended_at", "-")
    duration     = _format_duration(result.get("started_at"), result.get("ended_at"))
    total_ran    = summary.get("total_ran", len(cycles))
    total_target = summary.get("cycles_target", cfg.get("cycles_target", "-"))
    n_pass       = summary.get("pass", 0)
    n_fail       = summary.get("fail", 0)
    fb           = summary.get("fail_breakdown", {})

    # Analysis — boot time
    series   = _pass_boot_series(cycles)
    values   = [y for _, y in series]
    stats    = _boot_stats(values)
    streaks  = _streaks(cycles)
    boot_ds  = _boot_datasets(series, stats)
    fail_mk  = _failure_markers(cycles)
    hist_lbl, hist_cnt = _histogram(values)
    buckets  = _failure_buckets(cycles)
    fail_rows = _fail_rows_html(cycles)

    # Analysis — shutdown time + method (power_cycle only; empty for reboot)
    sd_series  = _shutdown_series(cycles)
    sd_values  = [y for _, y in sd_series]
    sd_stats   = _boot_stats(sd_values) if sd_values else {}
    sd_ds      = _boot_datasets(sd_series, sd_stats, "Shutdown time (s)") if sd_values else "[]"
    sd_fail_mk = _failure_markers(cycles)   # same failure positions
    method_counts = _shutdown_method_counts(cycles)
    has_shutdown  = bool(sd_series)
    has_methods   = bool(method_counts)

    # Donut (pass + each failure type actually present)
    donut_labels  = ["PASS"] + [k for k in _FAIL_ORDER if fb.get(k, 0) > 0]
    donut_values  = [n_pass] + [fb.get(k, 0) for k in _FAIL_ORDER if fb.get(k, 0) > 0]
    donut_colours = [_verdict_colour(v) for v in donut_labels]

    # Stat-card helpers
    def stat(key, unit="s"):
        if not stats:
            return "-"
        return f"{stats[key]:.1f}{unit}"

    first_fail   = streaks["first_fail"]
    first_fail_s = str(first_fail) if first_fail is not None else "none"

    # Per-failure-type cards (only those present), shown as a clearly separate
    # "breakdown of Fail" section so it's never mistaken for additional cycles.
    fail_breakdown_section = ""
    fail_cards = ""
    for k in _FAIL_ORDER:
        if fb.get(k, 0) > 0:
            fail_cards += (
                f'<div class="card"><div class="label">{k}</div>'
                f'<div class="value" style="color:{_verdict_colour(k)}">{fb[k]}</div></div>'
            )
    if fail_cards:
        fail_breakdown_section = f"""
<div class="section-title">Fail breakdown (sums to Fail = {n_fail} above)</div>
<div class="cards">
  {fail_cards}
</div>"""

    # Shutdown-time statistics cards (power_cycle only)
    def sdstat(key, unit="s"):
        if not sd_stats:
            return "-"
        return f"{sd_stats[key]:.1f}{unit}"

    shutdown_stats_section = ""
    if has_shutdown:
        shutdown_stats_section = f"""
<div class="section-title">Shutdown-time statistics (all cycles with confirmed shutdown)</div>
<div class="cards">
  <div class="card"><div class="label">Min</div><div class="value">{sdstat("min")}</div></div>
  <div class="card"><div class="label">Median</div><div class="value">{sdstat("median")}</div></div>
  <div class="card"><div class="label">Mean</div><div class="value">{sdstat("mean")}</div></div>
  <div class="card"><div class="label">p95</div><div class="value">{sdstat("p95")}</div></div>
  <div class="card"><div class="label">p99</div><div class="value">{sdstat("p99")}</div></div>
  <div class="card"><div class="label">Max</div><div class="value">{sdstat("max")}</div></div>
  <div class="card"><div class="label">Std-dev</div><div class="value">{sdstat("stddev")}</div></div>
</div>"""

    # Shutdown time chart + method distribution chart HTML (power_cycle only)
    shutdown_chart_html = ""
    if has_shutdown:
        shutdown_chart_html = """
  <div class="chart-box full-width">
    <h2>Shutdown time per cycle - trend, +/-3 sigma band, outliers, and failures (at baseline)</h2>
    <canvas id="shutdownChart"></canvas>
  </div>"""

    method_chart_html = ""
    if has_methods:
        method_chart_html = """
  <div class="chart-box">
    <h2>Shutdown method distribution (force = DUT failed to shut down gracefully)</h2>
    <canvas id="methodChart"></canvas>
  </div>"""

    # Build shutdown method chart data + conditional JS blocks
    method_labels  = list(method_counts.keys())
    method_values  = [method_counts[k] for k in method_labels]
    method_colours = [_SHUTDOWN_METHOD_COLOUR.get(k, "#999") for k in method_labels]

    method_js = ""
    if has_methods:
        method_js = (
            f'new Chart(document.getElementById("methodChart"), {{'
            f'  type:"doughnut",'
            f'  data:{{ labels:{json.dumps(method_labels)},'
            f'    datasets:[{{data:{json.dumps(method_values)},'
            f'                backgroundColor:{json.dumps(method_colours)},borderWidth:2}}] }},'
            f'  options:{{responsive:true,plugins:{{'
            f'    legend:{{position:"bottom"}},'
            f'    tooltip:{{callbacks:{{label:ctx=>`${{ctx.label}}: ${{ctx.parsed}} cycles '
            f'(${{Math.round(ctx.parsed/ctx.dataset.data.reduce((a,b)=>a+b,0)*100)}}%)`}}}}'
            f'  }}}}'
            f'}});'
        )

    shutdown_js = ""
    if has_shutdown:
        sd_fail_json = _failure_markers(cycles)
        no_boot_col  = _verdict_colour("NO_BOOT")
        shutdown_js = (
            f'new Chart(document.getElementById("shutdownChart"), {{'
            f'  data:{{ datasets: {sd_ds}.concat([{{'
            f'    label:"Failure", type:"scatter", data:{sd_fail_json},'
            f'    backgroundColor:"{no_boot_col}", pointStyle:"crossRot",'
            f'    pointRadius:7, pointHoverRadius:9, order:0'
            f'  }}]) }},'
            f'  options:{{'
            f'    responsive:true,'
            f'    interaction:{{mode:"nearest",intersect:true}},'
            f'    plugins:{{'
            f'      legend:{{position:"top"}},'
            f'      tooltip:{{callbacks:{{label:ctx=>`${{ctx.dataset.label}}: '
            f'cycle ${{ctx.parsed.x}}, ${{ctx.parsed.y}}`}}}}'
            f'    }},'
            f'    scales:{{'
            f'      x:{{title:{{display:true,text:"Cycle number"}},type:"linear"}},'
            f'      y:{{title:{{display:true,text:"Seconds"}},beginAtZero:true}}'
            f'    }}'
            f'  }}'
            f'}});'
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title} - {started[:10]}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
  *{{box-sizing:border-box;margin:0;padding:0}}
  body{{font-family:sans-serif;background:#f4f6f8;color:#333;padding:20px}}
  h1{{font-size:1.6rem;margin-bottom:4px}}
  .subtitle{{color:#666;font-size:.9rem;margin-bottom:20px}}
  .cards{{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:24px}}
  .card{{background:#fff;border-radius:8px;padding:14px 18px;min-width:120px;
         box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  .card .label{{font-size:.72rem;color:#888;text-transform:uppercase;letter-spacing:.05em}}
  .card .value{{font-size:1.6rem;font-weight:700;margin-top:4px}}
  .verdict-badge{{display:inline-block;padding:4px 14px;border-radius:4px;
                  color:#fff;font-size:1rem;font-weight:600}}
  .section-title{{font-size:1.1rem;font-weight:600;margin:24px 0 10px}}
  .charts{{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px}}
  .chart-box{{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  .chart-box h2{{font-size:.95rem;margin-bottom:10px;color:#555}}
  canvas{{max-height:300px}}
  .full-width{{grid-column:1/-1}}
  table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
         overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.1)}}
  th{{background:#37474f;color:#fff;padding:10px 14px;text-align:left;font-size:.85rem}}
  td{{padding:9px 14px;font-size:.85rem;border-bottom:1px solid #eee}}
  tr:last-child td{{border-bottom:none}}
  tr:hover td{{background:#fafafa}}
  .meta{{color:#888;font-size:.8rem;margin-top:20px}}
</style>
</head>
<body>

<h1>{title}</h1>
<p class="subtitle">
  {cfg.get("power_type", test_name)} &nbsp;|&nbsp;
  DUT: {cfg.get("dut_host") or "(liveness disabled)"} &nbsp;|&nbsp;
  Started: {started} &nbsp;|&nbsp; Ended: {ended} &nbsp;|&nbsp; Duration: {duration}
</p>

<!-- Summary + verdict cards -->
<div class="cards">
  <div class="card">
    <div class="label">Overall</div>
    <div class="value"><span class="verdict-badge" style="background:{overall_col}">{overall}</span></div>
  </div>
  <div class="card"><div class="label">Cycles ran</div>
    <div class="value">{total_ran} <span style="font-size:.9rem;color:#888">/ {total_target}</span></div></div>
  <div class="card"><div class="label">Pass</div>
    <div class="value" style="color:{_verdict_colour("PASS")}">{n_pass}</div></div>
  <div class="card"><div class="label">Fail</div>
    <div class="value" style="color:{_verdict_colour("NO_BOOT")}">{n_fail}</div></div>
</div>

{fail_breakdown_section}

<!-- Boot-time statistics cards -->
<div class="section-title">Boot-time statistics (passing cycles with recorded boot time)</div>
<div class="cards">
  <div class="card"><div class="label">Min</div><div class="value">{stat("min")}</div></div>
  <div class="card"><div class="label">Median</div><div class="value">{stat("median")}</div></div>
  <div class="card"><div class="label">Mean</div><div class="value">{stat("mean")}</div></div>
  <div class="card"><div class="label">p95</div><div class="value">{stat("p95")}</div></div>
  <div class="card"><div class="label">p99</div><div class="value">{stat("p99")}</div></div>
  <div class="card"><div class="label">Max</div><div class="value">{stat("max")}</div></div>
  <div class="card"><div class="label">Std-dev</div><div class="value">{stat("stddev")}</div></div>
  <div class="card"><div class="label">First fail @</div><div class="value">{first_fail_s}</div></div>
  <div class="card"><div class="label">Longest pass</div><div class="value">{streaks["longest_pass"]}</div></div>
  <div class="card"><div class="label">Max consec. fail</div><div class="value">{streaks["max_fail"]}</div></div>
</div>

<!-- Charts -->
<div class="charts">
  <div class="chart-box full-width">
    <h2>Boot time per cycle - trend, +/-3 sigma band, outliers, and failures (at baseline)</h2>
    <canvas id="bootChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Boot-time distribution (look for two peaks)</h2>
    <canvas id="histChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Failure rate per bucket + cumulative failures</h2>
    <canvas id="bucketChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Result distribution</h2>
    <canvas id="donutChart"></canvas>
  </div>
  {method_chart_html}
  {shutdown_chart_html}
</div>

{shutdown_stats_section}

<!-- Failure table -->
<div class="section-title">Failed cycles detail</div>
<table>
  <thead><tr><th>Cycle</th><th>Verdict</th><th>Event time</th><th>Boot time</th><th>Notes</th></tr></thead>
  <tbody>
    {fail_rows}
  </tbody>
</table>

<div class="meta">
  Generated from: {test_name} &nbsp;|&nbsp;
  Boot timeout: {cfg.get("boot_timeout_sec", "-")}s &nbsp;|&nbsp;
  Off-time: {cfg.get("off_time_sec", "-")}s
</div>

<script>
// -- Boot-time chart (scatter + trend + band + outliers + failure markers) --
new Chart(document.getElementById("bootChart"), {{
  data: {{ datasets: {boot_ds}.concat([{{
    label:"Failure", type:"scatter", data:{fail_mk},
    backgroundColor:"{_verdict_colour("NO_BOOT")}", pointStyle:"crossRot",
    pointRadius:7, pointHoverRadius:9, order:0
  }}]) }},
  options: {{
    responsive:true,
    interaction:{{mode:"nearest",intersect:true}},
    plugins:{{
      legend:{{position:"top"}},
      tooltip:{{callbacks:{{label:ctx=>`${{ctx.dataset.label}}: cycle ${{ctx.parsed.x}}, ${{ctx.parsed.y}}`}}}}
    }},
    scales:{{
      x:{{title:{{display:true,text:"Cycle number"}},type:"linear"}},
      y:{{title:{{display:true,text:"Seconds"}},beginAtZero:true}}
    }}
  }}
}});

// -- Histogram --
new Chart(document.getElementById("histChart"), {{
  type:"bar",
  data:{{ labels:{json.dumps(hist_lbl)},
          datasets:[{{label:"Cycles",data:{json.dumps(hist_cnt)},
                      backgroundColor:"{_verdict_colour('PASS')}"}}] }},
  options:{{responsive:true,plugins:{{legend:{{display:false}}}},
    scales:{{x:{{title:{{display:true,text:"Boot time bin (s)"}}}},
             y:{{title:{{display:true,text:"Count"}},beginAtZero:true}}}}}}
}});

// -- Failure buckets (bar = fail %, line = cumulative) --
new Chart(document.getElementById("bucketChart"), {{
  data:{{ labels:{json.dumps(buckets["labels"])},
    datasets:[
      {{type:"bar",label:"Fail % in bucket",data:{json.dumps(buckets["fail_pct"])},
        backgroundColor:"{_verdict_colour('NO_BOOT')}",yAxisID:"y"}},
      {{type:"line",label:"Cumulative failures",data:{json.dumps(buckets["cumulative"])},
        borderColor:"#9c27b0",borderWidth:2,pointRadius:2,fill:false,yAxisID:"y1"}}
    ] }},
  options:{{responsive:true,
    scales:{{
      x:{{title:{{display:true,text:"Cycle bucket"}}}},
      y:{{position:"left",title:{{display:true,text:"Fail %"}},beginAtZero:true,max:100}},
      y1:{{position:"right",title:{{display:true,text:"Cumulative fails"}},
           beginAtZero:true,grid:{{drawOnChartArea:false}}}}
    }}}}
}});

// -- Donut --
new Chart(document.getElementById("donutChart"), {{
  type:"doughnut",
  data:{{ labels:{json.dumps(donut_labels)},
    datasets:[{{data:{json.dumps(donut_values)},
                backgroundColor:{json.dumps(donut_colours)},borderWidth:2}}] }},
  options:{{responsive:true,plugins:{{legend:{{position:"bottom"}}}}}}
}});

// -- Shutdown method distribution (power_cycle only, omitted for reboot) --
{method_js}

// -- Shutdown time chart (power_cycle only, omitted for reboot) --
{shutdown_js}
</script>
</body>
</html>"""


# -- CLI -----------------------------------------------------------------------

def main(argv=None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print("Usage: python report.py <result.json> [output.html]")
        return 0 if argv else 1

    in_path = Path(argv[0])
    if not in_path.is_file():
        print(f"ERROR: not found: {in_path}")
        return 1

    out_path = Path(argv[1]) if len(argv) > 1 else in_path.with_suffix(".html")
    try:
        # utf-8-sig strips a leading BOM if present (PowerShell 5.1's
        # Set-Content -Encoding UTF8 writes one) and is a no-op otherwise,
        # so the same renderer reads JSON from reboot.ps1 and reboot.py alike.
        with open(in_path, encoding="utf-8-sig") as f:
            result = json.load(f)
    except Exception as exc:
        print(f"ERROR: cannot read JSON {in_path}: {exc}")
        return 1

    generate_report(result, str(out_path))
    print(f"Report written: {out_path}")
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    sys.exit(main())
