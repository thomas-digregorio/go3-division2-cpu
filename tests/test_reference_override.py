import json
import math
from pathlib import Path
import tempfile
import unittest

from go3cpu.campaign import (sixth_best_target, quality_gate, campaign_latch,
    FIFTH_POSITIVE_POLICY, NETWORK_ORDER, validate_reference_policy)
from go3cpu.controller import atomic_json

ROOT = Path(__file__).resolve().parents[1]


class ReferenceOverrideTests(unittest.TestCase):
    def test_23k_r02_changes_only_scheduling_storage_and_attempt_identity(self):
        original=json.loads((ROOT/"config/campaign_n23643_s003_r01.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r02.json").read_text())
        changed={"pilot_id","scheduling_storage_policy"}
        self.assertEqual({k:v for k,v in original.items() if k not in changed},
                         {k:v for k,v in current.items() if k not in changed})
        self.assertEqual(current["scheduling_storage_policy"],"native_handoff_trimmed_metadata_v1")
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["attempts"][current["pilot_id"]],
                         {k:current[k] for k in ("network","scenario","input_sha256")})
        tiny=json.loads((ROOT/"config/tiny_trimmed_scheduling.json").read_text())
        baseline=json.loads((ROOT/"config/tiny_reserve_bounded.json").read_text())
        self.assertEqual({k:v for k,v in tiny.items() if k!="scheduling_storage_policy"},
                         {k:v for k,v in baseline.items() if k!="scheduling_storage_policy"})

    def test_registered_23k_preserves_8316_numerical_route(self):
        baseline=json.loads((ROOT/"config/campaign_n08316_s103_r03.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r01.json").read_text())
        changed={"pilot_id","network","scenario","input_path","input_sha256","case_manifest_path",
            "comparison_manifest_path","quality_reference_policy","official_contingency_batch_size",
            "evaluation_reserve_seconds","reserve_storage_policy"}
        self.assertEqual({k:v for k,v in baseline.items() if k not in changed},
                         {k:v for k,v in current.items() if k not in changed})
        self.assertEqual(current["reserve_storage_policy"],"bounded_lifetime_v1")
        self.assertEqual(current["official_contingency_batch_size"],512)
        self.assertEqual(current["total_seconds"],7200)
        self.assertEqual(current["evaluation_reserve_seconds"],2400)

    def report(self):
        return json.loads((ROOT/"manifests/campaign/published_C3E4N23643D2_s003.json").read_text())

    def target(self, **kwargs):
        return sixth_best_target(self.report(), network="C3E4N23643D2", scenario="003", **kwargs)

    def test_original_policy_still_rejects_zero_sixth(self):
        with self.assertRaisesRegex(ValueError, "positive"):
            self.target()

    def test_approved_scope_reference_is_explicit_not_relabelled_sixth(self):
        target = self.target(reference_policy=FIFTH_POSITIVE_POLICY)
        self.assertEqual(target["sixth_best_score"], 0)
        self.assertEqual(target["reference_score"], 353804820.240399)
        self.assertEqual(target["reference_rank"], 5)
        self.assertEqual(target["metric"], "fifth_best_positive_eligible_score")
        self.assertAlmostEqual(target["minimum_score"], 318424338.2163591, delta=1e-6)
        for network, scenario in (("C3E4N08316D2", "003"), ("C3E4N23643D2", "004")):
            with self.assertRaisesRegex(ValueError, "scope"):
                validate_reference_policy(FIFTH_POSITIVE_POLICY, network, scenario)
        with self.assertRaises(ValueError):
            validate_reference_policy("new_unapproved_policy", "C3E4N23643D2", "003")

    def test_override_requires_zero_sixth(self):
        report = self.report()
        for row in report["records"]:
            if row.get("score") is not None and float(row["score"]) == 0:
                row.update(score="1", objective="1")
        with self.assertRaisesRegex(ValueError, "zero sixth"):
            sixth_best_target(report, network="C3E4N23643D2", scenario="003", reference_policy=FIFTH_POSITIVE_POLICY)

    def test_quality_boundary_and_all_original_acceptance_gates(self):
        target = self.target(reference_policy=FIFTH_POSITIVE_POLICY)
        certificate = {"pass":True,"complete":True,"official_feas":1,"official_phys_feas":1,
            "independent_hard_pass":True,"objective_agreement":True,"contingencies_required":9,
            "contingencies_completed":9,"objective":target["minimum_score"]}
        def gate(c=certificate, **kwargs):
            return quality_gate(c, target, pipeline_completed=kwargs.get("pipeline",True),
                                within_deadline=kwargs.get("deadline",True))
        self.assertTrue(gate()["pass"])
        self.assertIsNone(gate()["relative_shortfall_from_sixth"])
        for key, value in (("objective",math.nextafter(target["minimum_score"],0)),
                           ("contingencies_completed",8),("official_phys_feas",0),("complete",False)):
            self.assertFalse(gate({**certificate,key:value})["pass"])
        self.assertFalse(gate(deadline=False)["pass"])
        self.assertFalse(gate(pipeline=False)["pass"])

    def test_latch_requires_explicit_scoped_approval_before_predecessors(self):
        config = {"pilot_id":"campaign_n23643_s003_r01","network":"C3E4N23643D2",
            "scenario":"003","input_sha256":"test","cold_start":True,"allow_pop_solution":False,
            "total_seconds":7200,"quality_reference_policy":FIFTH_POSITIVE_POLICY}
        auth = {"network_order":list(NETWORK_ORDER),"cold_start_required":True,"reference_rank":6,
            "relative_shortfall_limit":0.10,"maximum_end_to_end_seconds":7200,"completed_networks":{},
            "attempts":{config["pilot_id"]:{k:config[k] for k in ("network","scenario","input_sha256")}}}
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            root = Path(directory)
            atomic_json(root/"manifests/authorization_campaign.json", auth)
            with self.assertRaisesRegex(ValueError, "scoped user authorization"):
                campaign_latch(root, config)
            approved = json.loads((ROOT/"manifests/authorization_campaign.json").read_text())["reference_overrides"]
            auth["reference_overrides"] = approved
            atomic_json(root/"manifests/authorization_campaign.json", auth)
            with self.assertRaisesRegex(ValueError, "Preceding network"):
                campaign_latch(root, config)


if __name__ == "__main__":
    unittest.main()
