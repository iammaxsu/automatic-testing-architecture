# BMCLibrary.py - Robot Framework keyword library for out-of-band BMC
# testing via ipmitool.
#
# Mirrors the detection semantics of src/bash-shell/bmc_sensor_test.sh:
#   - baseline-relative comparison: the first successful poll defines the
#     expected sensor set and per-sensor status; pre-existing non-ok
#     sensors (e.g. unpopulated fan headers reading `nr`) do not fail,
#     only *changes* do
#   - threshold sensors compare status only (values fluctuate by nature);
#     discrete sensors compare value+status as one state string
#   - SEL entry-count watching across the suite / soak window
#   - every ipmitool call wrapped in timeout + retries
#
# Canonical soak data is written to CSV (FWK028); Robot's log.html /
# report.html are the derived human-readable views.
#
# Security: the IPMI password is read from the IPMI_PASSWORD environment
# variable and passed to ipmitool via -E, never on a command line.
# IPMITOOL_BIN overrides the binary so the suite can run against a mock.
#
# Changelog:
#   00.00.01  Initial version

import csv
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    from robot.api import logger
except ImportError:  # allow plain `python3 -c "import BMCLibrary"` unit testing
    import logging

    logger = logging.getLogger("BMCLibrary")
    logger.warn = logger.warning
    if not logger.handlers:
        logging.basicConfig(level=logging.INFO)


