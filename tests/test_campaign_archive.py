import json
from pathlib import Path
import tempfile
import unittest

from go3cpu.controller import atomic_json, sha256
from scripts.archive_campaign_attempt import collect

ROOT = Path(__file__).resolve().parents[1]
ATTEMPT = "campaign_n02000_s005_r01"


def finished_fixture(root):
    root = Path(root)
    run = root / "runs" / "fixture"
    run.mkdir(parents=True)
    result = {"status":"NO_VERIFIED_INCUMBENT", "verified_incumbent":None,
        "preflight":{"pilot_id":ATTEMPT,"commit":"fixture-only",
            "config":{"network":"C3E4N02000D2","scenario":"005","input_sha256":"fixture-only"}},
        "quality_target":{"sixth_best_score":100.0,"relative_shortfall_limit":0.10},
        "pipeline_completed":False, "peak_sampled_process_tree_rss_bytes":1000,
        "worker_error":{"error":"Synthetic test timeout"}}
    atomic_json(run/"result.json",result)
    atomic_json(run/"completion.json",{"result_sha256":sha256(run/"result.json"),
        "within_local_deadline":True,"elapsed_through_result_serialization_seconds":12.0})
    atomic_json(root/"runs"/(ATTEMPT+"_latch.json"),
                {"run":str(run),"pilot_id":ATTEMPT,"commit":"fixture-only"})
    return run


class CampaignArchiveTests(unittest.TestCase):
    def test_failed_attempt_is_preserved_without_fabricated_score(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root = Path(d)
            run = finished_fixture(root)
            original = (run/"result.json").read_bytes()
            report = collect(ATTEMPT,root=root)
            self.assertFalse(report["quality_gate"]["pass"])
            self.assertIsNone(report["objective"])
            self.assertIsNone(report["quality_gate"]["score"])
            self.assertIsNone(report["completed_network_registration"])
            self.assertEqual(original,(run/"result.json").read_bytes())
            manifest = json.loads((root/"evidence/campaign"/ATTEMPT/"retained_manifest.json").read_text())
            self.assertEqual(manifest["files_deleted"],0)
            with self.assertRaises(FileExistsError):
                collect(ATTEMPT,root=root)

    def test_incomplete_attempt_cannot_be_archived_as_finished(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root = Path(d)
            run = finished_fixture(root)
            # Only delete this explicit, task-created fixture marker.
            (run/"completion.json").unlink()
            with self.assertRaises(FileNotFoundError):
                collect(ATTEMPT,root=root)

    def test_changed_result_cannot_be_archived(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root = Path(d)
            run = finished_fixture(root)
            atomic_json(run/"result.json",{"changed":True})
            with self.assertRaisesRegex(ValueError,"hash mismatch"):
                collect(ATTEMPT,root=root)


if __name__ == "__main__":
    unittest.main()
