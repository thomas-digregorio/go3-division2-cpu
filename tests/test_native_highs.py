import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from go3cpu.native_highs import backend_record, native_environment, POLICY, MANIFEST, STOCK_ARTIFACT, SOURCE_COMMIT

ROOT=Path(__file__).resolve().parents[1]


class NativeHighsPolicyTests(unittest.TestCase):
    def config(self, **extra):
        return {"scheduling_native_backend_policy":POLICY,
            "scheduling_native_objective_clique_max_size":4096,
            "scheduling_storage_policy":"disk_isolated_native_v1",
            "scheduling_decomposition_policy":"source_reserve_benders_v1",
            "scheduling_native_threads":1,"scheduling_native_parallel":"off",
            "scheduling_mip_lp_solver":"simplex",**extra}

    def test_stock_environment_unchanged(self):
        self.assertIsNone(native_environment({},root=ROOT))
        self.assertEqual(backend_record({},root=ROOT),{"policy":"upstream_jll_v1"})

    def test_invalid_policy_cap_or_scope_rejected(self):
        cases=[{"scheduling_native_backend_policy":"unknown"},
               {"scheduling_native_objective_clique_max_size":1}]
        cases += [self.config(scheduling_native_objective_clique_max_size=v)
                  for v in (True,-1,1.5,4097,None)]
        cases += [self.config(**{k:v}) for k,v in (
            ("scheduling_native_threads",2),("scheduling_native_parallel","on"),
            ("scheduling_mip_lp_solver","hipo"),("scheduling_decomposition_policy","off"))]
        for config in cases:
            with self.subTest(config=config),self.assertRaises(ValueError):
                backend_record(config,root=ROOT)

    def test_checked_child_only_override(self):
        record=backend_record(self.config(),root=ROOT)
        self.assertEqual(record["manifest"]["source_commit"],SOURCE_COMMIT)
        original=dict(os.environ)
        env=native_environment(self.config(),root=ROOT,base_environment={"UNCHANGED":"yes"})
        self.assertEqual(env["UNCHANGED"],"yes")
        self.assertEqual(env["JULIA_DEPOT_PATH"].split(os.pathsep),[
            str(ROOT/"environments/highs-setup-guard-depot"),str(ROOT/"environments/julia-depot")])
        self.assertEqual(dict(os.environ),original)
        self.assertFalse(record["manifest"]["installed_jll_modified"])

    def test_mutated_artifact_rejected(self):
        with patch("go3cpu.native_highs.digest",return_value="0"*64):
            with self.assertRaisesRegex(ValueError,"artifact changed"):
                backend_record(self.config(),root=ROOT)

    def test_build_manifest_is_in_source_inventory(self):
        from go3cpu.provenance import source_hashes
        inventory=source_hashes(ROOT)
        self.assertIn(MANIFEST,inventory)
        self.assertIn("patches/highs-1.15.1-setup-guard.patch",inventory)

    def test_r07_keeps_the_full_case_contract_and_has_new_latch(self):
        from go3cpu.controller import registered_latch
        old=json.loads((ROOT/"config/campaign_n23643_s003_r06.json").read_text())
        new=json.loads((ROOT/"config/campaign_n23643_s003_r07.json").read_text())
        changed={key for key in old.keys() | new.keys() if old.get(key)!=new.get(key)}
        self.assertEqual(changed,{"pilot_id","scheduling_native_backend_policy",
                                  "scheduling_native_objective_clique_max_size"})
        self.assertEqual(new["scheduling_native_backend_policy"],POLICY)
        self.assertEqual(new["scheduling_native_objective_clique_max_size"],4096)
        self.assertNotEqual(registered_latch(ROOT,new),registered_latch(ROOT,old))
        self.assertEqual(new["total_seconds"],7200)
        self.assertEqual(new["minimum_available_memory_gib"],2)


if __name__=="__main__":
    unittest.main()
