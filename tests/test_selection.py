import unittest

from go3cpu.selection import prefer_verified_candidate, verified_candidate_rank


def certificate(objective=100.0, physical=1):
    return {"pass": True, "complete": True, "objective": objective,
            "official_feas": 1, "official_phys_feas": physical,
            "independent_hard_pass": True, "objective_agreement": True,
            "contingencies_required": 9, "contingencies_completed": 9}


class VerifiedSelectionTests(unittest.TestCase):
    def test_physical_point_displaces_higher_objective_hard_only_point(self):
        self.assertTrue(prefer_verified_candidate(
            certificate(90.0), certificate(110.0, physical=0), prefer_physical=True))
        self.assertFalse(prefer_verified_candidate(
            certificate(110.0, physical=0), certificate(90.0), prefer_physical=True))

    def test_missing_physical_flag_is_not_physical_success(self):
        candidate = certificate(200.0)
        candidate.pop("official_phys_feas")
        self.assertEqual(verified_candidate_rank(candidate, prefer_physical=True), (0, 200.0))
        self.assertFalse(prefer_verified_candidate(candidate, certificate(), prefer_physical=True))

    def test_best_objective_within_each_class_and_first_on_tie(self):
        for physical in (0, 1):
            current = certificate(100.0, physical=physical)
            self.assertTrue(prefer_verified_candidate(
                certificate(101.0, physical=physical), current, prefer_physical=True))
            for obj in (99.0, 100.0):
                self.assertFalse(prefer_verified_candidate(
                    certificate(obj, physical=physical), current, prefer_physical=True))

    def test_campaign_rejects_incomplete_or_inconsistent_verification(self):
        for key, value in (("pass", False), ("complete", False), ("official_feas", 0),
                ("independent_hard_pass", False), ("objective_agreement", False),
                ("contingencies_required", 0), ("contingencies_required", True),
                ("contingencies_required", 9.0), ("contingencies_completed", 8)):
            invalid = dict(certificate(), **{key: value})
            self.assertIsNone(verified_candidate_rank(invalid, prefer_physical=True))
            self.assertFalse(prefer_verified_candidate(invalid, None, prefer_physical=True))

    def test_nonfinite_and_missing_objectives_rejected_in_both_modes(self):
        for mode in (False, True):
            for value in (float("nan"), float("inf"), -float("inf"), None, True, "100"):
                self.assertIsNone(verified_candidate_rank(
                    dict(certificate(), objective=value), prefer_physical=mode))
            self.assertFalse(prefer_verified_candidate(None, None, prefer_physical=mode))

    def test_historical_hard_only_objective_ordering_unchanged(self):
        hard_only = {"pass": True, "complete": True, "objective": 110.0}
        self.assertTrue(prefer_verified_candidate(hard_only, certificate(100.0)))
        self.assertFalse(prefer_verified_candidate(certificate(100.0), hard_only))
        self.assertEqual(verified_candidate_rank(hard_only), (0, 110.0))
        self.assertTrue(prefer_verified_candidate(hard_only, None))


if __name__ == "__main__":
    unittest.main()
