import json
from pathlib import Path
import tempfile
import unittest

from go3cpu.controller import atomic_json, claim_pilot, registered_latch, sha256
from go3cpu.speedup import skip_intermediate_verification, final_verification_required
from go3cpu.campaign import sixth_best_target

ROOT=Path(__file__).resolve().parents[1]


class SpeedupTests(unittest.TestCase):
    def test_frozen_reference_target_is_unchanged(self):
        manifest=json.loads((ROOT/"manifests/campaign/published_C3E4N06049D2_s003.json").read_text())
        target=sixth_best_target(manifest,network="C3E4N06049D2",scenario="003",switching=True)
        self.assertEqual(target["sixth_best_score"],597463992.571312)
        self.assertEqual(target["minimum_score"],537717593.3141807)

    def test_one_cold_attempt_budget_and_frozen_reference(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r01.json").read_text())
        auth=json.loads((ROOT/"manifests/authorization_speedup_001.json").read_text())
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d)
            for key in ("result","completion","configuration","comparison"):
                path=root/auth["baseline"][key+"_path"]
                atomic_json(path,{"tiny":key})
                auth["baseline"][key+"_sha256"]=sha256(path)
            atomic_json(root/"manifests/authorization_speedup_001.json",auth)
            latch=registered_latch(root,config)
            claim_pilot(latch,{"test":True})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"test":"repeat"})
            for change in ({"total_seconds":7200},{"cold_start":False},{"allow_pop_solution":True},
                    {"pilot_id":"speedup_n06049_s003_r02"},{"evaluation_reserve_seconds":299},
                    {"finalization_reserve_seconds":29},{"scheduling_relative_gap":0.01},
                    {"network":"C3E4N08316D2"},{"scheduling_seed_policy":"cold_online_construction_cost_lp_v2"}):
                with self.assertRaises(ValueError):
                    registered_latch(root,{**config,**change})
            atomic_json(root/auth["baseline"]["result_path"],{"changed":True})
            with self.assertRaisesRegex(ValueError,"baseline evidence changed"):
                registered_latch(root,config)

    def test_only_complete_horizon_gets_expensive_final_evaluation(self):
        cfg={"pilot_id":"speedup_n06049_s003_r01",
             "intermediate_verification":"skip_unverified_schedule_v1"}
        self.assertTrue(skip_intermediate_verification(cfg))
        self.assertFalse(skip_intermediate_verification({}))
        self.assertTrue(final_verification_required({}, {}, 1, {}, 3))
        stats={"ac_intervals":[{"interval":i} for i in (1,2,3)]}
        self.assertTrue(final_verification_required(cfg,{"stage":"complete"},0,stats,3))
        for stage,rc,ids in (("partial_complete",0,(1,2)),("complete",15,(1,2,3)),
                              ("complete",0,(1,2,2)),("ac_optimization",0,(1,2,3))):
            self.assertFalse(final_verification_required(cfg,{"stage":stage},rc,
                {"ac_intervals":[{"interval":i} for i in ids]},3))
        with self.assertRaises(ValueError):
            skip_intermediate_verification({"intermediate_verification":"omit_all_checks"})
