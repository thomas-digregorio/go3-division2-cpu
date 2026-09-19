"""Archive completed campaign evidence without a solve, reevaluation or deletion."""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from go3cpu.campaign import quality_gate
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import local_path


def read(path):
    return json.loads(local_path(path).read_text(encoding="utf-8"))


def collect(attempt, *, root=ROOT):
    root = local_path(root)
    if not re.fullmatch(r"(?:campaign|speedup)_n\d{5}_s\d{3}_r\d{2}", attempt):
        raise ValueError("Invalid campaign attempt")
    latch = read(root / "runs" / (attempt + "_latch.json"))
    run = local_path(latch["run"])
    if run.parent != root / "runs" or latch["pilot_id"] != attempt:
        raise ValueError("Run is outside the exact registered campaign scope")
    result, completion = read(run / "result.json"), read(run / "completion.json")
    if sha256(run / "result.json") != completion["result_sha256"]:
        raise ValueError("Completed result hash mismatch")
    if result["preflight"]["pilot_id"] != attempt or result["preflight"]["commit"] != latch["commit"]:
        raise ValueError("Run identity mismatch")
    certificate = result.get("verified_incumbent")
    if certificate:
        retained = local_path(certificate["retained_solution"])
        if not retained.is_relative_to(run / "verified_incumbent"):
            raise ValueError("Retained solution is outside this run")
        if sha256(retained) != certificate["candidate_sha256"]:
            raise ValueError("Retained solution changed after verification")
        verification_dir = local_path(certificate["verification_directory"])
        if not verification_dir.is_relative_to(run / "verification"):
            raise ValueError("Verification is outside this run")
        checked = read(verification_dir / "certificate.json")
        if any(checked[k] != certificate[k] for k in checked):
            raise ValueError("Retained and original verification records disagree")
    gate = quality_gate(certificate, result["quality_target"],
                        pipeline_completed=result["pipeline_completed"],
                        within_deadline=completion["within_local_deadline"])
    collection = "speedup" if attempt.startswith("speedup_") else "campaign"
    output = local_path(root / "evidence" / collection / attempt)
    output.mkdir(parents=True, exist_ok=False)
    copied = []
    compact_files=("result.json", "completion.json", "preflight.json", "initial_record.json",
            "agent_stop_reason.json",
            "resource_stop.json",
            "worker/solver_statistics.json", "worker/worker_error.json", "worker/schedule_balance.json",
            "runtime_case_manifest.json", "worker/native_result.json", "worker/native_exit.json",
            "worker/scheduling_builder.json", "worker/native_memory.jsonl",
            "worker/compaction_exit.json", "worker/compaction_memory.jsonl",
            "worker/compact_spool/manifest.json", "worker/compact_spool/proof_verification.json",
            "worker/original_scheduling_audit.json",
            "worker/native_console.log", "worker/statistics/scheduling_economic_native.log",
            "worker/scheduling_spool/manifest.json", "worker/scheduling_spool/builder_exit.json",
            "worker/statistics/scheduling.json", "worker/timings.json",
            "verification/schedule/certificate.json", "verification/final/certificate.json")
    compact_files += tuple(str(p.relative_to(run)) for p in
        sorted((run/"worker/native_correction").rglob("*.json")))
    for relative in compact_files:
        source = run / relative
        if source.exists():
            destination = output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            if sha256(source) != sha256(destination):
                raise ValueError("Evidence copy verification failed")
            copied.append(relative)
    config = result["preflight"]["config"]
    summary = {
        "operation": "Post-run hash audit only; no solve or reevaluation",
        "network": config["network"], "scenario": config["scenario"], "attempt": attempt,
        "implementation_commit": result["preflight"]["commit"],
        "input_sha256": config["input_sha256"], "status": result["status"],
        "quality_gate": gate,
        "objective": certificate.get("objective") if certificate else None,
        "end_to_end_seconds": completion["elapsed_through_result_serialization_seconds"],
        "peak_sampled_process_tree_rss_gib": result["peak_sampled_process_tree_rss_bytes"] / 2**30,
        "solver_statistics": result.get("solver_statistics"), "timings": result.get("timings"),
        "worker_error": result.get("worker_error"), "controller_error": result.get("controller_error"),
        "final_certificate": certificate,
        "completed_network_registration": {
            "result_path": str((output/"result.json").relative_to(root)).replace("\\", "/"),
            "completion_path": str((output/"completion.json").relative_to(root)).replace("\\", "/"),
            "result_sha256": sha256(output/"result.json"),
            "completion_sha256": sha256(output/"completion.json"),
        } if gate["pass"] else None,
    }
    files = {str(p.relative_to(run)).replace("\\", "/"):
             {"bytes":p.stat().st_size, "sha256":sha256(p)}
             for p in sorted(run.rglob("*")) if p.is_file()}
    manifest = {"retained_run":str(run), "full_solutions_preserved":True, "files_deleted":0,
                "source_files":files, "retained_bytes":sum(f["bytes"] for f in files.values()),
                "compact_files_copied":copied}
    atomic_json(output/"summary.json",summary,exclusive=True)
    atomic_json(output/"retained_manifest.json",manifest,exclusive=True)
    return summary


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--attempt", required=True)
    args = p.parse_args()
    print(json.dumps(collect(args.attempt), indent=2))
