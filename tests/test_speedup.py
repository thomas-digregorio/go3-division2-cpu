import json
from pathlib import Path
import tempfile
import unittest

from go3cpu.controller import atomic_json, claim_pilot, registered_latch, sha256
from go3cpu.speedup import (skip_intermediate_verification, final_verification_required,
                           runtime_target_status)
from go3cpu.campaign import sixth_best_target, registered_budget

ROOT=Path(__file__).resolve().parents[1]


class SpeedupTests(unittest.TestCase):
    def test_quality_guarded_recovery_preserves_registered_cold_contract(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r08.json").read_text())
        previous=json.loads((ROOT/"config/speedup_n06049_s003_r07.json").read_text())
        self.assertTrue(registered_budget(config))
        self.assertEqual(config["ac_correction_policy"],"network_slp_quality_guarded_recovery_v6")
        self.assertEqual(registered_latch(ROOT,config).name,"speedup_n06049_s003_r08_latch.json")
        self.assertEqual({k for k in config if config[k]!=previous[k]},
                         {"pilot_id","ac_correction_policy"})
        self.assertEqual(config["total_seconds"],7200)
        self.assertEqual(config["ac_correction_hour_seconds"],600)
        for change in ({"cold_start":False},{"allow_pop_solution":True},
                       {"ac_correction_policy":previous["ac_correction_policy"]},
                       {"total_seconds":7201},{"evaluation_reserve_seconds":449}):
            with self.assertRaises(ValueError):
                registered_latch(ROOT,{**config,**change})

    def test_original_residual_guard_registration_preserves_model_and_budget(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r07.json").read_text())
        previous=json.loads((ROOT/"config/speedup_n06049_s003_r06.json").read_text())
        self.assertTrue(registered_budget(config))
        self.assertEqual(config["ac_correction_policy"],"network_slp_original_residual_guard_v5")
        self.assertEqual(registered_latch(ROOT,config).name,"speedup_n06049_s003_r07_latch.json")
        self.assertEqual({k for k in config if config[k]!=previous[k]},
                         {"pilot_id","ac_correction_policy"})
        for change in ({"cold_start":False},{"allow_pop_solution":True},
                       {"ac_correction_policy":previous["ac_correction_policy"]}):
            with self.assertRaises(ValueError):
                registered_latch(ROOT,{**config,**change})

    def test_primal_continuation_registration_preserves_full_cold_contract(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r06.json").read_text())
        previous=json.loads((ROOT/"config/speedup_n06049_s003_r05.json").read_text())
        self.assertTrue(registered_budget(config))
        self.assertEqual(config["ac_correction_policy"],"network_slp_preserved_primal_repair_v4")
        self.assertEqual(registered_latch(ROOT,config).name,"speedup_n06049_s003_r06_latch.json")
        changed={k for k in config if config[k]!=previous[k]}
        self.assertEqual(changed,{"pilot_id","ac_correction_policy"})
        with self.assertRaises(ValueError):
            registered_latch(ROOT,{**config,"cold_start":False})

    def test_ipx_continuous_shunt_variant_requires_matching_registration(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r04.json").read_text())
        auth=json.loads((ROOT/"manifests/authorization_speedup_004.json").read_text())
        self.assertTrue(registered_budget(config))
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d)
            for group,keys in (("baseline",("result","completion","configuration","comparison")),
                               ("previous_attempt",("result","completion"))):
                for key in keys:
                    path=root/auth[group][key+"_path"]
                    atomic_json(path,{"tiny":group+key})
                    auth[group][key+"_sha256"]=sha256(path)
            atomic_json(root/"manifests/authorization_speedup_004.json",auth)
            latch=registered_latch(root,config)
            claim_pilot(latch,{"tiny":True})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"duplicate":True})
            for change in ({"ac_correction_lp_solver":"simplex"},
                           {"ac_correction_policy":"network_slp_fixed_shunts_v1"},
                           {"allow_pop_solution":True},{"cold_start":False}):
                with self.assertRaises(ValueError):
                    registered_latch(root,{**config,**change})

    def test_hot_repair_registration_preserves_cold_scope(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r05.json").read_text())
        self.assertTrue(registered_budget(config))
        self.assertEqual(config["ac_correction_policy"],"network_slp_continuous_hot_repair_v3")
        self.assertEqual(config["ac_correction_lp_solver"],"ipx")
        self.assertTrue(config["cold_start"])
        self.assertFalse(config["allow_pop_solution"])
        latch=registered_latch(ROOT,config)
        self.assertEqual(latch.name,"speedup_n06049_s003_r05_latch.json")
        for change in ({"ac_correction_policy":"network_slp_continuous_then_round_v2"},
                       {"ac_correction_lp_solver":"simplex"},{"cold_start":False}):
            with self.assertRaises(ValueError):
                registered_latch(ROOT,{**config,**change})

    def test_ongoing_iterations_remain_cold_and_one_execution_per_registration(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r03.json").read_text())
        auth=json.loads((ROOT/"manifests/authorization_speedup_003.json").read_text())
        self.assertTrue(registered_budget(config))
        self.assertEqual(config["ac_correction_budget_policy"],"remaining_horizon_v1")
        self.assertEqual(config["total_seconds"],7200)
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d)
            for group,keys in (("baseline",("result","completion","configuration","comparison")),
                               ("previous_attempt",("result","completion"))):
                for key in keys:
                    path=root/auth[group][key+"_path"]
                    atomic_json(path,{"tiny":group+key})
                    auth[group][key+"_sha256"]=sha256(path)
            registration=root/"manifests/authorization_speedup_003.json"
            atomic_json(registration,auth)
            latch=registered_latch(root,config)
            claim_pilot(latch,{"tiny":True})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"repeated":True})
            for change in ({"pilot_id":"speedup_n06049_s003_r04"},
                           {"pilot_id":"../authorization_speedup_003"},
                           {"network":"C3E4N06717D2"},{"total_seconds":7201},
                           {"cold_start":False},{"allow_pop_solution":True}):
                with self.assertRaises(ValueError):
                    registered_latch(root,{**config,**change})
            atomic_json(registration,{**auth,"ongoing_iteration_authorized":False})
            with self.assertRaisesRegex(ValueError,"updated user authorization"):
                registered_latch(root,config)

    def test_replacement_has_separate_latch_and_soft_target(self):
        config=json.loads((ROOT/"config/speedup_n06049_s003_r02.json").read_text())
        auth=json.loads((ROOT/"manifests/authorization_speedup_002.json").read_text())
        self.assertTrue(registered_budget(config))
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d)
            for group in ("baseline","previous_attempt"):
                for key in (("result","completion","configuration","comparison") if group=="baseline" else ("result","completion")):
                    path=root/auth[group][key+"_path"]
                    atomic_json(path,{"tiny":group+key})
                    auth[group][key+"_sha256"]=sha256(path)
            atomic_json(root/"manifests/authorization_speedup_002.json",auth)
            old=root/"runs/speedup_n06049_s003_r01_latch.json"
            atomic_json(old,{"consumed":True})
            old_hash=sha256(old)
            latch=registered_latch(root,config)
            self.assertNotEqual(latch,old)
            claim_pilot(latch,{"test":True})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"repeat":True})
            self.assertEqual(sha256(old),old_hash)
            for change in ({"total_seconds":1800},{"total_seconds":3600},{"target_seconds":3600},
                           {"pilot_id":"speedup_n06049_s003_r03"},{"cold_start":False},
                           {"allow_pop_solution":True},{"evaluation_reserve_seconds":299}):
                with self.assertRaises(ValueError):
                    registered_latch(root,{**config,**change})
        at_target=runtime_target_status(config,1800)
        beyond_target=runtime_target_status(config,1801)
        self.assertTrue(at_target["within_target"])
        self.assertFalse(beyond_target["within_target"])
        self.assertTrue(beyond_target["within_hard_limit"])
        self.assertFalse(beyond_target["target_is_hard_deadline"])
        self.assertTrue(runtime_target_status(config,3600)["within_hard_limit"])
        self.assertFalse(runtime_target_status(config,7200)["within_hard_limit"])

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
