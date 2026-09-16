"""Post-run evidence collection only: no model construction, solve or evaluation.

Reads the completed replacement once, checks artifact hashes, and preserves compact
records. Full official solutions/companions remain intact in the ignored run tree.
"""
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import local_path


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    latch = read(ROOT / "runs/pilot_002_latch.json")
    run = local_path(latch["run"])
    if run.parent != ROOT / "runs":
        raise ValueError("Evidence must belong to this project's registered run")
    result, completion = read(run / "result.json"), read(run / "completion.json")
    if sha256(run / "result.json") != completion["result_sha256"]:
        raise ValueError("Completed result hash changed")
    if not result["pipeline_completed"] or not completion["within_local_deadline"]:
        raise ValueError("This collector expects the completed in-deadline replacement")
    for evaluation in result["evaluations"]:
        cert = evaluation["certificate"]
        if not cert["pass"] or not cert["complete"]:
            raise ValueError("Do not archive an incomplete/failed check as a success")
        if sha256(Path(evaluation["solution"])) != cert["candidate_sha256"]:
            raise ValueError("Evaluated solution changed")
        retained = run / "verified_incumbent" / cert["candidate_sha256"] / "solution.json"
        if sha256(retained) != cert["candidate_sha256"]:
            raise ValueError("Retained official solution changed")

    certificate = read(run / "verification/final/certificate.json")
    independent = read(run / "verification/final/independent.json")
    schedule = read(run / "verification/schedule/independent.json")
    producer = [d for d in independent["devices"] if d["device_type"] == "producer"]
    consumer = [d for d in independent["devices"] if d["device_type"] == "consumer"]
    old = {d["uid"]: d for d in schedule["devices"]}
    intervals = []
    for t in range(len(independent["interval_hours"])):
        intervals.append({"hour_one_based": t + 1,
            "producers_on": int(sum(d["on_status"][t] for d in producer)),
            "generation_mw": sum(d["p_mw"][t] for d in producer),
            "consumption_mw": sum(d["p_mw"][t] for d in consumer),
            "objective": independent["objective_by_interval"][t]})
    records = read(ROOT / "manifests/published_scenario_002.json")["records"]
    eligible = [r for r in records if r["team"] != "ARPA-e Benchmark" and r["feas"] == "1"
                and r["objective"] is not None and r["model"] == "C3E4N00617D2"
                and int(r["scenario"]) == 2 and r["SW"] == "1"]
    top_five = sorted(eligible, key=lambda r: float(r["objective"]), reverse=True)[:5]
    benchmark = next(r for r in records if r["team"] == "ARPA-e Benchmark")
    z = certificate["objective"]
    summary = {
        "operation": "Post-run aggregation/hash audit only; no new solve or reevaluation",
        "implementation_commit": result["preflight"]["commit"],
        "run_directory": str(run), "status": result["status"],
        "official_objective": z, "computed_rule_score_not_official_entry": max(z, 0.0),
        "end_to_end_seconds": completion["elapsed_through_result_serialization_seconds"],
        "peak_sampled_rss_gib": result["peak_sampled_process_tree_rss_bytes"] / 2**30,
        "final_certificate": certificate, "per_interval": intervals,
        "producer_startups": sum(sum(d["startup"]) for d in producer),
        "producer_shutdowns": sum(sum(d["shutdown"]) for d in producer),
        "commitment_changes_during_ac_refinement": sum(
            a != b for d in independent["devices"]
            for a, b in zip(d["on_status"], old[d["uid"]]["on_status"])),
        "maximum_base_overload_pu": max(v for f in independent["branch_flows"] for v in f["overload_pu"]),
        "maximum_reserve_shortfall_pu": max(v for s in independent["reserve_shortfalls"] for v in s["shortfall_pu"]),
        "ac_final_solve_iterations": sum(s["barrier_iterations"] for s in result["solver_statistics"]["ac_intervals"]),
        "ac_statuses": sorted({s["termination"] for s in result["solver_statistics"]["ac_intervals"]}),
        "independent_timing": independent["timing"],
        "top_five": top_five, "published_benchmark": benchmark,
        "percent_below_best_published_objective_not_optimality_gap":
            100 * (float(top_five[0]["objective"]) - z) / float(top_five[0]["objective"]),
        "objective_above_published_benchmark": z - float(benchmark["objective"]),
    }
    manifest = {"implementation_commit": result["preflight"]["commit"],
        "retained_run": str(run), "raw_input_sha256": certificate["input_sha256"],
        "full_solutions_preserved": True, "files_deleted": 0,
        "source_files": {str(p.relative_to(run)).replace("\\", "/"):
                         {"bytes": p.stat().st_size, "sha256": sha256(p)}
                         for p in sorted(run.rglob("*")) if p.is_file()}}
    manifest["retained_bytes"] = sum(f["bytes"] for f in manifest["source_files"].values())
    output = local_path(ROOT / "evidence/pilot_002")
    output.mkdir(exist_ok=False)
    for relative, name in (("result.json", "result.json"), ("completion.json", "completion.json"),
            ("preflight.json", "preflight.json"),
            ("verification/schedule/certificate.json", "schedule_certificate.json"),
            ("verification/final/certificate.json", "final_certificate.json"),
            ("worker/schedule_balance.json", "schedule_balance.json")):
        shutil.copyfile(run / relative, output / name)
        if sha256(output / name) != manifest["source_files"][relative]["sha256"]:
            raise ValueError("Evidence copy hash mismatch")
    atomic_json(output / "summary.json", summary, exclusive=True)
    atomic_json(output / "retained_manifest.json", manifest, exclusive=True)
    print(json.dumps({"evidence_directory": str(output), "files_hashed": len(manifest["source_files"]),
        "retained_bytes": manifest["retained_bytes"], "objective": z,
        "end_to_end_seconds": summary["end_to_end_seconds"],
        "commitment_changes_during_ac_refinement": summary["commitment_changes_during_ac_refinement"]}, indent=2))


if __name__ == "__main__":
    main()
