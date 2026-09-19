from copy import deepcopy
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import numpy as np

from go3cpu.official import configure_imports
from go3cpu.official_batching import (official_contingency_batches,
    VIOLATION_FIELDS, validate_batch_size, _merge_violations)
from fixtures import tiny_dc_case, tiny_dc_solution
import test_contract_physics as oracle

ROOT = Path(__file__).resolve().parents[1]
configure_imports(ROOT)
from datautilities import ctgmodel


class OfficialBatchTests(unittest.TestCase):
    def fixture(self):
        case = tiny_dc_case()
        for i, branch in enumerate(case["network"]["ac_line"]):
            branch["mva_ub_em"] = 0.10 + 0.06 * i
            branch["mva_ub_nom"] = 0.09
        transformer = case["network"]["two_winding_transformer"][0]
        transformer.update(ta_lb=0.025, ta_ub=0.025, mva_ub_em=0.17, mva_ub_nom=0.16)
        transformer["initial_status"]["ta"] = 0.025
        solution = tiny_dc_solution(case)
        out = solution["time_series_output"]
        out["two_winding_transformer"][0]["ta"] = [0.025]*3
        out["two_winding_transformer"][0]["tm"] = [1.02, 1.0, 0.99]
        out["dc_line"][0]["pdc_fr"] = [0.1, -0.1, 0.3]
        # A changing topology is still connected after every listed outage.
        out["ac_line"][0]["on_status"] = [1, 0, 1]
        return case, solution

    def compare(self, case, solution, size):
        before = deepcopy((case, solution))
        original_function = ctgmodel.eval_post_contingency_model
        reference = oracle.OfficialCrossChecks().official(case, solution)
        with official_contingency_batches(size) as audit:
            actual = oracle.OfficialCrossChecks().official(case, solution)
        self.assertIs(ctgmodel.eval_post_contingency_model, original_function)
        self.assertEqual(before, (case, solution))
        self.assertTrue(audit["complete"])
        self.assertEqual(audit["invocations"], 1)
        self.assertEqual(audit["completed_checks"], 3 * len(case["reliability"]["contingency"]))
        self.assertEqual(audit["max_batch_columns"], min(size, actual.problem.num_k))
        self.assertEqual(audit["monitored_ac_branches"], 3)
        np.testing.assert_allclose(actual.t_k_z, reference.t_k_z, rtol=1e-13, atol=1e-10)
        for key in ("z", "z_k_worst_case", "z_k_average_case", "feas", "phys_feas"):
            self.assertAlmostEqual(float(getattr(actual, key)), float(getattr(reference, key)), places=8)
        for field in VIOLATION_FIELDS:
            a, b = getattr(actual, field), getattr(reference, field)
            self.assertAlmostEqual(a["val"], b["val"], places=11)
            self.assertEqual(a["idx"], b["idx"])
        return actual, audit

    def test_all_penalties_match_original_full_evaluation(self):
        case, solution = self.fixture()
        for size in (1, 2, 512):
            with self.subTest(size=size):
                actual, audit = self.compare(case, solution, size)
                self.assertLess(actual.z_k_average_case, 0)
                self.assertEqual(audit["completed_checks"], 9)

    def test_duplicate_components_and_source_order_retained(self):
        case, solution = self.fixture()
        contingencies = case["reliability"]["contingency"]
        contingencies.append({"uid": "duplicate_component_unique_id", "components": ["a0"]})
        case["reliability"]["contingency"] = [contingencies[i] for i in (2, 1, 3, 0)]
        actual, audit = self.compare(case, solution, 3)
        self.assertEqual([(x["start_inclusive"], x["stop_exclusive"]) for x in audit["batches"]], [(0, 3), (3, 4)])
        np.testing.assert_array_equal(actual.t_k_z[:, 2], actual.t_k_z[:, 3])
        # The global average must weight every source column, not each batch.
        expected = np.sum(np.mean(actual.t_k_z, axis=1))
        self.assertAlmostEqual(actual.z_k_average_case, expected, places=10)

    def test_invalid_batch_sizes_and_nested_context_fail_closed(self):
        for size in (None, 0, -1, 4097, True, 1.0, "2"):
            with self.subTest(size=size), self.assertRaises(ValueError):
                validate_batch_size(size)
        original = ctgmodel.eval_post_contingency_model
        with official_contingency_batches(2):
            with self.assertRaisesRegex(RuntimeError, "nested"):
                with official_contingency_batches(1):
                    pass
        self.assertIs(original, ctgmodel.eval_post_contingency_model)

    def test_deadline_is_not_a_completion_and_restores_hook(self):
        case, solution = self.fixture()
        original = ctgmodel.eval_post_contingency_model
        with self.assertRaises(TimeoutError):
            with official_contingency_batches(2, deadline=time.perf_counter()-1) as audit:
                oracle.OfficialCrossChecks().official(case, solution)
        self.assertFalse(audit["complete"])
        self.assertIs(original, ctgmodel.eval_post_contingency_model)

    def test_unwritten_or_nonfinite_penalties_cannot_pass(self):
        case, solution = self.fixture()
        original = ctgmodel.eval_post_contingency_model
        def incomplete(evaluator):
            original(evaluator)
            evaluator.t_k_z[0, 0] = np.nan
        with patch.object(ctgmodel, "eval_post_contingency_model", incomplete):
            with self.assertRaisesRegex(ValueError, "nonfinite"):
                with official_contingency_batches(2) as audit:
                    oracle.OfficialCrossChecks().official(case, solution)
            self.assertIs(ctgmodel.eval_post_contingency_model, incomplete)
        self.assertFalse(audit["complete"])
        self.assertIs(ctgmodel.eval_post_contingency_model, original)

    def test_source_pin_mismatch_refused(self):
        with patch("go3cpu.official_batching.PINNED_CTG_SHA256", "incorrect"):
            with self.assertRaisesRegex(ValueError, "pinned revision"):
                with official_contingency_batches(2):
                    pass

    def test_skipped_disconnected_hook_cannot_claim_complete(self):
        case, solution = self.fixture()
        solution["time_series_output"]["ac_line"][1]["on_status"] = [0, 0, 0]
        with official_contingency_batches(2) as audit:
            actual = oracle.OfficialCrossChecks().official(case, solution)
        self.assertFalse(audit["complete"])
        self.assertEqual(audit["invocations"], 0)
        self.assertEqual(actual.feas, 0)

    def test_violation_tie_break_uses_time_then_source_indices(self):
        from types import SimpleNamespace
        problem = SimpleNamespace(acl_map={"a":0,"b":1}, xfr_map={"x":0}, dcl_map={"d":0})
        def batch(time_index):
            result = SimpleNamespace()
            for field in VIOLATION_FIELDS:
                _, monitor, outage, *_ = field.split("_")
                setattr(result, field, {"val":1.0, "idx":{0:{"acl":"a","xfr":"x"}[monitor],
                    1:{"acl":"b","xfr":"x","dcl":"d"}[outage],2:time_index}})
            return result
        aggregate = {}
        _merge_violations(problem, aggregate, batch(2))
        _merge_violations(problem, aggregate, batch(0))
        _merge_violations(problem, aggregate, batch(1))
        self.assertTrue(all(x["idx"][2] == 0 for x in aggregate.values()))


if __name__ == "__main__":
    unittest.main()
