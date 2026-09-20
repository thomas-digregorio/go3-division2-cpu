import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from go3cpu.native_highs import (backend_record, native_environment, POLICY, MANIFEST,
    ROOT_POLICY, ROOT_MANIFEST, STOCK_ARTIFACT, SOURCE_COMMIT)

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

    def test_root_memory_policy_is_separate_and_requires_bool_false(self):
        for value in (True,0,1,"off",None):
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,"requires.*disabled"):
                backend_record(self.config(scheduling_native_backend_policy=ROOT_POLICY,
                    scheduling_native_analytic_center=value),root=ROOT)
        for policy in (POLICY,"upstream_jll_v1"):
            with self.subTest(policy=policy),self.assertRaises(ValueError):
                backend_record(self.config(scheduling_native_backend_policy=policy,
                    scheduling_native_analytic_center=False),root=ROOT)

    def test_root_memory_environment_preserves_the_previous_build(self):
        config=self.config(scheduling_native_backend_policy=ROOT_POLICY,
                           scheduling_native_analytic_center=False,
                           scheduling_native_root_presolve_only=True)
        record=backend_record(config,root=ROOT)
        old=backend_record(self.config(),root=ROOT)
        self.assertEqual(record["manifest"]["policy"],ROOT_POLICY)
        self.assertFalse(record["analytic_center_requested"])
        self.assertTrue(record["root_presolve_only_requested"])
        self.assertNotEqual(record["manifest"]["artifact_directory"],old["manifest"]["artifact_directory"])
        self.assertEqual(old["manifest"]["files"]["library"]["sha256"],
            "09e8b2b6eafd425f03390dc5aa192820aa79f825025ee3be54e71a792b75634d")
        env=native_environment(config,root=ROOT,base_environment={"UNCHANGED":"yes"})
        self.assertEqual(env["JULIA_DEPOT_PATH"].split(os.pathsep)[0],
                         str(ROOT/"environments/highs-root-memory-depot"))
        self.assertEqual(env["UNCHANGED"],"yes")
        from go3cpu.provenance import source_hashes
        self.assertIn(ROOT_MANIFEST,source_hashes(ROOT))

    def test_r08_changes_only_the_native_root_memory_policy(self):
        from go3cpu.controller import registered_latch
        old=json.loads((ROOT/"config/campaign_n23643_s003_r07.json").read_text())
        new=json.loads((ROOT/"config/campaign_n23643_s003_r08.json").read_text())
        changed={key for key in old.keys() | new.keys() if old.get(key)!=new.get(key)}
        self.assertEqual(changed,{"pilot_id","scheduling_native_backend_policy",
                                  "scheduling_native_analytic_center","scheduling_native_root_presolve_only"})
        self.assertEqual(new["scheduling_native_backend_policy"],ROOT_POLICY)
        self.assertIs(new["scheduling_native_analytic_center"],False)
        self.assertIs(new["scheduling_native_root_presolve_only"],True)
        self.assertNotEqual(registered_latch(ROOT,new),registered_latch(ROOT,old))

    def test_root_presolve_requires_boolean_and_registered_scope(self):
        for value in (0,1,"true",None):
            with self.subTest(value=value),self.assertRaisesRegex(ValueError,"Boolean"):
                backend_record(self.config(scheduling_native_backend_policy=ROOT_POLICY,
                    scheduling_native_analytic_center=False,scheduling_native_root_presolve_only=value),root=ROOT)
        for policy in (POLICY,"upstream_jll_v1"):
            with self.subTest(policy=policy),self.assertRaises(ValueError):
                backend_record(self.config(scheduling_native_backend_policy=policy,
                    scheduling_native_root_presolve_only=True),root=ROOT)
        for value in (True,False):
            record=backend_record(self.config(scheduling_native_backend_policy=ROOT_POLICY,
                scheduling_native_analytic_center=False,scheduling_native_root_presolve_only=value),root=ROOT)
            self.assertIs(record["root_presolve_only_requested"],value)


if __name__=="__main__":
    unittest.main()
