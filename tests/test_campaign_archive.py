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
            atomic_json(run/"agent_stop_reason.json",{"reason":"Synthetic scoped early stop"})
            original = (run/"result.json").read_bytes()
            report = collect(ATTEMPT,root=root)
            self.assertFalse(report["quality_gate"]["pass"])
            self.assertIsNone(report["objective"])
            self.assertIsNone(report["quality_gate"]["score"])
            self.assertIsNone(report["completed_network_registration"])
            self.assertEqual(original,(run/"result.json").read_bytes())
            manifest = json.loads((root/"evidence/campaign"/ATTEMPT/"retained_manifest.json").read_text())
            self.assertEqual(manifest["files_deleted"],0)
            self.assertIn("agent_stop_reason.json",manifest["compact_files_copied"])
            self.assertEqual((run/"agent_stop_reason.json").read_bytes(),
                (root/"evidence/campaign"/ATTEMPT/"agent_stop_reason.json").read_bytes())
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

    def test_interrupted_benders_stage_evidence_is_copied_without_binary_spools(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d);run=finished_fixture(root)
            stage=run/"worker/reserve_decomposition/rounds/round_0001/master"
            stage.mkdir(parents=True)
            atomic_json(stage/"request.json",{"mode":"master","round":1})
            (stage/"master.log").write_text("MIP setup started\n",encoding="utf-8")
            (stage/"memory.jsonl").write_text('{"rss_bytes":123}\n',encoding="utf-8")
            (stage/"matrix.bin").write_bytes(b"fixture binary retained locally")
            atomic_json(run/"worker/reserve_partition_exit.json",{"returncode":0})
            collect(ATTEMPT,root=root)
            output=root/"evidence/campaign"/ATTEMPT
            manifest=json.loads((output/"retained_manifest.json").read_text())
            for path in (stage/"request.json",stage/"master.log",stage/"memory.jsonl",
                         run/"worker/reserve_partition_exit.json"):
                self.assertEqual(path.read_bytes(),(output/path.relative_to(run)).read_bytes())
            self.assertFalse((output/(stage/"matrix.bin").relative_to(run)).exists())
            self.assertEqual((stage/"matrix.bin").read_bytes(),b"fixture binary retained locally")
            self.assertIn((stage/"matrix.bin").relative_to(run).as_posix(),manifest["source_files"])
            self.assertEqual(manifest["files_deleted"],0)

    def test_changed_result_cannot_be_archived(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root = Path(d)
            run = finished_fixture(root)
            atomic_json(run/"result.json",{"changed":True})
            with self.assertRaisesRegex(ValueError,"hash mismatch"):
                collect(ATTEMPT,root=root)

    def test_failed_ac_and_cancelled_verification_evidence_is_retained(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            root=Path(d);run=finished_fixture(root)
            atomic_json(run/"worker/statistics/ac_0001.json",
                {"interval":1,"termination":"TIME_LIMIT","max_primal_residual":1e-4})
            atomic_json(run/"worker/statistics/export_projection_0001.json",
                {"full_horizon_claimed":False})
            (run/"worker/console.log").write_bytes(b"GO3_AC_PHASE rejected\r\n")
            atomic_json(run/"verification_records/final.json",
                {"certificate":{"pass":False,"complete":False},"retained":False})
            atomic_json(run/"agent_stop_reason.json",
                {"classification":"POST_FAILURE_VERIFICATION_CANCELLED","solver_interrupted":False})
            report=collect(ATTEMPT,root=root)
            output=root/"evidence/campaign"/ATTEMPT
            for relative in ("worker/statistics/ac_0001.json",
                    "worker/statistics/export_projection_0001.json","worker/console.log",
                    "verification_records/final.json","agent_stop_reason.json"):
                self.assertEqual((run/relative).read_bytes(),(output/relative).read_bytes())
            self.assertIsNone(report["objective"])
            self.assertFalse(report["quality_gate"]["pass"])
            self.assertFalse((output/"verification/final/certificate.json").exists())
            self.assertFalse((run/"verification/final/certificate.json").exists())
            self.assertEqual(json.loads((output/"retained_manifest.json").read_text())["files_deleted"],0)


if __name__ == "__main__":
    unittest.main()
