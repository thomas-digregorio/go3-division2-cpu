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

    def test_handoff_fixture_changes_only_initial_unverified_awards(self):
        baseline=json.loads((ROOT/"config/tiny_reserve_bounded.json").read_text())
        current=json.loads((ROOT/"config/tiny_reserve_handoff.json").read_text())
        self.assertEqual(current.pop("initial_reserve_policy"),"use_joint_schedule_unverified")
        self.assertEqual(current,baseline)

    def test_r12_preserves_source_solver_precision_deadline_and_safety_contracts(self):
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r11.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r12.json").read_text())
        changed={k for k in previous.keys() | current.keys() if previous.get(k)!=current.get(k)}
        self.assertEqual(changed,{"pilot_id","initial_reserve_policy",
                                 "reserve_seconds_per_interval","reserve_finish_seconds"})
        self.assertEqual(current["initial_reserve_policy"],"use_joint_schedule_unverified")
        self.assertTrue(current["scheduling_include_reserves"])
        self.assertEqual(current["ac_reserve_policy"],"source_joint_reserves_in_ac_v1")
        self.assertEqual(current["reserve_storage_policy"],"bounded_lifetime_v1")
        self.assertEqual(current["reserve_seconds_per_interval"],30)
        self.assertEqual(current["reserve_finish_seconds"],600)
        self.assertEqual(current["total_seconds"],7200)
        self.assertEqual(current["evaluation_reserve_seconds"],2400)
        self.assertEqual(current["maximum_full_runs"],1)
        self.assertTrue(current["cold_start"])
        self.assertFalse(current["allow_pop_solution"])
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["reserve_handoff_goal_continuation"]["registered_next_attempt"],current["pilot_id"])
        self.assertEqual(auth["attempts"][current["pilot_id"]],
                         {k:current[k] for k in ("network","scenario","input_sha256")})


if __name__=="__main__":
    unittest.main()
