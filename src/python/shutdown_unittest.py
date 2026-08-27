# shutdown_unittest.py — BUG0068 immediate shutdown, comparable across OSes
#
# The Windows shutdown command used to carry a "/t 5" countdown that Linux's
# "shutdown -h now" did not, so five seconds of every Windows figure was a delay
# the framework had asked for and the two OSes' statistics were silently
# incomparable. Removing it exposes a second problem: an immediate shutdown
# races its own transport, and a dropped SSH session must not be mistaken for a
# refused command — that would credit the relay for a shutdown SSH performed.
#
# Run:
#   python3 -m unittest shutdown_unittest -v
#   (from src/python/)

import subprocess
import unittest
from unittest import mock

import config
import shutdown


class _Checker:
    """Reports the DUT dying after a set number of wait_until_dead calls."""

    host = "10.0.0.1"

    def __init__(self, dies=True, after=0):
        self.dies = dies
        self.after = after
        self.calls = []

    def wait_until_dead(self, timeout_sec, poll_interval=None):
        self.calls.append(timeout_sec)
        if self.dies and len(self.calls) > self.after:
            return True, 12.3
        return False, float(timeout_sec)


def _coord(**kw):
    kw.setdefault("checker", _Checker())
    kw.setdefault("ssh_user", "tester")
    kw.setdefault("ssh_host", "10.0.0.1")
    return shutdown.ShutdownCoordinator(**kw)


class ShutdownCommandTest(unittest.TestCase):

    def test_both_os_commands_are_immediate(self):
        """Neither OS may inject a delay into a figure the report compares."""
        self.assertEqual(config._OS_SHUTDOWN_CMD["windows"], "shutdown /s /t 0")
        self.assertNotIn("/t 5", config._OS_SHUTDOWN_CMD["windows"])
        self.assertIn("now", config._OS_SHUTDOWN_CMD["linux"])

    def test_neither_command_forces_applications_closed(self):
        """A DUT that genuinely hangs must still be caught as HANG_SHUTDOWN."""
        for cmd in config._OS_SHUTDOWN_CMD.values():
            self.assertNotIn(" /f", cmd)
            self.assertNotIn("--force", cmd)

    def test_windows_shutdown_matches_the_reboot_command_style(self):
        self.assertIn("/t 0", config._OS_REBOOT_CMD["windows"])
        self.assertIn("/t 0", config._OS_SHUTDOWN_CMD["windows"])


class ConfirmByDeathTest(unittest.TestCase):
    """A shutdown that worked must be recorded as ssh, not blamed on the relay."""

    def _run(self, checker, run_side_effect):
        coord = _coord(checker=checker)
        with mock.patch.object(subprocess, "run", side_effect=run_side_effect):
            return coord._try_ssh()

    def test_dropped_session_with_a_dead_dut_counts_as_success(self):
        checker = _Checker(dies=True)
        ok, elapsed = self._run(
            checker, lambda *a, **kw: mock.Mock(returncode=255, stderr="closed", stdout=""))
        self.assertTrue(ok)
        self.assertEqual(elapsed, 12.3)

    def test_timeout_with_a_dead_dut_counts_as_success(self):
        checker = _Checker(dies=True)

        def _boom(*a, **kw):
            raise subprocess.TimeoutExpired(cmd="ssh", timeout=15)

        ok, _ = self._run(checker, _boom)
        self.assertTrue(ok)

    def test_a_real_failure_still_falls_through(self):
        """Bad credentials: the DUT stays up, so the relay must take over."""
        checker = _Checker(dies=False)
        ok, elapsed = self._run(
            checker, lambda *a, **kw: mock.Mock(returncode=255,
                                                stderr="Permission denied", stdout=""))
        self.assertFalse(ok)
        self.assertEqual(elapsed, 0.0)

    def test_the_confirm_window_is_bounded(self):
        checker = _Checker(dies=False)
        self._run(checker,
                  lambda *a, **kw: mock.Mock(returncode=1, stderr="x", stdout=""))
        self.assertEqual(len(checker.calls), 1)
        self.assertLessEqual(checker.calls[0], config.SSH_CONFIRM_DEATH_SEC)
        self.assertLessEqual(checker.calls[0], config.DEAD_TIMEOUT_SEC)

    def test_no_checker_cannot_confirm_and_must_not_guess(self):
        coord = _coord(checker=None, ssh_host="10.0.0.1")
        with mock.patch.object(subprocess, "run",
                               side_effect=lambda *a, **kw: mock.Mock(
                                   returncode=255, stderr="closed", stdout="")):
            ok, _ = coord._try_ssh()
        self.assertFalse(ok)

    def test_a_clean_exit_does_not_spend_the_confirm_window(self):
        checker = _Checker(dies=True)
        coord = _coord(checker=checker)
        with mock.patch.object(subprocess, "run",
                               side_effect=lambda *a, **kw: mock.Mock(
                                   returncode=0, stderr="", stdout="")):
            ok, _ = coord._try_ssh()
        self.assertTrue(ok)
        self.assertEqual(checker.calls, [config.DEAD_TIMEOUT_SEC])


if __name__ == "__main__":
    unittest.main(verbosity=2)
