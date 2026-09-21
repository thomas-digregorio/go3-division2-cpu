"""Synthetic registration/acceptance tests; no competition solve is invoked."""
import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("frozen_regression", HERE / "run.py")
harness = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = harness
spec.loader.exec_module(harness)


class HarnessTests(unittest.TestCase):
    def valid_result(self):
        certificate = dict(pass_=True, complete=True, official_feas=1, official_phys_feas=1,
                           independent_hard_pass=True, objective_agreement=True,
                           contingencies_required=9, contingencies_completed=9, objective=100.)
        certificate["pass"] = certificate.pop("pass_")
        return ({"verified_incumbent": certificate, "pipeline_completed": True,
                 "quality_target": {"sixth_best_score": 100., "relative_shortfall_limit": .1}},
                {"within_local_deadline": True, "elapsed_through_result_serialization_seconds": 123.})

    def test_all_five_configs_keep_identical_numerical_options(self):
        auth = harness.authorization()
        baseline = harness.load(harness.ROOT / auth["baseline_config"])
        self.assertEqual(len(auth["cases"]), 5)
        for case in auth["cases"]:
            harness.validate_config(harness.load(harness.ROOT / case["config_path"]), baseline)

    def test_algorithm_inventory_is_exact(self):
        self.assertTrue(harness.validate_frozen_identity()["original_source_hashes_match"])

    def test_numerical_changes_rejected(self):
        baseline = harness.load(harness.ROOT / harness.authorization()["baseline_config"])
        config = copy.deepcopy(baseline)
        config["scheduling_relative_gap"] = .01
        with self.assertRaisesRegex(RuntimeError, "Numerical settings"):
            harness.validate_config(config, baseline)

    def test_valid_completed_result(self):
        self.assertTrue(harness.accepted_result(*self.valid_result()))

    def test_missing_physical_gate_rejected(self):
        result, completion = self.valid_result()
        result["verified_incumbent"]["official_phys_feas"] = 0
        self.assertFalse(harness.accepted_result(result, completion))

    def test_partial_contingency_screen_rejected(self):
        result, completion = self.valid_result()
        result["verified_incumbent"]["contingencies_completed"] = 8
        self.assertFalse(harness.accepted_result(result, completion))

    def test_quality_failure_rejected(self):
        result, completion = self.valid_result()
        result["verified_incumbent"]["objective"] = 89.9
        self.assertFalse(harness.accepted_result(result, completion))

    def test_timeout_rejected_even_with_certificate(self):
        result, completion = self.valid_result()
        completion["elapsed_through_result_serialization_seconds"] = 7200.
        self.assertFalse(harness.accepted_result(result, completion))

    def test_incomplete_horizon_rejected(self):
        result, completion = self.valid_result()
        result["pipeline_completed"] = False
        self.assertFalse(harness.accepted_result(result, completion))

    def test_direct_case_launch_without_queue_rejected(self):
        case = harness.authorization()["cases"][0]
        config = harness.load(harness.ROOT / case["config_path"])
        with patch.object(harness, "latest_snapshot", return_value={}):
            with self.assertRaisesRegex(RuntimeError, "stop-on-failure queue"):
                harness.regression_latch(harness.ROOT, config)

    def test_failed_predecessor_blocks_later_case(self):
        case = harness.authorization()["cases"][1]
        config = harness.load(harness.ROOT / case["config_path"])
        with patch.object(harness, "latest_snapshot", return_value={"status": "RUNNING", "current_pilot_id": case["pilot_id"]}), \
                patch.object(harness, "read_outcome", return_value={"pass": False}):
            with self.assertRaisesRegex(RuntimeError, "preceding frozen-regression"):
                harness.regression_latch(harness.ROOT, config)

    def test_queue_stops_after_first_failed_child(self):
        auth = harness.authorization()
        with tempfile.TemporaryDirectory(dir=harness.ROOT / "tmp") as temporary:
            queue = Path(temporary) / "queue"
            with patch.object(harness, "check_registration", return_value=(auth, {})), \
                    patch.object(harness, "queue_directory", return_value=queue), \
                    patch.object(harness, "claim_pilot"), \
                    patch("builtins.print"), \
                    patch.object(harness.subprocess, "Popen") as popen, \
                    patch.object(harness, "read_outcome", return_value={"pass": False, "failure": "fixture"}):
                popen.return_value.pid = 999999
                popen.return_value.wait.return_value = 2
                self.assertEqual(harness.run_queue(), 2)
                self.assertEqual(popen.call_count, 1)
                state = harness.latest_snapshot(queue / "state")
                self.assertEqual(state["status"], "STOPPED_ON_FAILURE")
                self.assertEqual(len(state["not_started"]), 4)

    def test_queue_runs_each_case_once_only_after_pass(self):
        auth = harness.authorization()
        with tempfile.TemporaryDirectory(dir=harness.ROOT / "tmp") as temporary:
            queue = Path(temporary) / "queue"
            with patch.object(harness, "check_registration", return_value=(auth, {})), \
                    patch.object(harness, "queue_directory", return_value=queue), \
                    patch.object(harness, "claim_pilot"), \
                    patch("builtins.print"), \
                    patch.object(harness.subprocess, "Popen") as popen, \
                    patch.object(harness, "read_outcome", return_value={"pass": True}):
                popen.return_value.pid = 999999
                popen.return_value.wait.return_value = 0
                self.assertEqual(harness.run_queue(), 0)
                self.assertEqual(popen.call_count, 5)
                state = harness.latest_snapshot(queue / "state")
                self.assertEqual(state["status"], "ALL_PASSED")
                self.assertEqual(len(state["completed"]), 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