class BMCLibrary:
    """Keywords for IPMI sensor / SEL testing against one BMC."""

    ROBOT_LIBRARY_SCOPE = "SUITE"
    ROBOT_LIBRARY_VERSION = "00.00.01"

    def __init__(self, host=None, user=None, interface="lanplus",
                 timeout=60, retries=3, retry_delay=5):
        self._host = host or None
        self._user = user or None
        self._iface = interface
        self._timeout = int(timeout)
        self._retries = int(retries)
        self._retry_delay = float(retry_delay)
        self._baseline = None        # name -> state string
        self._sel_baseline = None

    # ---------- low-level ----------

    def run_ipmitool(self, *args):
        """Run one ipmitool command with timeout + retries; return stdout.

        Fails (raises) only after all retries are exhausted, so transient
        lanplus session errors do not fail a test on their own.
        """
        if not self._host or not self._user:
            raise RuntimeError(
                "BMC host/user not configured - pass -v BMC_HOST:<ip> -v BMC_USER:<user>")
        if not os.environ.get("IPMI_PASSWORD"):
            raise RuntimeError("IPMI_PASSWORD environment variable is not set")
        binary = os.environ.get("IPMITOOL_BIN", "ipmitool")
        cmd = [binary, "-I", self._iface, "-H", self._host,
               "-U", self._user, "-E"] + [str(a) for a in args]
        last_err = None
        for attempt in range(1, self._retries + 1):
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      timeout=self._timeout)
                if proc.returncode == 0 and proc.stdout.strip():
                    if attempt > 1:
                        logger.warn("ipmitool %s needed %d attempts"
                                    % (" ".join(map(str, args)), attempt))
                    return proc.stdout
                last_err = "rc=%s stderr=%s" % (
                    proc.returncode, proc.stderr.strip()[:200])
            except subprocess.TimeoutExpired:
                last_err = "timeout after %ds" % self._timeout
            if attempt < self._retries:
                time.sleep(self._retry_delay)
        raise RuntimeError("ipmitool %s failed after %d attempts (%s)"
                           % (" ".join(map(str, args)), self._retries, last_err))

    # ---------- parsing ----------

    @staticmethod
    def _parse_sensor_list(output):
        sensors = []
        for line in output.splitlines():
            if "|" not in line:
                continue
            f = [p.strip() for p in line.split("|")]
            if len(f) < 4 or not f[0] or not f[3]:
                continue
            name, value, unit, status = f[0].replace(",", "_"), f[1], f[2], f[3]
            state = "%s/%s" % (value, status) if unit == "discrete" else status
            sensors.append({"name": name, "value": value, "unit": unit,
                            "status": status, "state": state})
        return sensors

    @staticmethod
    def _diff_states(prev_map, sensors):
        """Differences between a {name: state} map and a fresh reading."""
        diffs = []
        curr = {s["name"]: s for s in sensors}
        for name, s in curr.items():
            if name not in prev_map:
                diffs.append("sensor appeared: %s (state=%s)" % (name, s["state"]))
            elif prev_map[name] != s["state"]:
                diffs.append("status change: %s: %s -> %s (value=%s)"
                             % (name, prev_map[name], s["state"], s["value"]))
        for name in prev_map:
            if name not in curr:
                diffs.append("sensor disappeared: %s (was %s)" % (name, prev_map[name]))
        return diffs

    # ---------- keywords ----------

    def get_sensor_readings(self):
        """Poll `sensor list`; return a list of dicts (name/value/unit/status/state)."""
        sensors = self._parse_sensor_list(self.run_ipmitool("sensor", "list"))
        if not sensors:
            raise RuntimeError("sensor list returned no parsable rows")
        return sensors

    def get_sel_entry_count(self):
        """Return the SEL entry count from `sel info`."""
        out = self.run_ipmitool("sel", "info")
        for line in out.splitlines():
            if line.strip().lower().startswith("entries"):
                digits = "".join(c for c in line.split(":", 1)[-1] if c.isdigit())
                if digits:
                    return int(digits)
        raise RuntimeError("cannot parse SEL entry count from `sel info` output")

    def establish_sensor_baseline(self):
        """Suite Setup: capture expected sensor set/status and SEL count."""
        sensors = self.get_sensor_readings()
        self._baseline = {s["name"]: s["state"] for s in sensors}
        nonok = [
            "%s=%s" % (s["name"], s["status"]) for s in sensors
            if s["unit"] != "discrete" and s["status"] != "ok"
        ]
        self._sel_baseline = self.get_sel_entry_count()
        logger.info("baseline: %d sensors; non-ok at start: %s; SEL entries: %d"
                    % (len(sensors), ", ".join(nonok) if nonok else "none",
                       self._sel_baseline))
        return len(sensors)

    def get_baseline_sensor_count(self):
        """Number of sensors captured by `Establish Sensor Baseline`."""
        if self._baseline is None:
            raise RuntimeError("no baseline - run Establish Sensor Baseline first")
        return len(self._baseline)

    def sensor_states_should_match_baseline(self):
        """Fail listing every sensor that changed status, appeared or disappeared."""
        if self._baseline is None:
            raise RuntimeError("no baseline - run Establish Sensor Baseline first")
        diffs = self._diff_states(self._baseline, self.get_sensor_readings())
        if diffs:
            raise AssertionError("%d sensor difference(s) vs baseline:\n  %s"
                                 % (len(diffs), "\n  ".join(diffs)))

    def sel_entry_count_should_be_stable(self):
        """Fail if the SEL entry count differs from the suite-setup baseline."""
        if self._sel_baseline is None:
            raise RuntimeError("no baseline - run Establish Sensor Baseline first")
        now = self.get_sel_entry_count()
        if now != self._sel_baseline:
            raise AssertionError("SEL entry count changed %d -> %d"
                                 % (self._sel_baseline, now))

    def run_sensor_soak(self, cycles=10, interval=5, output_dir=".",
                        max_comm_fail_pct=1):
        """Poll every `interval` seconds for `cycles` cycles.

        Writes every reading to <output_dir>/bmc_sensor_soak_samples.csv
        (canonical, FWK028) and fails listing every anomaly:
        status transitions / sensor-set changes between consecutive
        cycles, SEL growth over the soak window, and a comm-failure rate
        above `max_comm_fail_pct` percent. Transient read failures are
        retried and never abort the soak.
        """
        cycles = int(cycles)
        interval = float(interval)
        max_comm_fail_pct = float(max_comm_fail_pct)
        anomalies = []
        comm_fails = 0
        prev = dict(self._baseline) if self._baseline else None
        sel_start = self.get_sel_entry_count()

        csv_path = Path(output_dir) / "bmc_sensor_soak_samples.csv"
        new_file = not csv_path.exists()
        t0 = time.monotonic()
        with open(csv_path, "a", newline="") as fh:
            writer = csv.writer(fh)
            if new_file:
                writer.writerow(
                    ["timestamp", "cycle", "sensor", "value", "unit", "status"])
            for cycle in range(1, cycles + 1):
                ts = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
                try:
                    sensors = self.get_sensor_readings()
                except RuntimeError as exc:
                    comm_fails += 1
                    logger.warn("cycle %d: %s" % (cycle, exc))
                else:
                    for s in sensors:
                        writer.writerow([ts, cycle, s["name"], s["value"],
                                         s["unit"], s["status"]])
                    fh.flush()
                    if prev is not None:
                        for d in self._diff_states(prev, sensors):
                            anomalies.append("cycle %d: %s" % (cycle, d))
                            logger.warn("cycle %d: %s" % (cycle, d))
                    prev = {s["name"]: s["state"] for s in sensors}
                if cycle % 60 == 0:
                    logger.info("heartbeat: cycle %d/%d, comm_fails %d, anomalies %d"
                                % (cycle, cycles, comm_fails, len(anomalies)))
                # Drift-corrected wait: cycle N starts at t0 + N*interval.
                if cycle < cycles:
                    wait_s = t0 + cycle * interval - time.monotonic()
                    if wait_s > 0:
                        time.sleep(wait_s)

        sel_end = self.get_sel_entry_count()
        if sel_end != sel_start:
            anomalies.append("SEL entry count changed %d -> %d during soak"
                             % (sel_start, sel_end))
        fail_pct = comm_fails * 100.0 / cycles if cycles else 0.0
        if fail_pct > max_comm_fail_pct:
            anomalies.append("comm failure rate %.2f%% exceeds %.2f%% (%d/%d cycles)"
                             % (fail_pct, max_comm_fail_pct, comm_fails, cycles))

        logger.info("soak done: %d cycles, comm_fails %d (%.2f%%), anomalies %d, "
                    "SEL %d -> %d, samples: %s"
                    % (cycles, comm_fails, fail_pct, len(anomalies),
                       sel_start, sel_end, csv_path))
        if anomalies:
            raise AssertionError("%d anomalies during soak:\n  %s"
                                 % (len(anomalies), "\n  ".join(anomalies)))
        return {"cycles": cycles, "comm_fails": comm_fails,
                "sel_start": sel_start, "sel_end": sel_end,
                "samples_csv": str(csv_path)}
