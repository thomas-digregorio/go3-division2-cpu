from copy import deepcopy
import contextlib
import io
import json
from pathlib import Path
import tempfile
import time
import unittest
import itertools

import numpy as np

from fixtures import tiny_case, tiny_solution
from go3cpu.contract import require_supported, case_manifest, load_case
from go3cpu.independent import check, branch_flow, trajectories, pwl_value
from go3cpu.official import configure_imports

ROOT = Path(__file__).resolve().parents[1]


class PhysicsTests(unittest.TestCase):
    def setUp(self):
        self.case = tiny_case()
        self.sol = tiny_solution(self.case)

    def test_tiny_complete_independent_check(self):
        result = check(self.case, self.sol)
        self.assertTrue(result["hard_constraints_pass"])
        self.assertTrue(result["complete"])
        self.assertEqual(result["contingencies_completed"], 9)
        self.assertAlmostEqual(result["objective"], -1906.1, places=7)

    def test_exact_pmin_on_off(self):
        x = self.sol["time_series_output"]["simple_dispatchable_device"][0]
        x["p_on"][1] = 0.1
        self.assertAlmostEqual(check(self.case, self.sol)["hard_residuals"]["conditional_pmin_pmax"], 0.1)
        x["on_status"][1] = 0
        x["p_on"][1] = 0.0
        self.assertEqual(check(self.case, self.sol)["hard_residuals"]["conditional_pmin_pmax"], 0)

    def test_initial_uptime(self):
        self.case["network"]["simple_dispatchable_device"][0]["initial_status"]["accu_up_time"] = 0.25
        self.sol["time_series_output"]["simple_dispatchable_device"][0]["on_status"][0] = 0
        self.assertEqual(check(self.case, self.sol)["hard_residuals"]["minimum_up_time"], 1)

    def test_initial_downtime(self):
        g = self.case["network"]["simple_dispatchable_device"][0]
        g["initial_status"].update(on_status=0, accu_up_time=0.0, accu_down_time=0.25, p=0.0)
        self.assertEqual(check(self.case, self.sol)["hard_residuals"]["minimum_down_time"], 1)

    def test_unequal_duration_ramp(self):
        x = self.sol["time_series_output"]["simple_dispatchable_device"][0]
        x["p_on"] = [1.0, 2.0, 1.0]
        self.assertAlmostEqual(check(self.case, self.sol)["hard_residuals"]["ramping"], 0.5)

    def test_startup_shutdown_trajectories(self):
        g = deepcopy(self.case["network"]["simple_dispatchable_device"][0])
        ts = deepcopy(self.case["time_series_input"]["simple_dispatchable_device"][0])
        g["initial_status"].update(on_status=0, p=0.0)
        g["p_startup_ramp_ub"] = g["p_shutdown_ramp_ub"] = 1.0
        ts["p_lb"] = [1.2]*3
        _, _, su, _ = trajectories(g, ts, [0,0,1], [1.0,0.25,0.25])
        np.testing.assert_allclose(su, [0.7,0.95,0])
        g["initial_status"].update(on_status=1, p=1.2)
        _, _, _, sd = trajectories(g, ts, [1,0,0], [1.0,0.25,0.25])
        np.testing.assert_allclose(sd, [0,0.95,0.7])

    def test_reserve_headroom_and_eligibility(self):
        x = self.sol["time_series_output"]["simple_dispatchable_device"][0]
        x["p_on"][0] = 2.9
        x["p_reg_res_up"][0] = 0.2
        self.assertAlmostEqual(check(self.case, self.sol)["hard_residuals"]["reserve_p_headroom"], 0.1)
        x["p_nsyn_res"][0] = 0.1
        self.assertGreater(check(self.case, self.sol)["hard_residuals"]["reserve_capability"], 0)

    def test_discrete_shunt_and_tap(self):
        self.sol["time_series_output"]["shunt"][0]["step"][0] = 0.5
        self.assertAlmostEqual(check(self.case, self.sol)["hard_residuals"]["shunt_integrality"], 0.5)
        self.sol["time_series_output"]["two_winding_transformer"][0]["tm"][0] = 1.2
        self.assertAlmostEqual(check(self.case, self.sol)["hard_residuals"]["tap_magnitude"], 0.15)

    def test_ac_losses_and_phase_shift(self):
        b = {"r":0.01, "x":0.1, "b":0.02}
        vf, vt, tm, ta = 1.02*np.exp(0.12j), 0.97*np.exp(-0.02j), 1.04, 0.07
        sf, st = branch_flow(b, vf, vt, tm=tm, ta=ta)
        loss = 0.01*abs((vf/(tm*np.exp(1j*ta))-vt)/complex(0.01,0.1))**2
        self.assertAlmostEqual((sf+st).real, loss, places=12)
        self.assertGreater(loss, 0)
        self.assertEqual(branch_flow(b, vf, vt, on=0), (0j,0j))

    def test_pwl_and_interval_cost(self):
        self.assertEqual(pwl_value([[2,1],[5,2]], 2), 7)
        result = check(self.case, self.sol)
        self.assertAlmostEqual(result["costs_total"]["production"], 17.5)
        self.assertAlmostEqual(result["costs_total"]["demand_benefit"], 1750)

    def test_permuted_pwl_blocks_and_negative_slopes(self):
        production=[[-2.0,0.2],[10.0,0.4],[30.0,3.4]]
        benefit=[[100.0,0.5],[1000.0,1.0],[500.0,2.5]]
        for blocks in itertools.permutations(production):
            self.assertAlmostEqual(pwl_value(blocks,1.0),15.6)
        for blocks in itertools.permutations(benefit):
            self.assertAlmostEqual(pwl_value(blocks,1.0,consumer=True),1000.0)
        self.assertEqual(pwl_value([[-10,1],[-20,1]],1,consumer=True),-10)

    def test_cost_ordering_does_not_mutate_source(self):
        blocks=[[100.0,0.5],[1000.0,1.0]]
        before=deepcopy(blocks)
        self.assertEqual(pwl_value(blocks,1,consumer=True),1000)
        self.assertEqual(blocks,before)

    def test_unknown_required_features_rejected(self):
        for field in ("energy_req_lb", "energy_req_ub", "startup_states"):
            case = deepcopy(self.case)
            case["network"]["simple_dispatchable_device"][0][field] = [[0,1,1]]
            with self.assertRaises(NotImplementedError):
                require_supported(case)

    def test_serialization_and_identity(self):
        round_trip = json.loads(json.dumps(self.sol, allow_nan=False))
        self.assertEqual(check(self.case, round_trip)["objective"], check(self.case,self.sol)["objective"])
        round_trip["time_series_output"]["bus"].pop()
        with self.assertRaises(ValueError):
            check(self.case, round_trip)

    def test_deadline_does_not_claim_partial_pass(self):
        with self.assertRaises(TimeoutError):
            check(self.case, self.sol, deadline=time.perf_counter()-1)
        self.assertFalse(check(self.case,self.sol,exhaustive=False)["complete"])

    def test_input_hash_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            p = Path(d)/"input.json"
            p.write_text(json.dumps(self.case))
            with self.assertRaises(ValueError):
                load_case(p, "bad")


