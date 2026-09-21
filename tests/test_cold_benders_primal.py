import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"scripts"))
from run_reserve_benders import (PRIMAL_POLICY, ROUND_SCHEMA, artifact,
    interrupted_construction, terminal_status, validate_configuration, run_stage)
from run_disk_worker import NativeCallDeadlineExceeded
from go3cpu.controller import atomic_json, sha256


class ColdBendersPrimalTests(unittest.TestCase):
    def test_r11_changes_only_constructor_budget_and_enclosing_allowances(self):
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r10.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r11.json").read_text())
        changed={k for k in previous.keys() | current.keys() if previous.get(k)!=current.get(k)}
        self.assertEqual(changed,{"pilot_id","scheduling_seconds",
            "scheduling_benders_master_round_seconds","scheduling_benders_construction_seconds"})
        validate_configuration(current)
        self.assertEqual(current["scheduling_benders_construction_seconds"],700)
        self.assertEqual(current["scheduling_benders_fixed_cost_seconds"],700)
        self.assertEqual(current["scheduling_benders_master_round_seconds"],1500)
        self.assertEqual(current["scheduling_seconds"],2000)
        self.assertEqual(current["total_seconds"],7200)
        self.assertEqual(current["evaluation_reserve_seconds"],2400)
        self.assertEqual(current["minimum_available_memory_gib"],2)
        self.assertEqual(current["minimum_free_gib"],30)
        self.assertGreater(current["scheduling_seconds"],sum(current[k] for k in (
            "scheduling_benders_master_round_seconds","scheduling_benders_recourse_reserve_seconds",
            "scheduling_benders_finalize_seconds")))
        self.assertEqual(current["maximum_full_runs"],1)
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["cold_primal_budget_goal_continuation"]["registered_next_attempt"],
                         current["pilot_id"])
        self.assertEqual(auth["attempts"][current["pilot_id"]],
                         {k:current[k] for k in ("network","scenario","input_sha256")})

    def test_registered_change_preserves_every_existing_contract(self):
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r09.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r10.json").read_text())
        changed={"pilot_id","scheduling_benders_primal_policy",
                 "scheduling_benders_construction_seconds","scheduling_benders_fixed_cost_seconds"}
        self.assertEqual({k:v for k,v in current.items() if k not in changed},
                         {k:v for k,v in previous.items() if k not in changed})
        validate_configuration(current)
        self.assertEqual(current["scheduling_benders_primal_policy"],PRIMAL_POLICY)
        self.assertEqual(current["scheduling_seed_policy"],"off")
        self.assertEqual(current["scheduling_benders_construction_seconds"],300)
        self.assertEqual(current["scheduling_benders_fixed_cost_seconds"],700)
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["attempts"][current["pilot_id"]],
                         {k:current[k] for k in ("network","scenario","input_sha256")})

    def test_budgets_and_primal_status_cannot_masquerade_as_mip_gap(self):
        config=json.loads((ROOT/"config/tiny_reserve_benders_cold_primal.json").read_text())
        validate_configuration(config)
        self.assertEqual(terminal_status("source_feasible_constructed_schedule",False),(16,"SOLUTION_LIMIT"))
        for key,value in (("scheduling_benders_primal_policy","typo"),
                ("scheduling_benders_primal_policy","off"),
                ("scheduling_benders_construction_seconds",True),
                ("scheduling_benders_fixed_cost_seconds",0),
                ("scheduling_benders_fixed_cost_seconds",float("inf")),
                ("scheduling_benders_fixed_cost_seconds",20)):
            bad=copy.deepcopy(config);bad[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                validate_configuration(bad)

    def test_interrupted_primal_is_hash_bound_and_not_a_final_certificate(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp",prefix="cold_fallback_") as directory:
            d=Path(directory)
            request={"mode":"master","identity":{"source":"test"},"round":1}
            atomic_json(d/"request.json",request)
            self.assertIsNone(interrupted_construction(d,request,{"scheduling_benders_primal_policy":PRIMAL_POLICY}))
            vector=d/"construction_primal.bin";vector.write_bytes(struct.pack("d",1.0))
            record={"schema":ROUND_SCHEMA,"complete":True,"mode":"master","identity":request["identity"],
                "primal_policy":PRIMAL_POLICY,"request_sha256":sha256(d/"request.json"),
                "statistics":{"has_primal":True,"bound":None,"relative_gap":None},
                "audit":{"complete":True,"pass":True,"maximum_cut_violation":0.0,"variables":1},
                "primal":dict(artifact(vector),bytes=8,elements=1)}
            atomic_json(d/"construction_result.json",record)
            config={"scheduling_benders_primal_policy":PRIMAL_POLICY}
            saved,ref=interrupted_construction(d,request,config)
            self.assertEqual(saved,record)
            self.assertEqual(ref["sha256"],sha256(d/"construction_result.json"))
            self.assertNotIn("original_audit",saved) # original recourse recomposition still owed
            self.assertIsNone(interrupted_construction(d,request,{}))
            self.assertIsNone(interrupted_construction(d,dict(request,mode="recourse"),config))
            for key,value in (("identity",{}),("request_sha256","foreign"),("complete",False),
                    ("statistics",{"has_primal":True,"bound":1.0,"relative_gap":0.0}),
                    ("audit",{"complete":True,"pass":False}),
                    ("primal",dict(record["primal"],elements=2))):
                bad=copy.deepcopy(record);bad[key]=value
                atomic_json(d/"construction_result.json",bad)
                with self.subTest(key=key),self.assertRaises(ValueError):
                    interrupted_construction(d,request,config)
            atomic_json(d/"construction_result.json",record)
            vector.write_bytes(struct.pack("d",0.0))
            with self.assertRaises(ValueError):
                interrupted_construction(d,request,config)

    def test_cost_timeout_returns_only_saved_audited_master_and_records_non_normal_exit(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp",prefix="cold_timeout_") as directory:
            output=Path(directory);d=output/"master"
            request={"mode":"master","round":1,"identity":{"source":"current"}}
            config=json.loads((ROOT/"config/tiny_reserve_benders_cold_primal.json").read_text())
            def interrupted(*args,**kwargs):
                vector=d/"construction_primal.bin";vector.write_bytes(struct.pack("d",1.0))
                record={"schema":ROUND_SCHEMA,"complete":True,"mode":"master","pid":123,
                    "identity":request["identity"],"request_sha256":sha256(d/"request.json"),
                    "primal_policy":PRIMAL_POLICY,
                    "statistics":{"has_primal":True,"bound":None,"relative_gap":None},
                    "audit":{"complete":True,"pass":True,"maximum_cut_violation":0.0,"variables":1},
                    "primal":dict(artifact(vector),bytes=8,elements=1)}
                atomic_json(d/"construction_result.json",record)
                raise NativeCallDeadlineExceeded({"pid":123,"begin_event":{
                    "mode":"master","actual_limit_seconds":4,"phase":"fixed_commitment_cost_lp"}})
            with patch("run_reserve_benders.native_environment",return_value=None),\
                    patch("run_reserve_benders.launch_stage",side_effect=interrupted):
                saved,ref=run_stage([],output,output/"config.json",request,d,100.0,config)
            exit_record=json.loads((d/"exit.json").read_text())
            interruption=json.loads((d/"interruption.json").read_text())
            self.assertIsNone(exit_record["returncode"])
            self.assertTrue(exit_record["interrupted"])
            self.assertTrue(exit_record["reserve_and_full_original_audit_still_required"])
            self.assertEqual(interruption["kind"],"native_call_deadline")
            self.assertTrue(interruption["launch_cleanup_completed"])
            self.assertEqual(Path(ref["path"]),d/"construction_result.json")
            self.assertIn("interrupted_stage_ref",saved)
            self.assertIsNone(saved["statistics"]["bound"])


if __name__=="__main__":
    unittest.main()
