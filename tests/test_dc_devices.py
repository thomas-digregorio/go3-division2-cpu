"""DC terminal physics and source fidelity on tiny, original fixtures only."""
from copy import deepcopy
import json
import unittest

import numpy as np

from fixtures import tiny_case, tiny_solution, tiny_dc_case, tiny_dc_solution
from go3cpu.contract import require_supported
from go3cpu.independent import check
import test_contract_physics as oracle


class DcDeviceTests(unittest.TestCase):
    def test_source_contract_does_not_mutate_or_zero_initial_values(self):
        case = tiny_dc_case()
        before = deepcopy(case)
        require_supported(case)
        self.assertEqual(case, before)
        self.assertEqual(case["network"]["dc_line"][0]["initial_status"]["pdc_fr"], 0.35)

    def test_invalid_source_data_rejected(self):
        changes = [("pdc_ub", -1.0), ("qdc_fr_lb", 0.1), ("qdc_fr_ub", -0.1),
                   ("qdc_to_lb", 0.1), ("qdc_to_ub", -0.1),
                   ("fr_bus", "unknown"), ("to_bus", "b0"), ("uid", "a0"), ("uid", "g")]
        changes += [(field, value) for field in
                    ("pdc_ub", "qdc_fr_lb", "qdc_fr_ub", "qdc_to_lb", "qdc_to_ub")
                    for value in (float("nan"), float("inf"), True, "0.5")]
        for field, value in changes:
            with self.subTest(field=field, value=value):
                case = tiny_dc_case()
                case["network"]["dc_line"][0][field] = value
                with self.assertRaises(ValueError):
                    require_supported(case)
        case = tiny_dc_case()
        case["network"]["dc_line"].append(deepcopy(case["network"]["dc_line"][0]))
        with self.assertRaises(ValueError):
            require_supported(case)

    def test_invalid_initial_terminal_values_rejected(self):
        for field in ("pdc_fr", "qdc_fr", "qdc_to"):
            for value in (-9, 9, float("nan"), float("inf"), False, "0"):
                with self.subTest(field=field, value=value):
                    case = tiny_dc_case()
                    case["network"]["dc_line"][0]["initial_status"][field] = value
                    with self.assertRaises(ValueError):
                        require_supported(case)

    def test_dc_outage_remains_explicitly_unsupported(self):
        case = tiny_dc_case()
        case["reliability"]["contingency"][0]["components"] = ["dc0"]
        with self.assertRaisesRegex(NotImplementedError, "single source AC branch outage"):
            require_supported(case)

    def test_output_identities_fields_and_interval_coverage(self):
        case = tiny_dc_case()
        for kind in ("missing", "duplicate", "extra", "missing_field", "extra_field",
                     "short", "nan", "inf"):
            with self.subTest(kind=kind):
                sol = tiny_dc_solution(case)
                rows = sol["time_series_output"]["dc_line"]
                if kind == "missing":
                    rows.clear()
                elif kind == "duplicate":
                    rows.append(deepcopy(rows[0]))
                elif kind == "extra":
                    rows.append(dict(deepcopy(rows[0]), uid="dc_unknown"))
                elif kind == "missing_field":
                    del rows[0]["qdc_to"]
                elif kind == "extra_field":
                    rows[0]["pdc_to"] = [99]*3
                else:
                    rows[0]["pdc_fr"] = [0.1] if kind == "short" else [0, float(kind), 0]
                with self.assertRaises(ValueError):
                    check(case, sol)

    def test_signed_terminal_balance_and_reported_units(self):
        case = tiny_dc_case()
        for sign in (1, -1):
            sol = tiny_dc_solution(case)
            sol["time_series_output"]["dc_line"][0]["pdc_fr"] = [sign*0.35]*3
            before = deepcopy(sol)
            result = check(case, sol)
            # At flat voltage, each AC terminal supplies 0.01 p.u. of charging Q.
            self.assertAlmostEqual(result["max_p_imbalance_pu"], 1-sign*0.35)
            self.assertAlmostEqual(result["max_q_imbalance_pu"], 0.11)
            flow = result["dc_flows"][0]
            np.testing.assert_allclose(flow["p_fr_pu"], sign*0.35)
            np.testing.assert_allclose(flow["p_to_pu"], -sign*0.35)
            np.testing.assert_allclose(flow["p_fr_mw"], sign*35)
            np.testing.assert_allclose(flow["q_fr_mvar"], 12)
            np.testing.assert_allclose(flow["q_to_mvar"], -8)
            self.assertEqual(sol, before)
            round_trip = json.loads(json.dumps(sol, allow_nan=False))
            self.assertEqual(check(case, round_trip)["objective"], result["objective"])

    def test_all_six_terminal_limits_match_official(self):
        examples = (("pdc_fr", "dc_active_power", "p", -0.8, 0.8),
                    ("qdc_fr", "dc_reactive_from", "q_fr", -0.3, 0.4),
                    ("qdc_to", "dc_reactive_to", "q_to", -0.2, 0.5))
        for field, residual, official_name, lo, hi in examples:
            for upper in (False, True):
                with self.subTest(field=field, upper=upper):
                    case = tiny_dc_case()
                    sol = tiny_dc_solution(case)
                    sol["time_series_output"]["dc_line"][0][field][1] = hi+0.02 if upper else lo-0.02
                    ind, ev = check(case, sol), oracle.OfficialCrossChecks().official(case, sol)
                    self.assertFalse(ind["hard_constraints_pass"])
                    self.assertAlmostEqual(ind["hard_residuals"][residual], 0.02)
                    violation = getattr(ev, f"viol_dcl_t_{official_name}_{'max' if upper else 'min'}")
                    self.assertAlmostEqual(violation["val"], 0.02)
                    self.assertEqual(ev.get_feas(), 0)

    def test_contingency_rhs_and_objective_match_official_in_both_directions(self):
        penalties = []
        for sign in (1, -1):
            case = tiny_dc_case()
            sol = tiny_dc_solution(case)
            sol["time_series_output"]["dc_line"][0]["pdc_fr"] = [sign*v for v in (0.8, 0.6, 0.7)]
            sol["time_series_output"]["bus"][0]["va"] = [0.04, 0.06, 0.03]
            xf = case["network"]["two_winding_transformer"][0]
            # GO3 permits a variable tap magnitude OR phase shift, not both.
            xf.update(ta_lb=0.02, ta_ub=0.02)
            xf["initial_status"]["ta"] = 0.02
            xo = sol["time_series_output"]["two_winding_transformer"][0]
            xo.update(tm=[0.98, 1.03, 1.01], ta=[0.02]*3)
            for branch in case["network"]["ac_line"]+[xf]:
                branch.update(mva_ub_nom=0.12, mva_ub_em=0.15)
            original = deepcopy(case)
            ind, ev = check(case, sol), oracle.OfficialCrossChecks().official(case, sol)
            self.assertTrue(ind["complete"] and ind["hard_constraints_pass"])
            self.assertEqual(ind["contingencies_completed"], 9)
            self.assertEqual(ev.get_feas(), 1)
            self.assertAlmostEqual(ind["objective"], ev.get_obj(), places=7)
            self.assertAlmostEqual(ind["costs_total"]["contingency_worst"], -ev.z_k_worst_case, places=8)
            self.assertAlmostEqual(ind["costs_total"]["contingency_average"], -ev.z_k_average_case, places=8)
            self.assertEqual(case, original)
            penalties.append(ind["costs_total"]["contingency_worst"])
        self.assertGreater(penalties[1], penalties[0])

    def test_zero_capacity_and_zero_reactive_bounds_match_no_dc(self):
        case = tiny_dc_case()
        link = case["network"]["dc_line"][0]
        for field in ("pdc_ub", "qdc_fr_lb", "qdc_fr_ub", "qdc_to_lb", "qdc_to_ub"):
            link[field] = 0.0
        link["initial_status"] = dict(pdc_fr=0.0, qdc_fr=0.0, qdc_to=0.0)
        sol = tiny_dc_solution(case)
        result = check(case, sol)
        base = tiny_case()
        self.assertEqual(result["costs_total"], check(base, tiny_solution(base))["costs_total"])
        self.assertAlmostEqual(result["objective"], oracle.OfficialCrossChecks().official(case, sol).get_obj(), places=8)
        self.assertTrue(result["hard_constraints_pass"])


if __name__ == "__main__":
    unittest.main()
