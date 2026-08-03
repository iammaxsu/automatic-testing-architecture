# resolve_session_unittest.py — LOG026 auto-resume decision matrix
#
# Verifies function.resolve_session()'s NEW-vs-RESUME decision without touching
# GPIO, SSH, or a DUT: every case seeds a meta.json with a chosen age and checks
# which session the resolver picks.
#
# Run:
#   python3 -m unittest resolve_session_unittest -v
#   (from src/python/, so `import config` / `import function` resolve)

import json
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

import function

TEST   = "power_cycle"
DUT_ID = "10.0.0.5"
TARGET = {"host": "10.0.0.5", "port": 22, "ssh_user": "adlink", "type": "ATX"}
OLD_ID = "20260801T120000"


class ResolveSessionTest(unittest.TestCase):

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="log026-"))

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    # ---- helpers ----

    def seed(self, age_hours, n=6, m=10, drop_timestamps=False):
        """Create one incomplete session last updated `age_hours` ago."""
        d = self.base / DUT_ID / f"{TEST}_{OLD_ID}"
        d.mkdir(parents=True, exist_ok=True)
        stamp = (datetime.now() - timedelta(hours=age_hours)).strftime("%Y-%m-%dT%H:%M:%S")
        meta = {
            "session_id": OLD_ID, "test": TEST, "dut_id": DUT_ID,
            "m": m, "n": n, "status": "running",
            "started_at": stamp, "updated_at": stamp, "target": TARGET,
        }
        if drop_timestamps:          # simulate a session written by an older build
            meta.pop("started_at")
            meta.pop("updated_at")
        (d / "meta.json").write_text(json.dumps(meta), encoding="utf-8")

    def resolve(self, new_session=False, **kw):
        return function.resolve_session(str(self.base), TEST, DUT_ID, TARGET,
                                        10, new_session, **kw)

    # ---- decision matrix (LOG026 Verification) ----

    def test_fresh_session_is_resumed(self):
        self.seed(age_hours=2)
        _, sid, _, start_n, _, resuming, skipped = self.resolve()
        self.assertTrue(resuming)
        self.assertEqual(sid, OLD_ID)
        self.assertEqual(start_n, 7)         # n=6 done -> continue at 7
        self.assertEqual(skipped, [])

    def test_stale_session_is_skipped_for_a_new_one(self):
        self.seed(age_hours=50)
        _, sid, _, start_n, _, resuming, skipped = self.resolve()
        self.assertFalse(resuming)
        self.assertNotEqual(sid, OLD_ID)
        self.assertEqual(start_n, 1)
        self.assertEqual(len(skipped), 1)
        self.assertEqual((skipped[0]["session_id"], skipped[0]["n"], skipped[0]["m"]),
                         (OLD_ID, 6, 10))
        self.assertGreater(skipped[0]["age_hours"], 24)

    def test_skipped_session_is_left_on_disk(self):
        """FWK028: a stale session stays canonical and stays resumable."""
        self.seed(age_hours=50)
        self.resolve()
        meta = json.loads((self.base / DUT_ID / f"{TEST}_{OLD_ID}" / "meta.json").read_text())
        self.assertEqual(meta["status"], "running")
        self.assertEqual(meta["n"], 6)

    def test_force_resume_overrides_age(self):
        self.seed(age_hours=50)
        _, sid, _, start_n, _, resuming, _ = self.resolve(force_resume=True)
        self.assertTrue(resuming)
        self.assertEqual(sid, OLD_ID)
        self.assertEqual(start_n, 7)

    def test_new_session_beats_a_resumable_one(self):
        self.seed(age_hours=2)
        _, sid, _, start_n, _, resuming, _ = self.resolve(new_session=True)
        self.assertFalse(resuming)
        self.assertNotEqual(sid, OLD_ID)
        self.assertEqual(start_n, 1)

    def test_zero_max_age_disables_auto_resume(self):
        self.seed(age_hours=0)
        _, _, _, start_n, _, resuming, skipped = self.resolve(max_age_hours=0)
        self.assertFalse(resuming)
        self.assertEqual(start_n, 1)
        self.assertEqual(len(skipped), 1)

    def test_negative_max_age_restores_unbounded_resume(self):
        self.seed(age_hours=9999)
        _, sid, _, start_n, _, resuming, _ = self.resolve(max_age_hours=-1)
        self.assertTrue(resuming)
        self.assertEqual(sid, OLD_ID)
        self.assertEqual(start_n, 7)

    def test_missing_timestamps_fall_back_to_mtime(self):
        """A session with no started_at/updated_at is aged by meta.json's mtime,
        not treated as ageless and therefore always resumable."""
        self.seed(age_hours=2, drop_timestamps=True)
        _, sid, _, start_n, _, resuming, _ = self.resolve()
        self.assertTrue(resuming)             # just written -> fresh
        self.assertEqual(sid, OLD_ID)
        self.assertEqual(start_n, 7)

    def test_complete_session_is_not_a_skip(self):
        """n == m is finished, not abandoned -- it must not be reported as
        skipped-for-age, or every run after a completed test would warn."""
        self.seed(age_hours=2, n=10, m=10)
        _, sid, _, start_n, _, resuming, skipped = self.resolve()
        self.assertFalse(resuming)
        self.assertNotEqual(sid, OLD_ID)
        self.assertEqual(start_n, 1)
        self.assertEqual(skipped, [])

    def test_target_mismatch_still_refuses(self):
        """LOG025's guard must survive the age bound."""
        self.seed(age_hours=2)
        other = dict(TARGET, host="10.0.0.99")
        with self.assertRaises(function.SessionTargetMismatch):
            function.resolve_session(str(self.base), TEST, DUT_ID, other, 10, False)

    def test_explicit_cycles_mismatch_still_refuses(self):
        """BUG0041's guard must survive the age bound."""
        self.seed(age_hours=2)
        with self.assertRaises(function.SessionCycleMismatch):
            function.resolve_session(str(self.base), TEST, DUT_ID, TARGET, 300, False,
                                     cycles_explicit=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
