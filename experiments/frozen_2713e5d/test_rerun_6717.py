"""Registration-only tests. Never launches a solver or edits historical evidence."""
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rerun_6717 as rerun


class RerunTests(unittest.TestCase):
    def config(self):
        return rerun.registration.load(rerun.ROOT / rerun.authorization()["config_path"])

    def test_identical_settings_except_new_id(self):
        rerun.validate_config(self.config())

    def test_original_123_source_inventory_unchanged(self):
        identity = rerun.registration.validate_frozen_identity()
        self.assertEqual(identity["original_tested_source_files"], 123)
        self.assertTrue(identity["original_source_hashes_match"])

    def test_any_changed_setting_rejected(self):
        config = self.config()
        for key, value in config.items():
            with self.subTest(key=key):
                changed = copy.deepcopy(config)
                changed[key] = "unregistered value"
                with self.assertRaises(RuntimeError):
                    rerun.validate_config(changed)

    def test_extra_setting_rejected(self):
        changed = self.config()
        changed["resume_solution"] = "previous.json"
        with self.assertRaises(RuntimeError):
            rerun.validate_config(changed)

    def test_only_new_latch_selected_old_one_remains(self):
        old = rerun.ROOT / "runs/campaign_r2_06717_latch.json"
        digest = rerun.registration.sha256(old)
        selected = rerun.registered_latch(rerun.ROOT, self.config())
        self.assertEqual(selected.name, "campaign_r3_06717_latch.json")
        self.assertNotEqual(selected, old)
        self.assertEqual(rerun.registration.sha256(old), digest)

    def test_wrong_root_rejected(self):
        with self.assertRaises(RuntimeError):
            rerun.registered_latch(rerun.ROOT / "tmp", self.config())

    def test_short_output_paths(self):
        audit = rerun.registration.output_path_audit(self.config())
        self.assertEqual(audit["maximum_temporary_path_characters"], 234)
        self.assertLessEqual(audit["maximum_temporary_path_characters"], 240)

    def test_real_exclusive_latch_prevents_duplicate(self):
        with tempfile.TemporaryDirectory(prefix="r3_latch_", dir=rerun.ROOT / "tmp") as directory:
            latch = Path(directory) / "one_use.json"
            rerun.registration.claim_pilot(latch, {"fixture": True})
            with self.assertRaises(FileExistsError):
                rerun.registration.claim_pilot(latch, {"duplicate": True})
            self.assertEqual(rerun.registration.load(latch), {"fixture": True})


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RerunTests))
    report = {
        "pass": result.wasSuccessful(), "tests": result.testsRun,
        "scope": "New 6717 authorization and identical configuration only; no full-case solve",
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {name: rerun.registration.sha256(rerun.HERE / name)
                          for name in rerun.SOURCE_NAMES},
    }
    rerun.registration.atomic_json(rerun.REPORT, report)
    print(json.dumps(report, indent=2))
    sys.exit(0 if result.wasSuccessful() else 1)
