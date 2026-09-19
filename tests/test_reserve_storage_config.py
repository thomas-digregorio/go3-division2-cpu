"""A storage-only fixture must not quietly change numerical configurations."""
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]


class ReserveStorageConfigTests(unittest.TestCase):
    def test_bounded_fixture_changes_only_reserve_model_lifetime(self):
        baseline=json.loads((ROOT/"config/tiny_ac_exact_ramp.json").read_text())
        bounded=json.loads((ROOT/"config/tiny_reserve_bounded.json").read_text())
        self.assertEqual(bounded.pop("reserve_storage_policy"),"bounded_lifetime_v1")
        self.assertEqual(bounded,baseline)


if __name__=="__main__":
    unittest.main()
