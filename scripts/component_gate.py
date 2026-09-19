"""Repeatable tiny-fixture setup/test gate. Never loads a competition case."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import re

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/"scripts"))
from go3cpu.controller import atomic_json, sha256
from go3cpu.provenance import source_hashes as complete_source_hashes
from go3cpu.campaign import pipeline_coverage
from run_pilot import JULIA, runtime_environment, runtime_identity


def source_hashes():
    return complete_source_hashes(ROOT)


def main():
    env=runtime_environment()
    evidence=Path(tempfile.mkdtemp(prefix="pilot002_component_gate_",dir=ROOT/"tmp"))
    print("COMPONENT_EVIDENCE "+str(evidence),flush=True)
    stages=[]
    def stage(name,command,timeout=120):
        started=time.perf_counter()
        with (evidence/(name+".log")).open("w",encoding="utf-8") as log:
            p=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=timeout,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
        entry={"name":name,"returncode":p.returncode,"seconds":time.perf_counter()-started,
            "log_sha256":sha256(evidence/(name+".log"))}
        stages.append(entry); print(json.dumps(entry),flush=True)
        if p.returncode:
            raise RuntimeError(f"Tiny component gate failed: {name}; no pilot allowed")
    stage("official_fixture",[sys.executable,"scripts/test_official_adapter.py"])
    stage("python_tests",[sys.executable,"-m","unittest","discover","-s","tests","-v"])
    stage("julia_tests",[str(JULIA),"--startup-file=no","--project=.","scripts/test_solver.jl"])
    stage("scheduling_seed_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_scheduling_seed.jl"])
    stage("consumer_dominance_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_consumer_dominance.jl"])
    stage("reserve_ac_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_ac.jl"])
    stage("source_feature_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_source_features.jl"])
    stage("ac_primal_start_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_primal_start.jl"])
    stage("ac_interval_start_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_interval_start.jl"])
    stage("ac_primal_guard_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_primal_guard.jl"])
    stage("ac_correction_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_correction.jl"])
    stage("ac_recovery_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_recovery.jl",str(evidence/"recovery_fixture")])
    stage("tiny_recovery_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dominance_problem.json",
        "--solution",str(evidence/"recovery_fixture/candidate_final.json"),
        "--output",str(evidence/"recovery_verification"),"--seconds","60"])
    recovery_certificate=json.loads((evidence/"recovery_verification/certificate.json").read_text())
    stage("tiny_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/problem.json",str(evidence/"worker"),"config/tiny_test.json",str(time.time()+120)],timeout=125)
    stage("tiny_final_check",[sys.executable,"scripts/verify_candidate.py","--input","tmp/official_tiny/problem.json",
        "--solution",str(evidence/"worker/candidate_final.json"),"--output",str(evidence/"verification"),"--seconds","60"])
    certificate=json.loads((evidence/"verification/certificate.json").read_text())
    stage("tiny_separated_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/problem.json",str(evidence/"separated_worker"),
        "config/tiny_separated_reserves.json",str(time.time()+120)],timeout=125)
    stage("tiny_separated_check",[sys.executable,"scripts/verify_candidate.py","--input","tmp/official_tiny/problem.json",
        "--solution",str(evidence/"separated_worker/candidate_final.json"),
        "--output",str(evidence/"separated_verification"),"--seconds","60"])
    separated_certificate=json.loads((evidence/"separated_verification/certificate.json").read_text())
    stage("tiny_hipo_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/problem.json",str(evidence/"hipo_worker"),
        "config/tiny_hipo.json",str(time.time()+120)],timeout=125)
    stage("tiny_hipo_check",[sys.executable,"scripts/verify_candidate.py","--input","tmp/official_tiny/problem.json",
        "--solution",str(evidence/"hipo_worker/candidate_final.json"),
        "--output",str(evidence/"hipo_verification"),"--seconds","60"])
    hipo_certificate=json.loads((evidence/"hipo_verification/certificate.json").read_text())
    stage("tiny_dominance_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dominance_problem.json",str(evidence/"dominance_worker"),
        "config/tiny_consumer_dominance.json",str(time.time()+120)],timeout=125)
    stage("tiny_dominance_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dominance_problem.json",
        "--solution",str(evidence/"dominance_worker/candidate_final.json"),
        "--output",str(evidence/"dominance_verification"),"--seconds","60"])
    dominance_certificate=json.loads((evidence/"dominance_verification/certificate.json").read_text())
    dominance_stats=json.loads((evidence/"dominance_worker/statistics/scheduling.json").read_text())
    dominance_audit=dominance_stats.get("consumer_online_dominance",{})
    if (dominance_audit.get("eligible_consumer_uids") != ["d"] or
        dominance_audit.get("fixed_online_variables") != 3 or
        dominance_audit.get("generator_commitments_changed") != 0 or
        dominance_audit.get("source_values_changed") is not False):
        raise RuntimeError("Tiny integration did not exercise exactly the eligible consumer reduction")
    stage("tiny_reserve_ac_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dominance_problem.json",str(evidence/"reserve_ac_worker"),
        "config/tiny_reserve_aware.json",str(time.time()+120)],timeout=125)
    stage("tiny_reserve_ac_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dominance_problem.json",
        "--solution",str(evidence/"reserve_ac_worker/candidate_final.json"),
        "--output",str(evidence/"reserve_ac_verification"),"--seconds","60"])
    reserve_ac_certificate=json.loads((evidence/"reserve_ac_verification/certificate.json").read_text())
    reserve_ac_stats=json.loads((evidence/"reserve_ac_worker/solver_statistics.json").read_text())
    stage("tiny_source_features_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"source_features_worker"),
        "config/tiny_source_features.json",str(time.time()+120)],timeout=125)
    stage("tiny_source_features_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"source_features_worker/candidate_final.json"),
        "--output",str(evidence/"source_features_verification"),"--seconds","60"])
    source_features_certificate=json.loads((evidence/"source_features_verification/certificate.json").read_text())
    stage("tiny_cold_seed_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"cold_seed_worker"),
        "config/tiny_cold_scheduling_seed.json",str(time.time()+120)],timeout=125)
    stage("tiny_cold_seed_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"cold_seed_worker/candidate_final.json"),
        "--output",str(evidence/"cold_seed_verification"),"--seconds","60"])
    cold_seed_certificate=json.loads((evidence/"cold_seed_verification/certificate.json").read_text())
    stage("tiny_correction_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"correction_worker"),
        "config/tiny_ac_correction.json",str(time.time()+120)],timeout=125)
    stage("tiny_correction_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"correction_worker/candidate_final.json"),
        "--output",str(evidence/"correction_verification"),"--seconds","60"])
    correction_certificate=json.loads((evidence/"correction_verification/certificate.json").read_text())
    correction_stats=json.loads((evidence/"correction_worker/solver_statistics.json").read_text())
    stage("tiny_continuous_correction_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"continuous_correction_worker"),
        "config/tiny_ac_correction_continuous.json",str(time.time()+120)],timeout=125)
    stage("tiny_continuous_correction_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"continuous_correction_worker/candidate_final.json"),
        "--output",str(evidence/"continuous_correction_verification"),"--seconds","60"])
    continuous_correction_certificate=json.loads((evidence/"continuous_correction_verification/certificate.json").read_text())
    continuous_correction_stats=json.loads((evidence/"continuous_correction_worker/solver_statistics.json").read_text())
    continuous_native=list((evidence/"continuous_correction_worker/native_correction").rglob("*.json"))
    if not continuous_native:
        raise RuntimeError("Missing native IPX correction records")
    for path in continuous_native:
        native=json.loads(path.read_text())
        if (native["native_solver_requested"]!="ipx" or native["crossover_requested"]!="off"
            or native["native_stored_start"] or native["native_useful_basis_bypassed_presolve"]
            or not native["import_audit"]["pass"]
            or not Path(native["native_log_file"]).is_relative_to(evidence/"continuous_correction_worker")
            or ("original_linearization_residual" in native and native["original_linearization_residual"]>1e-8)):
            raise RuntimeError("Continuous correction native solver/import/residual audit failed")
    for interval in continuous_correction_stats["ac_intervals"]:
        correction=interval["reserve_ac"]["correction"]
        phases=interval["reserve_ac"]["phases"]
        if (correction["policy"]!="network_slp_continuous_then_round_v2"
            or correction["lp_solver"]!="ipx" or correction["final_model_residual"]>1e-8
            or correction["internal_primal_target"]!=1e-10
            or correction["final_acceptance_tolerance"]!=1e-8
            or any(x!=round(x) for x in correction["final_discrete_settings"].values())
            or not any(p["phase"]=="continuous_shunt_correction" for p in phases)
            or not any(p["phase"]=="rounded_shunt_correction" for p in phases)):
            raise RuntimeError("Continuous candidate was not rounded and independently repaired")
    native_records=list((evidence/"correction_worker/native_correction").rglob("*.json"))
    if not native_records:
        raise RuntimeError("Missing retained native correction import/start audit")
    for path in native_records:
        native=json.loads(path.read_text())
        if (not Path(native["native_log_file"]).is_file()
            or not Path(native["native_log_file"]).is_relative_to(evidence/"correction_worker")
            or not native["import_audit"]["domains_exact"]
            or not native["import_audit"]["objective_exact"]
            or native["native_stored_start"] or native["complete_start_api_status"] is not None
            or native["native_useful_basis_bypassed_presolve"]
            or (native["native_optimizations"] and not native["import_audit"]["pass"])):
            raise RuntimeError("Native correction import/log retention gate failed")
    if any(s["termination"]!="HEURISTIC_CORRECTION_POINT"
           or s["reserve_ac"]["correction"]["final_model_residual"]>1e-8
           or s["reserve_ac"]["correction"]["policy"]!="network_slp_fixed_shunts_v1"
           or "no supplied dual, basis, or external solution" not in s["warm_start"]
           for s in correction_stats["ac_intervals"]):
        raise RuntimeError("Tiny network correction did not preserve original-model residual acceptance")
    seed_stats=json.loads((evidence/"cold_seed_worker/statistics/scheduling.json").read_text())
    start=seed_stats["cold_construction"]["mip_start"]
    cost_phase=seed_stats["cold_construction"]["phases"][1]
    seed_checkpoints=evidence/"cold_seed_worker/scheduling_seeds"
    seed_event_files=sorted((evidence/"cold_seed_worker/statistics/scheduling_events").glob("*.json"))
    seed_events=[json.loads(path.read_text())["event"] for path in seed_event_files]
    if (not start["complete"] or start["accepted_interface_count"]!=start["variable_count"]
        or start["native_acceptance"]!="native_log_confirms_feasible_start"
        or not seed_stats["selected_schedule"]["pass"]
        or seed_stats["highs_analysis_level"]!=128
        or not (evidence/"cold_seed_worker/timing_snapshots/scheduling.json").is_file()
        or seed_stats["cold_construction"]["policy"]!="cold_online_construction_cost_lp_v2"
        or cost_phase["solver"]!="ipx" or cost_phase["run_crossover"]!="off"
        or cost_phase["bound_and_gap_queried"] or cost_phase["bound"] is not None
        or not (seed_checkpoints/"online_commitment_construction.json").is_file()
        or not (seed_checkpoints/"constructed_commitment_cost_lp.json").is_file()
        or "restore_cache_edits_complete" not in seed_events
        or "economic_solve_returned" not in seed_events):
        raise RuntimeError("Cold scheduling construction/start/timing integration failed")
    feature_stats=json.loads((evidence/"source_features_worker/statistics/scheduling.json").read_text())
    source_ac_stats=json.loads((evidence/"source_features_worker/solver_statistics.json").read_text())["ac_intervals"]
    for interval in source_ac_stats:
        reserve=interval["reserve_ac"]
        guard=reserve["primal_guard"]
        if (guard["policy"]!="verified_stable_rounded_primal_v1" or
            len(guard["phases"])!=1 or not guard["phases"][0]["enabled"] or
            guard["phases"][0]["callback_count"]<=0 or
            guard["phases"][0].get("callback_error")):
            raise RuntimeError("Tiny pipeline did not exercise the rounded-point guard")
        recovery=reserve["numerical_recovery"]
        if (recovery["policy"]!="adaptive_barrier_on_failed_residual_v1" or
            recovery["attempted"] or
            recovery["reason"]!="rounded_point_passed_local_residual_screen"):
            raise RuntimeError("A successful tiny interval incorrectly triggered numerical recovery")
        continuation=reserve["interval_primal_start"]
        if interval["interval"]==1:
            if continuation["policy"]!="cold_defaults":
                raise RuntimeError("First tiny AC interval was not cold")
        elif (continuation["policy"]!="previous_screened_interval_v1" or
            continuation["source_interval"]!=interval["interval"]-1 or
            not continuation["complete_current_primal_vector"] or
            continuation["reused_named_values"]<=0):
            raise RuntimeError("Tiny pipeline did not exercise within-run interval continuation")
        start=reserve["shunt_primal_start"]
        phases=reserve["phases"]
        if (not start["complete"] or start["variable_count"]<=0 or
            start["accepted_interface_count"]!=start["variable_count"] or
            not start.get("dual_transfer_used") or
            not start.get("dual_start",{}).get("complete_current_mapping") or
            start["dual_start"]["constraint_count"]!=start["dual_start"]["accepted_interface_count"] or
            len(phases)!=2 or not phases[-1]["complete_finite_point"] or
            phases[-1]["max_primal_residual"]>1e-8):
            raise RuntimeError("Tiny pipeline did not transfer and audit the complete same-interval primal")
    if (feature_stats["source_startup_windows"]["windows"]!=4 or
        feature_stats["source_pq_bound_devices"]!=1 or
        feature_stats["mip_lp_solver_option"]!="simplex"):
        raise RuntimeError("New tiny integration did not exercise the registered source features")
    for checked in (certificate,separated_certificate,hipo_certificate,dominance_certificate,
                    reserve_ac_certificate,source_features_certificate,recovery_certificate,cold_seed_certificate,
                    correction_certificate,continuous_correction_certificate):
        if (not checked["pass"] or not checked["complete"] or checked["official_phys_feas"]!=1 or
                checked["contingencies_completed"]!=9 or checked["contingencies_required"]!=9):
            raise RuntimeError("A complete tiny pipeline failed physical/exhaustive verification")
    coverage_records={}
    for name in ("worker","separated_worker","hipo_worker","dominance_worker",
                 "reserve_ac_worker","source_features_worker","cold_seed_worker","correction_worker",
                 "continuous_correction_worker"):
        from go3cpu.controller import latest_snapshot
        stats=json.loads((evidence/name/"solver_statistics.json").read_text())
        progress=latest_snapshot(evidence/name/"progress")
        coverage=pipeline_coverage(progress,0,stats,3)
        if (not coverage["complete"] or progress.get("all_intervals_refined") is not True or
            progress.get("intervals_finished")!=3 or progress.get("intervals_required")!=3):
            raise RuntimeError(f"Tiny worker did not certify exact full-hour coverage: {name}")
        coverage_records[name]=coverage
    ac_intervals=reserve_ac_stats["ac_intervals"]
    if len(ac_intervals)!=3 or any(
        s.get("reserve_policy")!="source_joint_reserves_in_ac_v1" or
        s.get("reserve_ac",{}).get("original_bounds") is not True or
        s.get("reserve_ac",{}).get("physical_balance_policy")!="zero_slack_candidate_restriction" or
        s.get("reserve_ac",{}).get("products")!=10 for s in ac_intervals):
        raise RuntimeError("Tiny AC integration did not exercise original-bound ten-product reserves")
    python_count=int(re.search(r"Ran (\d+) tests",(evidence/"python_tests.log").read_text()).group(1))
    julia_logs="\n".join((evidence/(name+".log")).read_text()
        for name in ("julia_tests","consumer_dominance_tests","reserve_ac_tests","source_feature_tests",
                     "ac_primal_start_tests","ac_interval_start_tests","ac_recovery_tests",
                     "ac_primal_guard_tests","scheduling_seed_tests","ac_correction_tests"))
    julia_counts=re.findall(r"^GO3[^\n]*\|\s+(\d+)\s+(\d+)\s+",julia_logs,re.MULTILINE)
    if not julia_counts or any(a!=b for a,b in julia_counts):
        raise RuntimeError("Julia test summaries missing or not all passed")
    result={"pass":True,"scope":"Original synthetic 2-bus 3-interval fixture only; no competition-case solve",
        "runtime":runtime_identity(),
        "python_test_count":python_count,"julia_test_count":sum(int(a) for a,b in julia_counts),"stages":stages,
        "evidence_directory":str(evidence),
        "tiny_integration_certificate":certificate,
        "tiny_separated_reserves_certificate":separated_certificate,
        "tiny_hipo_certificate":hipo_certificate,
        "tiny_consumer_dominance_certificate":dominance_certificate,
        "tiny_consumer_dominance_audit":dominance_audit,
        "tiny_reserve_aware_certificate":reserve_ac_certificate,
        "tiny_source_features_certificate":source_features_certificate,
        "tiny_forced_recovery_certificate":recovery_certificate,
        "tiny_cold_seed_certificate":cold_seed_certificate,
        "tiny_cold_seed_scheduling":seed_stats,
        "tiny_network_correction_certificate":correction_certificate,
        "tiny_network_correction_statistics":correction_stats,
        "tiny_continuous_correction_certificate":continuous_correction_certificate,
        "tiny_continuous_correction_statistics":continuous_correction_stats,
        "tiny_worker_exact_interval_coverage":coverage_records,
        "tiny_source_features_scheduling":feature_stats,
        "tiny_source_features_ac_statistics":source_ac_stats,
        "tiny_reserve_aware_statistics":ac_intervals,"source_sha256":source_hashes()}
    atomic_json(ROOT/"manifests/component_tests.json",result)


if __name__=="__main__":
    main()
