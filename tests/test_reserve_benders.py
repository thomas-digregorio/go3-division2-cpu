import copy
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"scripts"))
from run_reserve_benders import scheduling_gap, terminal_status, validate_configuration
from run_disk_worker import native_pid_matches


class ReserveBendersContracts(unittest.TestCase):
    def test_registered_r06_changes_only_decomposition_and_internal_allocation(self):
        old=json.loads((ROOT/"config/campaign_n23643_s003_r05.json").read_text())
        new=json.loads((ROOT/"config/campaign_n23643_s003_r06.json").read_text())
        changes={"pilot_id","scheduling_seconds","scheduling_decomposition_policy",
            "scheduling_benders_master_round_seconds","scheduling_benders_recourse_seconds",
            "scheduling_benders_recourse_reserve_seconds","scheduling_benders_finalize_seconds",
            "scheduling_benders_max_rounds"}
        self.assertEqual({k:v for k,v in old.items() if k not in changes},
                         {k:v for k,v in new.items() if k not in changes})
        validate_configuration(new)
        self.assertEqual(new["scheduling_seconds"],1500)
        self.assertEqual(new["total_seconds"],7200)
        self.assertEqual(new["scheduling_relative_gap"],1e-3)
        authorization=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(authorization["attempts"][new["pilot_id"]],
            {k:new[k] for k in ("network","scenario","input_sha256")})
        from go3cpu.campaign import campaign_latch
        self.assertEqual(campaign_latch(ROOT,new),ROOT/"runs/campaign_n23643_s003_r06_latch.json")

    def test_no_false_optimal_or_timeout_status_at_round_limit(self):
        self.assertEqual(terminal_status("scheduling_gap_met",True),(7,"OPTIMAL"))
        self.assertEqual(terminal_status("round_limit",False),(14,"ITERATION_LIMIT"))
        self.assertEqual(terminal_status("recourse_absolute_deadline",False),(13,"TIME_LIMIT"))
        self.assertEqual(terminal_status("master_native_call_deadline",False),(13,"TIME_LIMIT"))
        self.assertEqual(terminal_status("recourse_native_call_deadline",False),(13,"TIME_LIMIT"))
        with self.assertRaises(ValueError):
            terminal_status("invented",False)

    def test_synchronous_python_launcher_does_not_relax_julia_pid_identity(self):
        record={"pid":200,"coordinator_parent_pid":100,
            "storage":{"decomposition_policy":"source_reserve_benders_v1"}}
        self.assertTrue(native_pid_matches(record,200,"off"))
        self.assertTrue(native_pid_matches(record,100,"source_reserve_benders_v1"))
        self.assertFalse(native_pid_matches(record,100,"off"))
        self.assertFalse(native_pid_matches(record,101,"source_reserve_benders_v1"))
        record["storage"]={}
        self.assertFalse(native_pid_matches(record,100,"source_reserve_benders_v1"))

    def test_gap_uses_joint_incumbent_not_underpriced_master_objective(self):
        self.assertAlmostEqual(scheduling_gap(110.0,100.0),0.1)
        self.assertAlmostEqual(scheduling_gap(-90.0,-100.0),0.1)
        self.assertEqual(scheduling_gap(100.0,100.0),0)
        self.assertIsNone(scheduling_gap(None,100.0))
        self.assertIsNone(scheduling_gap(110.0,None))
        for upper,incumbent in ((90,100),(float("inf"),100),(110,float("nan"))):
            with self.assertRaises(ValueError):
                scheduling_gap(upper,incumbent)

    def test_exact_source_cold_and_finite_budget_contract(self):
        config=json.loads((ROOT/"config/tiny_reserve_benders.json").read_text())
        baseline=copy.deepcopy(config)
        validate_configuration(config)
        self.assertEqual(config,baseline)
        for key,value in (("scheduling_decomposition_policy","wrong"),
                ("scheduling_include_reserves",False),("scheduling_seed_policy","external"),
                ("scheduling_storage_policy","cached_model_v1"),("scheduling_compaction_policy","off"),
                ("scheduling_benders_max_rounds",True),("scheduling_benders_max_rounds",0),
                ("scheduling_seconds",float("inf")),("scheduling_relative_gap",0),
                ("scheduling_benders_finalize_seconds",119),("scheduling_benders_recourse_seconds",-1)):
            bad=copy.deepcopy(config);bad[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                validate_configuration(bad)


if __name__=="__main__":
    unittest.main()
