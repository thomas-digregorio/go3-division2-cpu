import json
from pathlib import Path
import unittest

from go3cpu.ac_numerics import AC_NUMERICS_POLICY, AC_INITIALIZATION_POLICY, AC_ZERO_RESERVES_POLICY, validate_ac_numerics
from go3cpu.speedup import final_verification_required

ROOT=Path(__file__).resolve().parents[1]


class AcNumericsTests(unittest.TestCase):
    def test_exact_reserve_reduction_requires_audited_initialization(self):
        cfg=json.loads((ROOT/"config/campaign_n23643_s003_r15.json").read_text())
        self.assertEqual(cfg["ac_zero_reserve_policy"],AC_ZERO_RESERVES_POLICY)
        validate_ac_numerics(cfg)
        for change in ({"ac_zero_reserve_policy":"approximate"},
                       {"ac_initialization_policy":"legacy_v1"},
                       {"ac_primal_guard":"off"}, {"ac_correction_policy":"other"}):
            with self.assertRaises(ValueError):
                validate_ac_numerics({**cfg,**change})
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r14.json").read_text())
        self.assertEqual({k for k in previous.keys()|cfg.keys() if previous.get(k)!=cfg.get(k)},
                         {"pilot_id","ac_zero_reserve_policy"})
        tiny=json.loads((ROOT/"config/tiny_ac_zero_reserves.json").read_text())
        validate_ac_numerics(tiny)
        old_tiny=json.loads((ROOT/"config/tiny_ac_complete_initialization.json").read_text())
        self.assertEqual({k for k in old_tiny.keys()|tiny.keys() if old_tiny.get(k)!=tiny.get(k)},
                         {"ac_zero_reserve_policy"})
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["attempts"][cfg["pilot_id"]],
                         {k:cfg[k] for k in ("network","scenario","input_sha256")})

    def test_complete_initialization_requires_supported_audited_path(self):
        cfg=json.loads((ROOT/"config/campaign_n23643_s003_r14.json").read_text())
        self.assertEqual(cfg["ac_initialization_policy"],AC_INITIALIZATION_POLICY)
        validate_ac_numerics(cfg)
        for change in ({"ac_initialization_policy":"unknown"},
                {"ac_numerics_policy":"legacy_v1"},{"ac_primal_guard":"off"},
                {"ac_shunt_primal_start":"off"},{"ac_interval_primal_start":"off"},
                {"ac_correction_policy":"continuous_shunt_candidate_v1"}):
            with self.assertRaises(ValueError):
                validate_ac_numerics({**cfg,**change})
        validate_ac_numerics({**cfg,"ac_shunt_primal_start":"within_interval_complete_v1"})

    def test_r14_changes_only_initialization_and_registered_attempt(self):
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r13.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r14.json").read_text())
        changed={k for k in previous.keys()|current.keys() if previous.get(k)!=current.get(k)}
        self.assertEqual(changed,{"pilot_id","ac_initialization_policy"})
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["attempts"][current["pilot_id"]],
            {k:current[k] for k in ("network","scenario","input_sha256")})
        tiny=json.loads((ROOT/"config/tiny_ac_complete_initialization.json").read_text())
        validate_ac_numerics(tiny)
        self.assertEqual(tiny["ac_initialization_policy"],current["ac_initialization_policy"])

    def test_legacy_and_explicit_backend_scope(self):
        validate_ac_numerics({})
        valid={"ac_numerics_policy":AC_NUMERICS_POLICY,
            "ac_reserve_policy":"source_joint_reserves_in_ac_v1",
            "ac_fail_fast_on_infeasible":True,"ac_first_interval_seconds_per_solve":600}
        validate_ac_numerics(valid)
        for change in ({"ac_numerics_policy":"unknown"},
                {"ac_fail_fast_on_infeasible":False},{"ac_correction_policy":"other"},
                {"ac_reserve_policy":"off"},{"ac_first_interval_seconds_per_solve":False},
                {"ac_first_interval_seconds_per_solve":float("nan")},
                {"ac_first_interval_seconds_per_solve":0},
                {"ac_first_interval_seconds_per_solve":7201},
                {"final_verification_policy":"omit_checks"}):
            with self.assertRaises(ValueError):
                validate_ac_numerics({**valid,**change})
        with self.assertRaises(ValueError):
            validate_ac_numerics({"ac_first_interval_seconds_per_solve":600})

    def test_incomplete_horizon_rejected_but_complete_horizon_always_checked(self):
        cfg={"pilot_id":"campaign_n23643_s003_r13",
            "final_verification_policy":"complete_pipeline_only_v1"}
        stats={"ac_intervals":[{"interval":i} for i in range(1,49)]}
        self.assertTrue(final_verification_required(cfg,{"stage":"complete"},0,stats,48))
        for stage,rc,partial in (("ac_refinement_failed",1,stats),
                ("complete",0,{"ac_intervals":stats["ac_intervals"][:-1]}),
                ("complete",0,{"ac_intervals":stats["ac_intervals"]+[{'interval':48}]}),
                ("reserves",1,stats)):
            self.assertFalse(final_verification_required(cfg,{"stage":stage},rc,partial,48))
        self.assertTrue(final_verification_required({}, {}, 1, {}, 48))
        with self.assertRaises(ValueError):
            final_verification_required({"final_verification_policy":"omit_checks"},{},0,stats,48)

    def test_r13_does_not_change_source_model_or_safety_gates(self):
        previous=json.loads((ROOT/"config/campaign_n23643_s003_r12.json").read_text())
        current=json.loads((ROOT/"config/campaign_n23643_s003_r13.json").read_text())
        changed={k for k in previous.keys()|current.keys() if previous.get(k)!=current.get(k)}
        self.assertEqual(changed,{"pilot_id","ac_numerics_policy",
            "ac_first_interval_seconds_per_solve","final_verification_policy"})
        validate_ac_numerics(current)
        self.assertEqual(current["ac_first_interval_seconds_per_solve"],600)
        self.assertEqual(current["total_seconds"],7200)
        self.assertEqual(current["minimum_available_memory_gib"],2)
        self.assertEqual(current["input_sha256"],previous["input_sha256"])
        auth=json.loads((ROOT/"manifests/authorization_campaign.json").read_text())
        self.assertEqual(auth["attempts"][current["pilot_id"]],
            {k:current[k] for k in ("network","scenario","input_sha256")})


if __name__=="__main__":
    unittest.main()
