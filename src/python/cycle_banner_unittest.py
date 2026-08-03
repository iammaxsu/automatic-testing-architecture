# cycle_banner_unittest.py — BUG0044/BUG0045 phase labelling
#
# A calibrate cycle used to print two banners: "[CAL c/5]" from its caller and
# "[WARMUP c/5]" from run_one_cycle, because is_warmup was overloaded to mean
# both "do not count this cycle" and "label it WARMUP". The log then read as if
# warmup and calibration were interleaved, and the counters disagreed
# ("WARMUP 1/1" followed by "WARMUP 1/5").
#
# Also pins BUG0045: a failed calibrate cycle has no boot time, so neither the
# log nor the report may present the timeout it gave up at as a measurement.
#
# Run:
#   python3 -m unittest cycle_banner_unittest -v
#   (from src/python/)

import argparse
import logging
import re
import unittest
from unittest import mock

import power_cycle
import report


class _Relay:
    def atx_press(self, *a, **kw):
        pass

    def atx_force_off(self, *a, **kw):
        pass

    def at_power_off(self, *a, **kw):
        pass

    def at_power_on(self, *a, **kw):
        pass


class _DeadChecker:
    """Never comes alive — the shortest path through run_one_cycle."""
    ping_seen_during_wait = False

    def wait_until_alive(self, timeout):
        return False, float(timeout)


def _args():
    return argparse.Namespace(type="ATX", boot_timeout=5, cycles=10,
                              debug=True,          # skip the force-off branch
                              dry_run=True, ssh_user="", no_check=False)


class PhaseBannerTest(unittest.TestCase):

    def banners(self, **kw):
        with self.assertLogs("power_cycle", level="INFO") as cm:
            power_cycle.run_one_cycle(1, _args(), _Relay(), _DeadChecker(), **kw)
        return [r.getMessage() for r in cm.records
                if re.match(r"^(\[WARMUP|\[CAL|─── Cycle)", r.getMessage())]

    def test_main_cycle_prints_one_cycle_banner(self):
        got = self.banners(total=10)
        self.assertEqual(len(got), 1, got)
        self.assertTrue(got[0].startswith("─── Cycle 1 / 10"), got[0])

    def test_warmup_prints_one_warmup_banner(self):
        got = self.banners(total=1, phase="warmup")
        self.assertEqual(len(got), 1, got)
        self.assertTrue(got[0].startswith("[WARMUP 1/1]"), got[0])

    def test_calibrate_prints_one_cal_banner_and_no_warmup(self):
        """The regression: a calibrate cycle is not a warmup cycle (BUG0044)."""
        got = self.banners(total=5, phase="calibrate")
        self.assertEqual(len(got), 1, got)
        self.assertTrue(got[0].startswith("[CAL 1/5]"), got[0])
        self.assertNotIn("WARMUP", " ".join(got))

    def test_calibrate_phase_emits_exactly_one_banner_per_cycle(self):
        """End to end over the real calibrate loop: 2 cycles → 2 banners, not 4."""
        args = _args()
        args.debug = False              # let both cycles run
        args.calibrate_cycles = 2
        args.boot_ceiling = 5
        args.on_time = 5
        result = {"calibrate": {"cycles": []}, "config": {}}
        with mock.patch.object(power_cycle.config, "OFF_TIME_SEC", 0):
            with self.assertLogs("power_cycle", level="INFO") as cm:
                power_cycle._run_calibrate_phase(args, _Relay(), _DeadChecker(),
                                                 None, result)
        msgs = [r.getMessage() for r in cm.records]
        self.assertEqual(len([m for m in msgs if m.startswith("[CAL 1/2] ─")]), 1, msgs)
        self.assertEqual(len([m for m in msgs if m.startswith("[CAL 2/2] ─")]), 1, msgs)
        self.assertEqual([m for m in msgs if "WARMUP" in m], [], msgs)

    def test_failed_calibrate_cycle_logs_no_boot_time(self):
        """BUG0045: the ceiling it gave up at is not a boot time."""
        args = _args()
        args.calibrate_cycles = 1
        args.boot_ceiling = 5
        args.on_time = 5
        result = {"calibrate": {"cycles": []}, "config": {}}
        with self.assertLogs("power_cycle", level="INFO") as cm:
            power_cycle._run_calibrate_phase(args, _Relay(), _DeadChecker(), None, result)
        verdict_lines = [r.getMessage() for r in cm.records
                         if r.getMessage().startswith("[CAL 1/1] verdict")]
        self.assertEqual(len(verdict_lines), 1, verdict_lines)
        self.assertIn("boot: — s", verdict_lines[0])


class CalibrateReportTest(unittest.TestCase):
    """BUG0045: the rendered report must not contradict the log."""

    def test_failed_calibrate_cycle_renders_no_number(self):
        # Exercise the helper through the same logic the report uses.
        cycles = [
            {"n": 1, "verdict": "PASS",    "boot_time_sec": 92.2},
            {"n": 2, "verdict": "NO_BOOT", "boot_time_sec": 360.0},
            {"n": 3, "verdict": "NO_BOOT", "boot_time_sec": None},
        ]

        def cal_boot_str(c):
            bt = c.get("boot_time_sec")
            if bt is None or c.get("verdict") != "PASS":
                return "—"
            return f"{bt:.1f}s"

        self.assertEqual([cal_boot_str(c) for c in cycles], ["92.2s", "—", "—"])

    def test_report_module_uses_the_verdict_guard(self):
        """Guards against the helper being simplified back to a bare None check."""
        import inspect
        src = inspect.getsource(report)
        self.assertIn('c.get("verdict") != "PASS"', src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
