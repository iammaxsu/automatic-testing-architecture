# force_off_unittest.py — BUG0066 force-off escalation and honest recording
#
# The relay is an output only: the framework can command a force-off but cannot
# observe whether the DUT powered down. Two consequences are pinned here.
#
# 1. A force-off that follows a cycle which already failed to boot is held
#    longer. Repeating an unverifiable action unchanged is how a run spends 27
#    cycles and 1.5 hours learning nothing; escalating makes the next run
#    evidence either way.
# 2. The cycle record states the hold that was COMMANDED. It must never grow a
#    field that implies the DUT's power state was observed, because it wasn't.
#
# Run:
#   python3 -m unittest force_off_unittest -v
#   (from src/python/)

import argparse
import unittest
from unittest import mock

import config
import power_cycle


class _Relay:
    """Records the hold times it was asked for."""

    def __init__(self):
        self.holds = []

    def atx_press(self, *a, **kw):
        pass

    def atx_force_off(self, duration=5.0):
        self.holds.append(duration)

    def at_power_off(self):
        self.holds.append("at")

    def at_power_on(self):
        pass


class _DeadChecker:
    ping_seen_during_wait = False

    def wait_until_alive(self, timeout):
        return False, float(timeout)


def _args(**kw):
    a = argparse.Namespace(type="ATX", boot_timeout=1, cycles=10, debug=False,
                           dry_run=True, ssh_user="", no_check=False,
                           force_off_escalate=10.0)
    for k, v in kw.items():
        setattr(a, k, v)
    return a


def _run(result, args=None):
    relay = _Relay()
    with mock.patch.object(config, "OFF_TIME_SEC", 0):
        rec = power_cycle.run_one_cycle(1, args or _args(), relay, _DeadChecker(),
                                        None, total=10, result=result)
    return rec, relay


class ForceOffEscalationTest(unittest.TestCase):

    def test_first_no_boot_uses_the_normal_hold(self):
        rec, relay = _run({"cycles": []})
        self.assertEqual(relay.holds, [config.ATX_LONG_PRESS_SEC])
        self.assertEqual(rec["force_off_sec"], config.ATX_LONG_PRESS_SEC)

    def test_second_consecutive_no_boot_escalates(self):
        prior = {"cycles": [{"n": 0, "verdict": power_cycle.NO_BOOT}]}
        rec, relay = _run(prior)
        self.assertEqual(relay.holds, [10.0])
        self.assertEqual(rec["force_off_sec"], 10.0)

    def test_a_pass_in_between_resets_the_hold(self):
        prior = {"cycles": [{"n": 0, "verdict": power_cycle.PASS}]}
        _, relay = _run(prior)
        self.assertEqual(relay.holds, [config.ATX_LONG_PRESS_SEC])

    def test_escalation_can_be_disabled(self):
        prior = {"cycles": [{"n": 0, "verdict": power_cycle.NO_BOOT}]}
        _, relay = _run(prior, _args(force_off_escalate=0))
        self.assertEqual(relay.holds, [config.ATX_LONG_PRESS_SEC])

    def test_missing_result_does_not_crash_the_cycle(self):
        """run_one_cycle is called with result=None from some paths."""
        rec, relay = _run(None)
        self.assertEqual(relay.holds, [config.ATX_LONG_PRESS_SEC])
        self.assertEqual(rec["verdict"], power_cycle.NO_BOOT)

    def test_debug_leaves_the_dut_alone(self):
        prior = {"cycles": [{"n": 0, "verdict": power_cycle.NO_BOOT}]}
        rec, relay = _run(prior, _args(debug=True))
        self.assertEqual(relay.holds, [])
        self.assertIsNone(rec["force_off_sec"])


class RecordHonestyTest(unittest.TestCase):

    def test_the_record_claims_a_command_not_an_outcome(self):
        rec, _ = _run({"cycles": []})
        for field in ("powered_off", "force_off_ok", "dut_off", "power_state"):
            self.assertNotIn(field, rec,
                             f"{field} would claim an outcome the relay cannot observe")

    def test_no_boot_notes_offer_both_causes(self):
        rec, _ = _run({"cycles": []})
        notes = rec["notes"].lower()
        self.assertIn("did not power on", notes)
        self.assertIn("no network", notes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
