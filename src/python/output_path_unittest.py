# output_path_unittest.py — LOG001/BUG0042 default output location
#
# Guards the rule that the DEFAULT output tree is anchored to the directory
# holding the scripts, not to the process working directory -- matching
# function.sh's `_tool_path` and the PowerShell scripts' `$_script_root`.
#
# Run:
#   python3 -m unittest output_path_unittest -v
#   (from src/python/, so `import config` / `import function` resolve)

import os
import subprocess
import sys
import tempfile
import unittest

import config
import function

HERE = os.path.dirname(os.path.abspath(__file__))


class DefaultOutputPathTest(unittest.TestCase):

    def test_log_dir_is_absolute(self):
        self.assertTrue(os.path.isabs(config.LOG_DIR), config.LOG_DIR)

    def test_report_dir_is_absolute(self):
        self.assertTrue(os.path.isabs(config.REPORT_DIR), config.REPORT_DIR)

    def test_log_dir_sits_beside_the_scripts(self):
        self.assertEqual(os.path.dirname(config.LOG_DIR), HERE)
        self.assertEqual(os.path.basename(config.LOG_DIR), "logs")

    def test_counter_file_sits_beside_the_scripts(self):
        self.assertEqual(os.path.dirname(function._COUNTER_FILE), HERE)

    def test_defaults_do_not_follow_the_working_directory(self):
        """The regression itself: importing config from an unrelated cwd must
        yield the same paths, or `cd /tmp && python3 .../reboot.py` grows a
        second, invisible log tree (BUG0042)."""
        code = ("import sys; sys.path.insert(0, %r)\n"
                "import config, function\n"
                "print(config.LOG_DIR)\n"
                "print(config.REPORT_DIR)\n"
                "print(function._COUNTER_FILE)\n" % HERE)
        with tempfile.TemporaryDirectory() as elsewhere:
            out = subprocess.run([sys.executable, "-c", code], cwd=elsewhere,
                                 capture_output=True, text=True, check=True)
            log_dir, report_dir, counter = out.stdout.split()
            self.assertEqual(log_dir, config.LOG_DIR)
            self.assertEqual(report_dir, config.REPORT_DIR)
            self.assertEqual(counter, function._COUNTER_FILE)
            # and nothing was created in the foreign working directory
            self.assertEqual(os.listdir(elsewhere), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
