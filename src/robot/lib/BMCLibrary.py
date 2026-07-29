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
# Engine note: after the src/robot/spike evaluation, out-of-band IPMI is
# driven by wrapping the ipmitool CLI (not python-ipmi / the Kontron
# robotframework-ipmilibrary, whose native + ipmitool-backend paths both
# failed to decode this BMC's responses). See docs/architecture.md.
#
# Changelog:
#   00.00.01  Initial version
#   00.00.02  Phase 1 functional keywords: device id (mc info), IPMI
#             version / chassis power status, sensor-by-name assertions,
#             SEL entry-list parsing. All read-only (safe on a live DUT).
#   00.00.03  Phase 1 areas: FRU inventory, SDR repository info, LAN
#             configuration, user list. All read-only.

import csv
import os
import re
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
    ROBOT_LIBRARY_VERSION = "00.00.03"

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

    @staticmethod
    def _parse_key_value(output):
        """Parse ``Label : Value`` output (``mc info``, ``chassis status``).

        Returns an ordered dict keyed by the exact label. Indented
        continuation lines (e.g. the ``Additional Device Support`` list in
        ``mc info``) have no colon and are skipped.
        """
        result = {}
        for line in output.splitlines():
            if ":" not in line or line[:1].isspace():
                continue
            key, value = line.split(":", 1)
            key = key.strip()
            if key:
                result[key] = value.strip()
        return result

    @staticmethod
    def _parse_sel_elist(output):
        """Parse ``sel elist`` into a list of dicts (empty list if no entries)."""
        entries = []
        for line in output.splitlines():
            line = line.strip()
            if not line or "|" not in line:
                continue  # e.g. "SEL has no entries"
            f = [p.strip() for p in line.split("|")]
            entries.append({
                "id": f[0],
                "date": f[1] if len(f) > 1 else "",
                "time": f[2] if len(f) > 2 else "",
                "sensor": f[3] if len(f) > 3 else "",
                "event": f[4] if len(f) > 4 else "",
                "direction": f[5] if len(f) > 5 else "",
                "raw": line,
            })
        return entries

    @staticmethod
    def _parse_fru(output):
        """Parse ``fru print`` (indented ``Key : Value``) into a dict.

        Unlike ``_parse_key_value`` this keeps indented lines (FRU fields are
        indented). With multiple FRU devices the last value per key wins,
        which is fine for the presence/identity checks below.
        """
        result = {}
        for line in output.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            key = key.strip()
            if key:
                result[key] = value.strip()
        return result

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

    # ---------- Phase 1 functional keywords (read-only) ----------
    # Coverage modelled on the openbmc-test-automation and Arm SBMR-ACS IPMI
    # suites, implemented over the ipmitool CLI. Everything here is read-only
    # and safe to run against a live DUT: no power control, no config writes.

    def get_bmc_info(self):
        """Return the Management Controller info dict from ``mc info``.

        Keys are the ipmitool labels, e.g. "Device ID", "Firmware Revision",
        "IPMI Version", "Manufacturer ID", "Product ID".
        """
        info = self._parse_key_value(self.run_ipmitool("mc", "info"))
        if not info:
            raise RuntimeError("`mc info` returned no parsable fields")
        return info

    def bmc_should_be_reachable(self):
        """Fail unless the BMC answers ``mc info`` with a Device ID."""
        info = self.get_bmc_info()
        if "Device ID" not in info:
            raise AssertionError("BMC responded but `mc info` has no Device ID: %s"
                                 % ", ".join(info) or "empty")
        logger.info("BMC reachable: %s / firmware %s / IPMI %s"
                    % (info.get("Device ID"), info.get("Firmware Revision"),
                       info.get("IPMI Version")))
        return info

    def ipmi_version_should_be(self, expected):
        """Fail unless ``mc info`` reports the given IPMI version (e.g. 2.0)."""
        actual = self.get_bmc_info().get("IPMI Version")
        if actual != str(expected):
            raise AssertionError("IPMI version is %r, expected %r"
                                 % (actual, str(expected)))

    def get_sensor(self, name):
        """Return one sensor's dict by name (case-insensitive); fail if absent."""
        wanted = name.strip().lower()
        for s in self.get_sensor_readings():
            if s["name"].lower() == wanted:
                return s
        raise AssertionError("sensor %r not found in sensor list" % name)

    def sensor_should_be_present(self, name):
        """Fail unless a sensor with the given name exists."""
        self.get_sensor(name)

    def sensor_status_should_be(self, name, expected):
        """Fail unless the named sensor's status equals ``expected`` (e.g. ok)."""
        s = self.get_sensor(name)
        if s["status"] != str(expected):
            raise AssertionError("sensor %s status is %r (value=%s), expected %r"
                                 % (name, s["status"], s["value"], str(expected)))

    def sensor_reading_should_be_between(self, name, low, high):
        """Fail unless the named sensor's numeric reading is within [low, high]."""
        s = self.get_sensor(name)
        try:
            value = float(s["value"])
        except ValueError:
            raise AssertionError("sensor %s reads %r (status=%s), not a number"
                                 % (name, s["value"], s["status"]))
        if not (float(low) <= value <= float(high)):
            raise AssertionError("sensor %s = %s %s, outside [%s, %s]"
                                 % (name, s["value"], s["unit"], low, high))

    def get_chassis_status(self):
        """Return the chassis status dict from ``chassis status``."""
        status = self._parse_key_value(self.run_ipmitool("chassis", "status"))
        if "System Power" not in status:
            raise RuntimeError("`chassis status` has no System Power field")
        return status

    def chassis_power_should_be_on(self):
        """Fail unless ``chassis status`` reports System Power = on."""
        power = self.get_chassis_status().get("System Power")
        if power != "on":
            raise AssertionError("chassis System Power is %r, expected 'on'" % power)

    def get_sel_entries(self):
        """Return SEL entries as a list of dicts (empty list if none)."""
        return self._parse_sel_elist(self.run_ipmitool("sel", "elist"))

    def sel_should_be_readable(self):
        """Fail unless the SEL can be read (``sel info`` returns a count)."""
        count = self.get_sel_entry_count()
        logger.info("SEL readable: %d entries" % count)
        return count

    # -- FRU (fru print) --

    def get_fru_info(self, fru_id=0):
        """Return the FRU inventory dict from ``fru print <id>``."""
        info = self._parse_fru(self.run_ipmitool("fru", "print", str(fru_id)))
        if not info:
            raise RuntimeError("`fru print %s` returned no parsable fields" % fru_id)
        return info

    def fru_should_be_readable(self, fru_id=0):
        """Fail unless FRU inventory reads back with a Board or Product field."""
        info = self.get_fru_info(fru_id)
        if not any(k.startswith("Board") or k.startswith("Product") for k in info):
            raise AssertionError("FRU %s has no Board/Product fields: %s"
                                 % (fru_id, ", ".join(info) or "empty"))
        return info

    def fru_should_have_identity(self, fru_id=0):
        """Fail unless at least one FRU identity field is present and non-empty.

        Lenient by design: boards vary in which of Board Mfg / Board Product /
        Product Manufacturer / Product Name they populate.
        """
        info = self.get_fru_info(fru_id)
        fields = ("Board Mfg", "Board Product", "Product Manufacturer",
                  "Product Name")
        present = {f: info[f] for f in fields if info.get(f)}
        if not present:
            raise AssertionError("FRU %s has no non-empty identity field (%s)"
                                 % (fru_id, ", ".join(fields)))
        logger.info("FRU %s identity: %s" % (fru_id, present))
        return present

    def fru_field_should_not_be_empty(self, field, fru_id=0):
        """Fail unless the named FRU field is present and non-empty."""
        value = self.get_fru_info(fru_id).get(field)
        if not value:
            raise AssertionError("FRU field %r is missing or empty (fru %s)"
                                 % (field, fru_id))
        return value

    # -- SDR repository (sdr info) --

    def get_sdr_repository_info(self):
        """Return the SDR repository info dict from ``sdr info``."""
        info = self._parse_key_value(self.run_ipmitool("sdr", "info"))
        if not info:
            raise RuntimeError("`sdr info` returned no parsable fields")
        return info

    def sdr_repository_should_be_populated(self):
        """Fail unless the SDR repository reports at least one record."""
        info = self.get_sdr_repository_info()
        raw = info.get("Record Count") or info.get("Record count")
        digits = "".join(c for c in (raw or "") if c.isdigit())
        if not digits:
            raise AssertionError("cannot find SDR Record Count in: %s"
                                 % ", ".join(info))
        count = int(digits)
        if count < 1:
            raise AssertionError("SDR repository is empty (Record Count=%d)" % count)
        logger.info("SDR repository: %d records" % count)
        return count

    # -- LAN configuration (lan print) --

    def get_lan_config(self, channel=1):
        """Return the LAN configuration dict from ``lan print <channel>``."""
        info = self._parse_key_value(self.run_ipmitool("lan", "print", str(channel)))
        if not info:
            raise RuntimeError("`lan print %s` returned no parsable fields" % channel)
        return info

    def lan_should_have_ip_address(self, channel=1):
        """Fail unless the BMC LAN channel reports a non-zero IPv4 address."""
        ip = self.get_lan_config(channel).get("IP Address", "")
        if not ip or ip == "0.0.0.0":
            raise AssertionError("BMC LAN channel %s has no IP address (got %r)"
                                 % (channel, ip))
        logger.info("BMC LAN channel %s IP: %s" % (channel, ip))
        return ip

    def lan_mac_should_be_valid(self, channel=1):
        """Fail unless the BMC LAN channel reports a valid, non-zero MAC."""
        mac = self.get_lan_config(channel).get("MAC Address", "")
        if (not re.match(r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", mac)
                or mac.lower() == "00:00:00:00:00:00"):
            raise AssertionError("BMC LAN channel %s MAC invalid (got %r)"
                                 % (channel, mac))
        return mac

    # -- Users (user list) --

    def get_user_list(self, channel=1):
        """Return the raw ``user list <channel>`` table."""
        return self.run_ipmitool("user", "list", str(channel))

    def user_list_should_be_readable(self, channel=1):
        """Fail unless ``user list`` returns a table with an ID/Name header."""
        out = self.get_user_list(channel)
        if "ID" not in out or "Name" not in out:
            raise AssertionError("`user list %s` did not return a user table:\n%s"
                                 % (channel, out.strip()[:200]))
        return out

    def user_should_be_present(self, name, channel=1):
        """Fail unless a user row with the given name (2nd column) exists."""
        for line in self.get_user_list(channel).splitlines():
            cols = line.split()
            if len(cols) >= 2 and cols[0].isdigit() and cols[1] == name:
                return
        raise AssertionError("user %r not found in `user list %s`" % (name, channel))
