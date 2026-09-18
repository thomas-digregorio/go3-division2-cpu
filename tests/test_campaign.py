from pathlib import Path
import tempfile
import unittest

from go3cpu.campaign import NETWORK_ORDER, sixth_best_target, quality_gate, registered_budget
from go3cpu.controller import atomic_json, registered_latch, claim_pilot
from scripts.audit_sources import archive_source

ROOT = Path(__file__).resolve().parents[1]


def rows():
    return [{"source_row": i, "team": f"team{i}", "model": NETWORK_ORDER[0],
             "scenario": "5", "SW": "1", "Div.": "2", "feas": "1",
             "evaluation_feas": "1", "is_active": "1", "score": str(200-i),
             "objective": str(200-i), "runtime": "12", "uuid": str(i)} for i in range(1, 9)]


class CampaignTests(unittest.TestCase):
    def test_two_hour_campaign_cap_preserves_old_pilot_limit(self):
        for seconds in (1800, 7200):
            self.assertTrue(registered_budget({"pilot_id":"campaign_test", "total_seconds":seconds}))
        for seconds in (7201, float("nan"), float("inf"), 0, -1, True):
            self.assertFalse(registered_budget({"pilot_id":"campaign_test", "total_seconds":seconds}))
        self.assertTrue(registered_budget({"pilot_id":"pilot_002", "total_seconds":1800}))
        self.assertFalse(registered_budget({"pilot_id":"pilot_002", "total_seconds":7200}))

    def target(self, data=None):
        return sixth_best_target({"records": rows() if data is None else data},
                                 network=NETWORK_ORDER[0], scenario="005")

    def test_reference_is_sixth_eligible_not_best_or_average(self):
        target = self.target()
        self.assertEqual(target["sixth_best_score"], 194)
        self.assertAlmostEqual(target["minimum_score"], 174.6)

    def test_excludes_benchmark_infeasible_inactive_and_wrong_switching(self):
        data = rows()
        for key, value in (("team", "ARPA-e Benchmark"), ("feas", "0"),
                           ("is_active", "0"), ("SW", "0")):
            extra = dict(data[0], source_row=len(data)+1, team=f"extra{len(data)}",
                         score="1000", objective="1000")
            extra[key] = value
            data.append(extra)
        self.assertEqual(self.target(data)["sixth_best_score"], 194)

    def test_missing_score_and_nonfinite_rejected(self):
        data = rows()
        data += [dict(data[0], team="missing", score=None), dict(data[0], team="nan", score="nan")]
        self.assertEqual(self.target(data)["eligible_competitors"], 8)

    def test_duplicates_and_insufficient_reference_fail(self):
        with self.assertRaises(ValueError):
            self.target(rows()+[rows()[0]])
        with self.assertRaises(ValueError):
            self.target(rows()[:5])

    def test_full_official_and_physical_verification_required(self):
        target = self.target()
        certificate = {"pass": True, "complete": True, "official_feas": 1,
            "official_phys_feas": 1, "independent_hard_pass": True,
            "objective_agreement": True, "contingencies_required": 9,
            "contingencies_completed": 9, "objective": 180.0}
        def gate(c, **kw):
            return quality_gate(c, target, pipeline_completed=kw.get("completed", True),
                                within_deadline=kw.get("deadline", True))["pass"]
        self.assertTrue(gate(certificate))
        for key, value in (("official_phys_feas",0), ("official_feas",0),
                ("contingencies_completed",8), ("pass",False), ("complete",False),
                ("objective_agreement",False), ("objective",174.0), ("objective",float("nan"))):
            self.assertFalse(gate(dict(certificate, **{key:value})))
        self.assertFalse(gate(certificate,completed=False))
        self.assertFalse(gate(certificate,deadline=False))
        self.assertFalse(gate(None))

    def test_campaign_identity_cold_policy_and_unique_attempt_latch(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root = Path(d)
            identifier = "campaign_n02000_s005_r01"
            identity = {"network": NETWORK_ORDER[0], "scenario":"005", "input_sha256":"test"}
            auth = {"network_order":list(NETWORK_ORDER), "cold_start_required":True,
                "reference_rank":6,"relative_shortfall_limit":0.10,"maximum_end_to_end_seconds":7200,
                "attempts":{identifier:identity},"completed_networks":{}}
            atomic_json(root/"manifests/authorization_campaign.json",auth)
            cfg = {"pilot_id":identifier,"cold_start":True,"allow_pop_solution":False,"total_seconds":7200,**identity}
            latch = registered_latch(root,cfg)
            claim_pilot(latch,{"case":"test"})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"case":"duplicate"})
            for extra in ({"input_sha256":"different"},{"cold_start":False},{"allow_pop_solution":True}):
                with self.assertRaises(ValueError):
                    registered_latch(root,dict(cfg,**extra))
            identifier2 = "campaign_n04224_s001_r01"
            identity2 = dict(identity,network=NETWORK_ORDER[1],scenario="001")
            auth["attempts"][identifier2] = identity2
            atomic_json(root/"manifests/authorization_campaign.json",auth)
            with self.assertRaisesRegex(ValueError,"Preceding network"):
                registered_latch(root,dict(cfg,pilot_id=identifier2,**identity2))

    def test_archive_filter_cannot_extract_pop_or_other_network(self):
        url, pattern = archive_source(NETWORK_ORDER[0])
        self.assertEqual(url,"https://data.openei.org/files/5997/C3E4N02000_20231002.zip")
        self.assertTrue(pattern.fullmatch("D2/C3E4N02000D2/scenario_005.json"))
        for member in ("D2/C3E4N02000D2/pop_solution_005.json", "D1/C3E4N02000D1/scenario_005.json",
                       "D2/C3E4N04224D2/scenario_005.json", "../scenario_005.json"):
            self.assertFalse(pattern.fullmatch(member))
        with self.assertRaises(ValueError):
            archive_source("C3E4N02000D1")


if __name__ == "__main__":
    unittest.main()
