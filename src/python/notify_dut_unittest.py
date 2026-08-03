# notify_dut_unittest.py — BUG0025 Windows desktop notification delivery
#
# Drives function.notify_dut()'s Windows branch with a fake ssh(1), so the
# delivery logic is exercised without a DUT. Each case records the remote
# command lines that would have been sent and asserts on that sequence.
#
# Run:
#   python3 -m unittest notify_dut_unittest -v
#   (from src/python/, so `import config` / `import function` resolve)

import logging
import subprocess
import unittest
from unittest import mock

import function

MESSAGE = "Power cycle test in progress - cycle 1/10. Do not use."


class _FakeSSH:
    """Stands in for subprocess.run, answering per-command with a chosen rc."""

    def __init__(self, rcs, default_rc=1):
        self.rcs = rcs                  # {substring: (rc, stdout, stderr)}
        self.default_rc = default_rc
        self.commands = []              # remote command lines, in order

    def __call__(self, argv, **kwargs):
        cmd = argv[-1]                  # ssh ... user@host "<cmd>"
        self.commands.append(cmd)
        for needle, (rc, out, err) in self.rcs.items():
            if cmd.startswith(needle):
                return subprocess.CompletedProcess(argv, rc, out, err)
        return subprocess.CompletedProcess(argv, self.default_rc, "", "boom")


class NotifyDutWindowsTest(unittest.TestCase):

    def setUp(self):
        # notify_dut is best-effort and logs at INFO/WARNING; keep test output quiet.
        logging.disable(logging.CRITICAL)
        self.addCleanup(logging.disable, logging.NOTSET)

    def run_notify(self, fake, **kw):
        opts = dict(ssh_user="tester", host="10.0.0.137", port=22,
                    message=MESSAGE, dut_os="windows",
                    max_wait=1, retry_interval=0.01, ssh_timeout=1)
        opts.update(kw)
        with mock.patch.object(subprocess, "run", fake):
            t = function.notify_dut(**opts)
            self.assertIsNotNone(t)
            t.join(timeout=10)
            self.assertFalse(t.is_alive(), "notify thread did not finish")
        return fake.commands

    # ---- the regression itself ----

    def test_delivery_is_not_gated_on_query_session(self):
        """BUG0025: `query session` is an administrative operation that fails as
        an ordinary user over SSH. Requiring it to succeed before trying msg.exe
        suppressed a notification that would have worked -- which is why the
        operator's manual `ssh <dut> "msg * hello"` did work."""
        fake = _FakeSSH({"msg *": (0, "", "")})
        cmds = self.run_notify(fake)
        self.assertTrue(cmds[0].startswith("msg *"),
                        f"first remote command should be msg, got {cmds[0]!r}")
        self.assertNotIn("query session", cmds)

    def test_message_is_quoted(self):
        fake = _FakeSSH({"msg *": (0, "", "")})
        cmds = self.run_notify(fake)
        self.assertEqual(cmds[0], 'msg * "%s"' % MESSAGE)

    def test_no_time_switch(self):
        """No /time means the popup stays until acknowledged, which is what an
        'in progress' reminder needs."""
        fake = _FakeSSH({"msg *": (0, "", "")})
        self.assertNotIn("/time", self.run_notify(fake)[0])

    def test_stops_after_first_success(self):
        fake = _FakeSSH({"msg *": (0, "", "")})
        self.assertEqual(len(self.run_notify(fake)), 1)

    # ---- fallback and failure reporting ----

    def test_falls_back_to_console_session(self):
        fake = _FakeSSH({"msg *":       (1, "", "Error 5 getting session names"),
                         "msg console": (0, "", "")})
        cmds = self.run_notify(fake)
        self.assertEqual(cmds, ['msg * "%s"' % MESSAGE, 'msg console "%s"' % MESSAGE])

    def test_diagnostic_query_session_runs_only_after_giving_up(self):
        fake = _FakeSSH({})                       # everything fails
        cmds = self.run_notify(fake)
        self.assertEqual(cmds[-1], "query session")
        self.assertEqual(cmds.count("query session"), 1)
        self.assertGreaterEqual(len([c for c in cmds if c.startswith("msg")]), 2)

    def test_failure_never_raises(self):
        """FWK032: the notification must never be able to affect the test."""
        def explode(*a, **kw):
            raise OSError("ssh missing")
        fake = _FakeSSH({})
        with mock.patch.object(subprocess, "run", explode):
            t = function.notify_dut("tester", "10.0.0.137", 22, MESSAGE,
                                    dut_os="windows", max_wait=1,
                                    retry_interval=0.01, ssh_timeout=1)
            t.join(timeout=10)
            self.assertFalse(t.is_alive())
        del fake

    # ---- guards on the non-Windows path and the no-op paths ----

    def test_linux_uses_wall_not_msg(self):
        fake = _FakeSSH({"true": (0, "", "")})
        cmds = self.run_notify(fake, dut_os="linux")
        self.assertEqual(cmds[0], "true")
        self.assertTrue(cmds[1].startswith("wall "), cmds[1])

    def test_dry_run_sends_nothing(self):
        self.assertIsNone(function.notify_dut("tester", "10.0.0.137", 22, MESSAGE,
                                              dry_run=True))

    def test_no_ssh_user_sends_nothing(self):
        self.assertIsNone(function.notify_dut("", "10.0.0.137", 22, MESSAGE))


class WinMsgCmdTest(unittest.TestCase):

    def test_slash_in_message_is_protected_from_switch_parsing(self):
        cmd = function.win_msg_cmd("*", "cycle 1/10. Do not use.")
        self.assertEqual(cmd, 'msg * "cycle 1/10. Do not use."')

    def test_embedded_quotes_cannot_break_the_command_line(self):
        cmd = function.win_msg_cmd("*", 'say "hi" now')
        self.assertEqual(cmd.count('"'), 2)
        self.assertEqual(cmd, 'msg * "say \'hi\' now"')


if __name__ == "__main__":
    unittest.main(verbosity=2)