class OfficialCrossChecks(unittest.TestCase):
    def official(self, case, sol):
        configure_imports(ROOT)
        from datamodel.input.data import InputDataFile
        from datamodel.output.data import OutputDataFile
        from datautilities import arraydata, evaluation, validation
        config = json.loads((ROOT/".cache/upstream/C3DataUtilities/config.json").read_text())
        p, s = InputDataFile(**case), OutputDataFile(**sol)
        validation.solution_model_checks(p,s,config)
        with contextlib.redirect_stdout(io.StringIO()):
            pa, sa = arraydata.InputData(), arraydata.OutputData()
            pa.set_from_data_model(p)
            sa.set_from_data_model(pa,s)
            ev = evaluation.SolutionEvaluator(pa,sa,config=config)
            ev.run()
        return ev

    def test_objective_and_contingencies_match_official(self):
        case = tiny_case()
        sol = tiny_solution(case)
        sol["time_series_output"]["bus"][0]["va"] = [0.04,0.06,0.03]
        sol["time_series_output"]["two_winding_transformer"][0]["tm"] = [0.98,1.03,1.01]
        # Deliberately congest the fixture so contingency aggregation is nonzero.
        for branch in case["network"]["ac_line"]+case["network"]["two_winding_transformer"]:
            branch["mva_ub_nom"] = 0.2
            branch["mva_ub_em"] = 0.25
        independent, official = check(case,sol), self.official(case,sol)
        self.assertAlmostEqual(independent["objective"], official.get_obj(), places=7)
        self.assertGreater(independent["costs_total"]["contingency_worst"], 0)
        self.assertAlmostEqual(independent["costs_total"]["contingency_worst"], -official.z_k_worst_case, places=8)
        self.assertAlmostEqual(independent["costs_total"]["contingency_average"], -official.z_k_average_case, places=8)

    def test_consumer_ordering_regression_against_official(self):
        case=tiny_case(); sol=tiny_solution(case)
        case["time_series_input"]["simple_dispatchable_device"][1]["cost"]=[[[100.0,0.5],[1000.0,1.0]] for _ in range(3)]
        independent,official=check(case,sol),self.official(case,sol)
        self.assertAlmostEqual(independent["costs_total"]["demand_benefit"],1750)
        self.assertAlmostEqual(independent["objective"],official.get_obj(),places=8)

    def test_multiblock_producer_and_consumer_agree_with_official(self):
        case=tiny_case(); sol=tiny_solution(case)
        devices=case["time_series_input"]["simple_dispatchable_device"]
        devices[0]["cost"]=[[[30.0,3.4],[-2.0,0.2],[10.0,0.4]] for _ in range(3)]
        devices[1]["cost"]=[[[100.0,0.5],[1000.0,1.0],[500.0,2.5]] for _ in range(3)]
        self.assertAlmostEqual(check(case,sol)["objective"],self.official(case,sol).get_obj(),places=8)

    def test_official_rejects_bound_ramp_reserve(self):
        case = tiny_case()
        for field, values in (("p_on", [0.1,1,1]), ("p_on", [1,2,1]), ("p_nsyn_res", [0.1,0,0])):
            sol = tiny_solution(case)
            sol["time_series_output"]["simple_dispatchable_device"][0][field] = values
            self.assertFalse(check(case,sol)["hard_constraints_pass"])
            self.assertEqual(self.official(case,sol).get_feas(), 0)

    def test_missing_output_field_rejected(self):
        case = tiny_case(); sol = tiny_solution(case)
        del sol["time_series_output"]["simple_dispatchable_device"][0]["p_on"]
        with self.assertRaises(Exception):
            self.official(case,sol)


if __name__ == "__main__":
    unittest.main()
