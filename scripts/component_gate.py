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


def dc_pipeline_audit(evidence, worker="dc_worker", verification="dc_verification"):
    """Prove the small integration actually optimized and exported the link."""
    solution=json.loads((evidence/worker/"candidate_final.json").read_text())
    rows=solution["time_series_output"]["dc_line"]
    if (len(rows)!=1 or rows[0]["uid"]!="dc0" or len(rows[0]["pdc_fr"])!=3
            or any(p<=0.05 for p in rows[0]["pdc_fr"])
            or all(abs(p-0.35)<=1e-4 for p in rows[0]["pdc_fr"])):
        raise RuntimeError("Tiny DC pipeline did not optimize and export nonzero DC flow")
    certificate=json.loads((evidence/verification/"certificate.json").read_text())
    stats=json.loads((evidence/worker/"solver_statistics.json").read_text())
    if (not certificate["pass"] or not certificate["complete"] or certificate["official_phys_feas"]!=1
            or certificate["contingencies_completed"]!=9 or certificate["contingencies_required"]!=9):
        raise RuntimeError("Tiny DC pipeline failed complete physical/exhaustive verification")
    from go3cpu.controller import latest_snapshot
    coverage=pipeline_coverage(latest_snapshot(evidence/worker/"progress"),0,stats,3)
    if not coverage["complete"]:
        raise RuntimeError("Tiny DC pipeline did not refine all three intervals")
    return {"certificate":certificate,"terminal_flows":rows[0],"coverage":coverage}


def bounded_reserve_pipeline_audit(evidence, worker="bounded_reserve_worker"):
    stats=json.loads((evidence/worker/"solver_statistics.json").read_text())
    audits={k:stats[k] for k in ("initial_reserve_storage","final_reserve_storage")}
    for audit in audits.values():
        if (audit["policy"]!="bounded_lifetime_v1" or audit["upstream_horizon_wrapper"]
                or not audit["upstream_interval_model_unchanged"] or not audit["upstream_projection_unchanged"]
                or audit["source_values_changed"] or audit["rows_or_columns_eliminated"]!=0
                or audit["intervals_completed"]!=3 or audit["intervals_required"]!=3
                or audit["maximum_live_interval_models"]!=1 or not audit["all_models_released"]
                or [r["interval"] for r in audit["intervals"]]!=[1,2,3]
                or any(not r["model_released"] or not r["accepted"]
                       or not r["has_feasible_primal"] or r["result_count"]<1
                       or not r["extraction_attempted"] or not r["projection_completed"]
                       or r["maximum_model_residual"]>1e-8 or r["failure_reason"] is not None
                       for r in audit["intervals"])):
            raise RuntimeError("Tiny reserve pipeline failed the bounded, source-identical lifetime contract")
    return audits


def symbolic_ac_pipeline_audit(evidence, worker="symbolic_ac_worker", verification="symbolic_ac_verification"):
    verified=dc_pipeline_audit(evidence,worker,verification)
    stats=json.loads((evidence/worker/"solver_statistics.json").read_text())
    for interval in stats["ac_intervals"]:
        info=interval["reserve_ac"]
        calls=info["numerical_calls"]
        if (len(calls)<2 or info["model_build_seconds"]<0
                or any(c["policy"]!="symbolic_adaptive_v1" or c["mu_strategy"]!="adaptive"
                    or "SymbolicMode" not in c["effective_native_backend"]
                    or "SymbolicAD.Evaluator" not in c["effective_native_evaluator"]
                    or not c["native_backend_confirmed"] or c["floating_point_bits"]!=64
                    or c["model_structure_changed"] or c["source_bounds_changed"] for c in calls)
                or any(p["residual_audit_seconds"]<0 for p in info["phases"])
                or info["phases"][-1]["max_primal_residual"]>1e-8):
            raise RuntimeError("Tiny AC numerical policy was not applied or residuals failed")
    reserves=stats["final_reserve_storage"]
    if (reserves["intervals_completed"]!=3 or not reserves["all_models_released"]
            or any(not r["accepted"] for r in reserves["intervals"])):
        raise RuntimeError("Symbolic AC pipeline omitted final source reserve optimization")
    return {"verification":verified,"statistics":stats}


def complete_initialization_pipeline_audit(evidence,worker="initialized_ac_worker",verification="initialized_ac_verification"):
    import math
    result=symbolic_ac_pipeline_audit(evidence,worker,verification)
    dual_transfers=0
    for interval in result["statistics"]["ac_intervals"]:
        info=interval["reserve_ac"]
        if info["initialization"]["policy"]!="current_schedule_preserving_restarts_v1":
            raise RuntimeError("Complete AC initialization policy was not applied")
        start=info["interval_primal_start"]
        if interval["interval"]==1:
            if (start["source"]!="current_attempt_joint_schedule" or start["optimization_calls"]!=0
                    or start["external_solution_read"] or start["feasibility_claimed"]
                    or not start["complete_current_primal_vector"] or start["source_bounds_changed"]):
                raise RuntimeError("First AC start was not complete, cold and source-preserving")
        elif start["source_interval"]!=interval["interval"]-1 or not start["complete_current_primal_vector"]:
            raise RuntimeError("Complete initialization broke within-run interval continuation")
        guards=info["primal_guard"]["phases"]
        if len(guards)!=len(info["phases"]) or not guards[0]["audit_only"] or guards[0]["stop_requested"]:
            raise RuntimeError("Continuous initialization audit altered termination")
        for guard in guards:
            native=guard["native_initialization"]
            if (not native["complete_mapping"] or native["iteration"]!=0
                    or not math.isfinite(native["maximum_absolute_change_from_requested_start"])
                    or not math.isfinite(native["maximum_relative_change_from_requested_start"])
                    or not math.isfinite(native["original_unscaled_residual"])
                    or guard["residual_screen"]!="native_original_unscaled"
                    or guard["discrete_solution_claimed"]):
                raise RuntimeError("Native initialization and original-residual audits are incomplete")
        primal=info["shunt_primal_start"]
        if primal["dual_transfer_used"]:
            if not primal["dual_start"]["complete_current_mapping"]:
                raise RuntimeError("Valid dual transfer lost its mapping")
            dual_transfers+=1
        elif primal["primal_initialization_options"]["bound_push"]!=1e-8:
            raise RuntimeError("Primal-only rounded restart lost small pushes")
    if dual_transfers==0:
        raise RuntimeError("Tiny initialization pipeline did not preserve eligible dual transfer")
    result["verified_dual_transfers"]=dual_transfers
    return result


def zero_reserve_pipeline_audit(evidence):
    import math
    result=complete_initialization_pipeline_audit(evidence,"zero_reserve_worker","zero_reserve_verification")
    for interval in result["statistics"]["ac_intervals"]:
        info=interval["reserve_ac"]
        record=info["zero_reserve_domains"]
        if (record["policy"]!="exact_zero_reserve_domains_v1" or not record["enabled"]
                or not record["proof_replayed"] or record["proof_tolerance"]!=0.0
                or record["source_feasible_set_changed"] or record["source_parameters_changed"]
                or record["dispatch_or_PMIN_modified"] or record["objective_changed"]
                or record["floating_point_bits"]!=64 or record["variables_deleted"]!=0
                or record["implied_zero_variables"]<=0 or record["constant_satisfied_rows_removed"]<=0
                or record["original_row_audits"]<len(info["phases"])
                or not math.isfinite(record["last_original_row_maximum_residual"])
                or record["last_original_row_maximum_residual"]>1e-8
                or any(not call["pre_solve_exact_zero_reduction"] or call["source_feasible_set_changed"]
                       for call in info["numerical_calls"])):
            raise RuntimeError("Exact reserve-domain pipeline lost a source-equivalence or original-row audit gate")
    return result


def main():
    tested_sources=source_hashes()
    env=runtime_environment()
    evidence=Path(tempfile.mkdtemp(prefix="pilot002_component_gate_",dir=ROOT/"tmp"))
    print("COMPONENT_EVIDENCE "+str(evidence),flush=True)
    stages=[]
    def stage(name,command,timeout=120,stage_env=None):
        started=time.perf_counter()
        with (evidence/(name+".log")).open("w",encoding="utf-8") as log:
            p=subprocess.run(command,cwd=ROOT,env=env if stage_env is None else stage_env,stdout=log,stderr=subprocess.STDOUT,timeout=timeout,
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
    stage("scheduling_storage_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_scheduling_storage.jl"])
    stage("scheduling_spool_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_scheduling_spool.jl"],timeout=180)
    stage("isolated_scheduling_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_isolated_scheduling.jl"],timeout=120)
    stage("scheduling_compaction_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_scheduling_compaction.jl"],timeout=180)
    stage("reserve_benders_certificate_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_certificate.jl"],timeout=120)
    stage("reserve_benders_partition_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_partition.jl"],timeout=180)
    stage("reserve_benders_runtime_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_runtime.jl"],timeout=120)
    stage("cold_benders_primal_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_primal.jl"],timeout=120)
    from go3cpu.native_highs import native_environment
    guard_config=json.loads((ROOT/"config/tiny_reserve_benders_native_guard.json").read_text())
    guard_env=native_environment(guard_config,root=ROOT,base_environment=env)
    stage("native_highs_guard_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_native_highs_guard.jl"],timeout=120,stage_env=guard_env)
    stage("guarded_reserve_benders_runtime_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_runtime.jl"],timeout=120,stage_env=guard_env)
    root_memory_config=json.loads((ROOT/"config/tiny_reserve_benders_root_memory.json").read_text())
    root_memory_env=native_environment(root_memory_config,root=ROOT,base_environment=env)
    stage("native_root_memory_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_native_root_memory_guard.jl"],timeout=120,stage_env=root_memory_env)
    stage("root_memory_reserve_benders_runtime_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_runtime.jl"],timeout=120,stage_env=root_memory_env)
    root_progress_config=json.loads((ROOT/"config/tiny_reserve_benders_root_progress.json").read_text())
    root_progress_env=native_environment(root_progress_config,root=ROOT,base_environment=env)
    stage("native_root_progress_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_native_root_memory_guard.jl","--root-progress"],timeout=120,stage_env=root_progress_env)
    stage("root_progress_reserve_benders_runtime_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_benders_runtime.jl"],timeout=120,stage_env=root_progress_env)
    stage("consumer_dominance_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_consumer_dominance.jl"])
    stage("reserve_ac_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_ac.jl"])
    stage("source_feature_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_source_features.jl"])
    stage("dc_device_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_dc_devices.jl"])
    stage("reserve_storage_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_storage.jl"])
    stage("ac_primal_start_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_primal_start.jl"])
    stage("ac_interval_start_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_interval_start.jl"])
    stage("ac_numerics_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_numerics.jl"],timeout=180)
    stage("ac_initialization_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_initialization.jl"],timeout=180)
    stage("ac_zero_reserve_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_zero_reserves.jl"],timeout=180)
    stage("ac_ramp_bound_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_ramp_bounds.jl"])
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
    stage("tiny_native_scheduling_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"native_scheduling_worker"),
        "config/tiny_scheduling_native.json",str(time.time()+120)],timeout=125)
    stage("tiny_native_scheduling_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"native_scheduling_worker/candidate_final.json"),
        "--output",str(evidence/"native_scheduling_verification"),"--seconds","60"])
    native_scheduling_certificate=json.loads((evidence/"native_scheduling_verification/certificate.json").read_text())
    native_scheduling_stats=json.loads((evidence/"native_scheduling_worker/statistics/scheduling.json").read_text())
    native_storage=native_scheduling_stats["storage"]
    if (native_storage["policy"]!="native_handoff_v1" or not native_storage["whole_model_copy"]
            or not native_storage["cached_model_emptied"] or native_storage["native_mode"]!="DIRECT"
            or native_storage["rows_or_columns_eliminated"]!=0 or native_storage["source_values_changed"]
            or native_scheduling_stats["mip_lp_solver_option"]!="simplex"):
        raise RuntimeError("Native scheduling integration did not preserve its storage-only contract")
    stage("tiny_exact_ramp_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"exact_ramp_worker"),
        "config/tiny_ac_exact_ramp.json",str(time.time()+120)],timeout=125)
    stage("tiny_exact_ramp_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"exact_ramp_worker/candidate_final.json"),
        "--output",str(evidence/"exact_ramp_verification"),"--seconds","60"])
    exact_ramp_certificate=json.loads((evidence/"exact_ramp_verification/certificate.json").read_text())
    exact_ramp_stats=json.loads((evidence/"exact_ramp_worker/solver_statistics.json").read_text())
    ramp_policy=exact_ramp_stats["ac_ramp_bounds"]
    if (ramp_policy["policy"]!="exact_source_intersections_v1" or ramp_policy["bookkeeping_tolerance"]!=0.0
            or ramp_policy["source_bounds_changed"] or ramp_policy["official_tolerance_changed"]):
        raise RuntimeError("Exact ramp integration did not preserve source bounds and tolerances")
    audits=[exact_ramp_stats["final_export_projection"]]
    for i in range(1,4):
        audit=json.loads((evidence/f"exact_ramp_worker/statistics/export_projection_{i:04d}.json").read_text())
        if audit["refined_intervals"]!=i:
            raise RuntimeError("Export audit did not distinguish refined and unfinished intervals")
        audits.append(audit)
    for audit in audits:
        if (audit["policy"]!="exact_source_intersections_v1" or not audit["enforced"]
                or not audit["within_guard"] or audit["bookkeeping_tolerance"]!=0.0
                or audit["maximum_refined_bus_injection_change_pu"]>1e-9
                or audit["source_bounds_changed"] or audit["official_tolerance_changed"]):
            raise RuntimeError("Exported refined dispatch exceeded the unchanged physical contract")
    stage("tiny_dc_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"dc_worker"),
        "config/tiny_ac_exact_ramp.json",str(time.time()+120)],timeout=125)
    stage("tiny_dc_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"dc_worker/candidate_final.json"),
        "--output",str(evidence/"dc_verification"),"--seconds","60"])
    dc_audit=dc_pipeline_audit(evidence)
    stage("tiny_bounded_reserve_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"bounded_reserve_worker"),
        "config/tiny_reserve_bounded.json",str(time.time()+120)],timeout=125)
    stage("tiny_bounded_reserve_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"bounded_reserve_worker/candidate_final.json"),
        "--output",str(evidence/"bounded_reserve_verification"),"--seconds","60"])
    bounded_reserve_dc=dc_pipeline_audit(evidence,"bounded_reserve_worker","bounded_reserve_verification")
    stage("tiny_reserve_handoff_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"reserve_handoff_worker"),
        "config/tiny_reserve_handoff.json",str(time.time()+120)],timeout=125)
    stage("tiny_reserve_handoff_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"reserve_handoff_worker/candidate_final.json"),
        "--output",str(evidence/"reserve_handoff_verification"),"--seconds","60"])
    handoff_dc=dc_pipeline_audit(evidence,"reserve_handoff_worker","reserve_handoff_verification")
    handoff_stats=json.loads((evidence/"reserve_handoff_worker/solver_statistics.json").read_text())
    handoff=handoff_stats["initial_reserve_storage"]
    final_reserves=handoff_stats["final_reserve_storage"]
    if (handoff["source"]!="current_attempt_joint_schedule" or handoff["optimization_calls"]!=0
            or handoff["external_solution_read"] or handoff["initial_solution_verified"]
            or not handoff["final_reserve_optimization_required"] or not handoff["full_case_checks_required"]
            or final_reserves["intervals_completed"]!=3 or not final_reserves["all_models_released"]
            or any(not r["accepted"] or r["maximum_model_residual"]>1e-8 for r in final_reserves["intervals"])):
        raise RuntimeError("Tiny reserve handoff omitted final optimization or claimed initial verification")
    stage("tiny_symbolic_ac_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"symbolic_ac_worker"),
        "config/tiny_ac_symbolic_adaptive.json",str(time.time()+180)],timeout=185)
    stage("tiny_symbolic_ac_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"symbolic_ac_worker/candidate_final.json"),
        "--output",str(evidence/"symbolic_ac_verification"),"--seconds","60"])
    symbolic_ac=symbolic_ac_pipeline_audit(evidence)
    stage("tiny_initialized_ac_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"initialized_ac_worker"),
        "config/tiny_ac_complete_initialization.json",str(time.time()+180)],timeout=185)
    stage("tiny_initialized_ac_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"initialized_ac_worker/candidate_final.json"),
        "--output",str(evidence/"initialized_ac_verification"),"--seconds","60"])
    initialized_ac=complete_initialization_pipeline_audit(evidence)
    stage("tiny_zero_reserve_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"zero_reserve_worker"),
        "config/tiny_ac_zero_reserves.json",str(time.time()+180)],timeout=185)
    stage("tiny_zero_reserve_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"zero_reserve_worker/candidate_final.json"),
        "--output",str(evidence/"zero_reserve_verification"),"--seconds","60"])
    zero_reserve_ac=zero_reserve_pipeline_audit(evidence)
    stage("tiny_batched_official_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"bounded_reserve_worker/candidate_final.json"),
        "--output",str(evidence/"batched_official_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"])
    batched_dc=dc_pipeline_audit(evidence,"bounded_reserve_worker","batched_official_verification")
    batch_audit=batched_dc["certificate"]["official_contingency_batch_audit"]
    if (not batch_audit["complete"] or batch_audit["completed_checks"]!=9
            or batch_audit["max_batch_columns"]!=2 or len(batch_audit["batches"])!=2
            or abs(batched_dc["certificate"]["objective"]-bounded_reserve_dc["certificate"]["objective"])>1e-8):
        raise RuntimeError("Batched official integration changed objective or omitted source contingencies")
    stage("tiny_trimmed_scheduling_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"trimmed_scheduling_worker"),
        "config/tiny_trimmed_scheduling.json",str(time.time()+120)],timeout=125)
    stage("tiny_trimmed_scheduling_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"trimmed_scheduling_worker/candidate_final.json"),
        "--output",str(evidence/"trimmed_scheduling_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"])
    trimmed_dc=dc_pipeline_audit(evidence,"trimmed_scheduling_worker","trimmed_scheduling_verification")
    trimmed_reserves=bounded_reserve_pipeline_audit(evidence,"trimmed_scheduling_worker")
    trimmed_stats=json.loads((evidence/"trimmed_scheduling_worker/solver_statistics.json").read_text())
    trimmed_storage=trimmed_stats["scheduling"]["storage"]
    trimmed_cleanup=trimmed_storage["pre_handoff_cleanup"]
    if (trimmed_storage["policy"]!="native_handoff_trimmed_metadata_v1"
            or not trimmed_storage["whole_model_copy"] or not trimmed_storage["cached_model_emptied"]
            or trimmed_cleanup["rows_or_columns_eliminated"]!=0 or trimmed_cleanup["source_values_changed"]
            or trimmed_cleanup["mathematical_names_changed"] or trimmed_cleanup["removed_container_entries"]<=0
            or not trimmed_dc["certificate"]["official_contingency_batch_audit"]["complete"]
            or abs(trimmed_dc["certificate"]["objective"]-bounded_reserve_dc["certificate"]["objective"])>1e-8):
        raise RuntimeError("Trimmed scheduling integration changed mathematics or failed exhaustive verification")
    bounded_reserve_audit=bounded_reserve_pipeline_audit(evidence)
    stage("tiny_disk_scheduling_worker",[sys.executable,"scripts/run_disk_worker.py",str(JULIA),
        "tmp/official_tiny/dc_problem.json",str(evidence/"disk_scheduling_worker"),
        "config/tiny_disk_scheduling.json",str(time.time()+180)],timeout=185)
    stage("tiny_disk_scheduling_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"disk_scheduling_worker/candidate_final.json"),
        "--output",str(evidence/"disk_scheduling_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"])
    disk_dc=dc_pipeline_audit(evidence,"disk_scheduling_worker","disk_scheduling_verification")
    disk_reserves=bounded_reserve_pipeline_audit(evidence,"disk_scheduling_worker")
    disk_stats=json.loads((evidence/"disk_scheduling_worker/statistics/scheduling.json").read_text())
    disk_storage=disk_stats["storage"]
    spool=evidence/"disk_scheduling_worker/scheduling_spool"
    spool_manifest=json.loads((spool/"manifest.json").read_text())
    spool_exit=json.loads((spool/"builder_exit.json").read_text())
    if (disk_storage["policy"]!="disk_backed_native_v1" or not disk_storage["whole_model_copy"]
            or not disk_storage["builder_exited_before_native_load"] or disk_storage["builder_solve_calls"]!=0
            or disk_storage["rows_or_columns_eliminated"]!=0 or disk_storage["source_values_changed"]
            or disk_storage["native_julia_per_row_metadata"] or spool_exit["returncode"]!=0
            or spool_exit["manifest_sha256"]!=sha256(spool/"manifest.json")
            or spool_manifest["builder_pid"]!=spool_exit["pid"]
            or abs(disk_dc["certificate"]["objective"]-bounded_reserve_dc["certificate"]["objective"])>1e-8):
        raise RuntimeError("Disk-backed pipeline changed mathematics or failed lifecycle/exhaustive verification")
    stage("tiny_isolated_scheduling_worker",[sys.executable,"scripts/run_disk_worker.py",str(JULIA),
        "tmp/official_tiny/dc_problem.json",str(evidence/"isolated_scheduling_worker"),
        "config/tiny_isolated_scheduling.json",str(time.time()+240)],timeout=245)
    stage("tiny_isolated_scheduling_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"isolated_scheduling_worker/candidate_final.json"),
        "--output",str(evidence/"isolated_scheduling_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"])
    isolated_dc=dc_pipeline_audit(evidence,"isolated_scheduling_worker","isolated_scheduling_verification")
    isolated_reserves=bounded_reserve_pipeline_audit(evidence,"isolated_scheduling_worker")
    isolated_dir=evidence/"isolated_scheduling_worker"
    isolated_stats=json.loads((isolated_dir/"statistics/scheduling.json").read_text())
    isolated_storage=isolated_stats["storage"]
    isolated_result=json.loads((isolated_dir/"native_result.json").read_text())
    isolated_exit=json.loads((isolated_dir/"native_exit.json").read_text())
    isolated_memory=[json.loads(line) for line in (isolated_dir/"native_memory.jsonl").read_text().splitlines()]
    if (isolated_storage["policy"]!="disk_isolated_native_v1" or not isolated_storage["whole_model_copy"]
            or not isolated_storage["native_exited_before_ac_load"] or isolated_storage["solve_calls"]!=1
            or isolated_storage["raw_case_parsed_in_native_process"]
            or isolated_storage["extraction_metadata_loaded_in_native_process"]
            or isolated_storage["rows_or_columns_eliminated"]!=0 or isolated_storage["source_values_changed"]
            or isolated_result["diagnostic_only"] or isolated_exit["returncode"]!=0
            or isolated_exit["pid"]!=isolated_result["pid"] or not isolated_exit["exited_before_ac_launch"]
            or isolated_exit["result_sha256"]!=sha256(isolated_dir/"native_result.json")
            or not isolated_memory or isolated_storage["options"]["threads"]!=1
            or isolated_storage["options"]["parallel"]!="off"
            or abs(isolated_dc["certificate"]["objective"]-bounded_reserve_dc["certificate"]["objective"])>1e-8):
        raise RuntimeError("Isolated pipeline failed exact source, process lifetime, or exhaustive verification")
    stage("tiny_compacted_scheduling_worker",[sys.executable,"scripts/run_disk_worker.py",str(JULIA),
        "tmp/official_tiny/dc_problem.json",str(evidence/"compacted_scheduling_worker"),
        "config/tiny_compacted_scheduling.json",str(time.time()+240)],timeout=245)
    stage("tiny_compacted_scheduling_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"compacted_scheduling_worker/candidate_final.json"),
        "--output",str(evidence/"compacted_scheduling_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"])
    compacted_dc=dc_pipeline_audit(evidence,"compacted_scheduling_worker","compacted_scheduling_verification")
    compacted_reserves=bounded_reserve_pipeline_audit(evidence,"compacted_scheduling_worker")
    compacted_dir=evidence/"compacted_scheduling_worker"
    compacted_stats=json.loads((compacted_dir/"statistics/scheduling.json").read_text())
    compacted_storage=compacted_stats["storage"]
    compacted_proof=json.loads((compacted_dir/"compact_spool/proof_verification.json").read_text())
    original_audit=json.loads((compacted_dir/"original_scheduling_audit.json").read_text())
    if (compacted_storage["compaction_policy"]!="exact_zero_alias_v1"
            or compacted_storage["options"].get("presolve_rule_off")!=8192
            or compacted_storage["whole_model_copy"] or compacted_storage["source_values_changed"]
            or compacted_storage["rows_or_columns_eliminated"]<=0 or not compacted_proof["pass"]
            or not original_audit["pass"] or not original_audit["objective_agreement"]
            or abs(compacted_dc["certificate"]["objective"]-bounded_reserve_dc["certificate"]["objective"])>1e-8):
        raise RuntimeError("Compacted pipeline failed equivalence, original-model residuals, or exhaustive checks")
    stage("reserve_benders_pipeline_tests",[sys.executable,"scripts/test_reserve_benders_pipeline.py",
        "--integration-only"],timeout=360)
    benders_log=(evidence/"reserve_benders_pipeline_tests.log").read_text()
    benders_match=re.search(r"^BENDERS_COMPONENT_EVIDENCE (.+)$",benders_log,re.MULTILINE)
    if benders_match is None:
        raise RuntimeError("Missing current Benders integration evidence directory")
    benders_directory=Path(benders_match.group(1).strip())
    benders_result=json.loads((benders_directory/"result.json").read_text())
    if (not benders_result["pass"] or not benders_result["complete"] or
            benders_result["evidence_directory"]!=str(benders_directory) or
            benders_result["source_hashes"]!=source_hashes() or benders_result["full_case_runs"]!=0):
        raise RuntimeError("Stale or incomplete source reserve decomposition test gate")
    stage("native_guard_benders_integration",[sys.executable,"scripts/test_reserve_benders_pipeline.py",
        "--integration-only","--native-guard"],timeout=420)
    guard_log=(evidence/"native_guard_benders_integration.log").read_text()
    guard_match=re.search(r"^BENDERS_COMPONENT_EVIDENCE (.+)$",guard_log,re.MULTILINE)
    if guard_match is None:
        raise RuntimeError("Missing current native-guard integration evidence")
    guard_directory=Path(guard_match.group(1).strip())
    guard_result=json.loads((guard_directory/"result.json").read_text())
    if (not guard_result["pass"] or not guard_result["complete"] or
            guard_result["source_hashes"]!=source_hashes() or guard_result["full_case_runs"]!=0 or
            guard_result["results"]["native_guard"]["workers_checked"]<16 or
            guard_result["results"]["source_dc_ac_pipeline"]["certificate"]["candidate_sha256"] !=
            benders_result["results"]["source_dc_ac_pipeline"]["certificate"]["candidate_sha256"]):
        raise RuntimeError("Native guard changed or did not verify the complete tiny integration")
    stage("native_root_memory_benders_integration",[sys.executable,"scripts/test_reserve_benders_pipeline.py",
        "--integration-only","--root-memory"],timeout=420)
    root_memory_log=(evidence/"native_root_memory_benders_integration.log").read_text()
    root_memory_match=re.search(r"^BENDERS_COMPONENT_EVIDENCE (.+)$",root_memory_log,re.MULTILINE)
    if root_memory_match is None:
        raise RuntimeError("Missing current root-memory integration evidence")
    root_memory_directory=Path(root_memory_match.group(1).strip())
    root_memory_result=json.loads((root_memory_directory/"result.json").read_text())
    root_certificate=root_memory_result["results"]["source_dc_ac_pipeline"]["certificate"]
    stock_certificate=benders_result["results"]["source_dc_ac_pipeline"]["certificate"]
    if (not root_memory_result["pass"] or not root_memory_result["complete"] or
            root_memory_result["source_hashes"]!=source_hashes() or root_memory_result["full_case_runs"]!=0 or
            root_memory_result["results"]["native_guard"]["workers_checked"]<16 or
            root_memory_result["results"]["native_guard"].get("analytic_center_requested") is not False or
            root_memory_result["results"]["native_guard"].get("root_presolve_only_requested") is not True or
            root_memory_result["results"]["native_guard"].get("master_options_checked",0)<8 or
            root_certificate["input_sha256"]!=stock_certificate["input_sha256"] or
            abs(root_certificate["objective"]-stock_certificate["objective"])>1e-8):
        raise RuntimeError("Root-memory guard failed the complete equivalent tiny integration")
    stage("native_root_progress_benders_integration",[sys.executable,"scripts/test_reserve_benders_pipeline.py",
        "--integration-only","--root-progress"],timeout=420)
    root_progress_log=(evidence/"native_root_progress_benders_integration.log").read_text()
    root_progress_match=re.search(r"^BENDERS_COMPONENT_EVIDENCE (.+)$",root_progress_log,re.MULTILINE)
    if root_progress_match is None:
        raise RuntimeError("Missing current root-progress integration evidence")
    root_progress_directory=Path(root_progress_match.group(1).strip())
    root_progress_result=json.loads((root_progress_directory/"result.json").read_text())
    progress_certificate=root_progress_result["results"]["source_dc_ac_pipeline"]["certificate"]
    progress_guard=root_progress_result["results"]["native_guard"]
    if (not root_progress_result["pass"] or not root_progress_result["complete"] or
            root_progress_result["evidence_directory"]!=str(root_progress_directory) or
            root_progress_result["source_hashes"]!=source_hashes() or root_progress_result["full_case_runs"]!=0 or
            progress_guard["workers_checked"]<16 or progress_guard.get("master_options_checked",0)<8 or
            progress_guard.get("analytic_center_requested") is not False or
            progress_guard.get("root_presolve_only_requested") is not True or
            progress_guard.get("root_lp_logging_requested") is not True or
            progress_certificate["input_sha256"]!=stock_certificate["input_sha256"] or
            abs(progress_certificate["objective"]-stock_certificate["objective"])>1e-8):
        raise RuntimeError("Root-progress guard failed the complete equivalent tiny integration")
    stage("cold_benders_primal_integration",[sys.executable,"scripts/test_reserve_benders_pipeline.py",
        "--integration-only","--cold-primal"],timeout=420)
    cold_log=(evidence/"cold_benders_primal_integration.log").read_text()
    cold_match=re.search(r"^BENDERS_COMPONENT_EVIDENCE (.+)$",cold_log,re.MULTILINE)
    if cold_match is None:
        raise RuntimeError("Missing current cold primal integration evidence")
    cold_directory=Path(cold_match.group(1).strip())
    cold_result=json.loads((cold_directory/"result.json").read_text())
    cold_certificate=cold_result["results"]["source_dc_ac_pipeline"]["certificate"]
    if (not cold_result["pass"] or not cold_result["complete"] or
            cold_result["evidence_directory"]!=str(cold_directory) or
            cold_result["source_hashes"]!=source_hashes() or cold_result["full_case_runs"]!=0 or
            cold_result["results"]["native_guard"]["workers_checked"]<10 or
            not cold_certificate["pass"] or not cold_certificate["complete"] or
            cold_certificate["input_sha256"]!=stock_certificate["input_sha256"] or
            cold_certificate["official_phys_feas"]!=1):
        raise RuntimeError("Cold primal failed source-checked complete tiny integration")
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
    stage("tiny_hot_repair_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/source_features_problem.json",str(evidence/"hot_repair_worker"),
        "config/tiny_ac_correction_hot_repair.json",str(time.time()+120)],timeout=125)
    stage("tiny_hot_repair_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/source_features_problem.json",
        "--solution",str(evidence/"hot_repair_worker/candidate_final.json"),
        "--output",str(evidence/"hot_repair_verification"),"--seconds","60"])
    hot_repair_certificate=json.loads((evidence/"hot_repair_verification/certificate.json").read_text())
    hot_repair_stats=json.loads((evidence/"hot_repair_worker/solver_statistics.json").read_text())
    stage("tiny_continuation_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/primal_continuation_problem.json",str(evidence/"continuation_worker"),
        "config/tiny_ac_correction_continuation.json",str(time.time()+120)],timeout=125)
    stage("tiny_continuation_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/primal_continuation_problem.json",
        "--solution",str(evidence/"continuation_worker/candidate_final.json"),
        "--output",str(evidence/"continuation_verification"),"--seconds","60"])
    continuation_certificate=json.loads((evidence/"continuation_verification/certificate.json").read_text())
    continuation_stats=json.loads((evidence/"continuation_worker/solver_statistics.json").read_text())
    stage("tiny_original_guard_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/primal_continuation_problem.json",str(evidence/"original_guard_worker"),
        "config/tiny_ac_correction_original_guard.json",str(time.time()+120)],timeout=125)
    stage("tiny_original_guard_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/primal_continuation_problem.json",
        "--solution",str(evidence/"original_guard_worker/candidate_final.json"),
        "--output",str(evidence/"original_guard_verification"),"--seconds","60"])
    original_guard_certificate=json.loads((evidence/"original_guard_verification/certificate.json").read_text())
    original_guard_stats=json.loads((evidence/"original_guard_worker/solver_statistics.json").read_text())
    stage("tiny_guarded_recovery_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/primal_continuation_problem.json",str(evidence/"guarded_recovery_worker"),
        "config/tiny_ac_correction_guarded_recovery.json",str(time.time()+120)],timeout=125)
    stage("tiny_guarded_recovery_check",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/primal_continuation_problem.json",
        "--solution",str(evidence/"guarded_recovery_worker/candidate_final.json"),
        "--output",str(evidence/"guarded_recovery_verification"),"--seconds","60"])
    guarded_recovery_certificate=json.loads((evidence/"guarded_recovery_verification/certificate.json").read_text())
    guarded_recovery_stats=json.loads((evidence/"guarded_recovery_worker/solver_statistics.json").read_text())
    guarded_probes=0
    guarded_fallbacks=0
    for interval in guarded_recovery_stats["ac_intervals"]:
        correction=interval["reserve_ac"]["correction"]
        if (correction["policy"]!="network_slp_quality_guarded_recovery_v6"
                or correction["final_model_residual"]>1e-10
                or correction["internal_primal_target"]!=1e-10
                or correction["final_acceptance_tolerance"]!=1e-8
                or not correction["final_recovery_enabled"]
                or any(x!=round(x) for x in correction["final_discrete_settings"].values())):
            raise RuntimeError("Guarded recovery changed original acceptance or discrete domains")
        quality=correction["dual_initialization_quality"]
        recoveries=[]
        for phase in interval["reserve_ac"]["phases"]:
            if phase["phase"]=="bounded_primal_only_recovery":
                recoveries.append(phase)
                if phase["attempted"] and (phase["global_deadline_reset"]
                        or phase["recovery_count"]!=1 or phase["start"]["dual_transfer_used"]
                        or phase["protected_absolute_deadline"]!=correction["protected_recovery_deadline"]):
                    raise RuntimeError("Recovery changed its bounded primal-only contract")
            if not phase.get("fallback"):
                continue
            guarded_fallbacks+=1
            guard=phase["native_primal_guard"]
            if (guard["residual_screen"]!="native_original_unscaled"
                    or guard["original_probe_interval"]!=1
                    or not guard["native_initialization"]["complete_mapping"]
                    or guard["primal_residual_limit"]!=1e-10):
                raise RuntimeError("Missing every-eligible-iteration original probe or complete native mapping")
            guarded_probes+=guard["native_original_probe_count"]
            if phase["start"]["dual_transfer_used"] and (not quality["pass"]
                    or quality["relative_stationarity"]>quality["relative_limit"]
                    or quality["dual_certificate_claimed"]):
                raise RuntimeError("Unsuitable multipliers were transferred or called a certificate")
            if guard["stop_requested"] and (guard["model_residual_at_stop"]>1e-10
                    or not guard["returned_point_passed_internal_target"]):
                raise RuntimeError("Guarded recovery bypassed its complete original-model audit")
        if len(recoveries)!=1:
            raise RuntimeError("Guarded recovery must make exactly one bounded eligibility decision per hour")
    if not guarded_fallbacks or not guarded_probes:
        raise RuntimeError("New integration did not exercise actual nonlinear fallbacks and residual probes")
    original_probes=0
    original_audits=0
    for interval in original_guard_stats["ac_intervals"]:
        correction=interval["reserve_ac"]["correction"]
        if (correction["policy"]!="network_slp_original_residual_guard_v5"
                or correction["final_model_residual"]>1e-8
                or correction["internal_primal_target"]!=1e-10
                or any(x!=round(x) for x in correction["final_discrete_settings"].values())):
            raise RuntimeError("Original-residual guard changed local/discrete acceptance")
        for phase in interval["reserve_ac"]["phases"]:
            if not phase.get("fallback"):
                continue
            guard=phase["native_primal_guard"]
            if (guard["residual_screen"]!="native_original_unscaled"
                    or not guard["native_initialization"]["complete_mapping"]
                    or guard["primal_residual_limit"]!=1e-10):
                raise RuntimeError("Missing original-residual probe policy or native initialization audit")
            original_probes+=guard["native_original_probe_count"]
            original_audits+=guard["audit_count"]
            if guard["stop_requested"] and (guard["model_residual_at_stop"]>1e-10
                    or not guard["returned_point_passed_internal_target"]):
                raise RuntimeError("Native probe incorrectly replaced complete original-model audit")
    if not original_probes or not original_audits:
        raise RuntimeError("Tiny original-residual pipeline never exercised its native/full audits")
    preserved_starts=0
    for interval in continuation_stats["ac_intervals"]:
        correction=interval["reserve_ac"]["correction"]
        if (correction["policy"]!="network_slp_preserved_primal_repair_v4"
                or correction["final_model_residual"]>1e-10
                or any(x!=round(x) for x in correction["final_discrete_settings"].values())
                or "first native Ipopt iterate audited" not in interval["warm_start"]):
            raise RuntimeError("Primal-continuation fixture failed original-model audit")
        for phase in interval["reserve_ac"]["phases"]:
            if not phase.get("fallback"):
                continue
            native=phase["native_primal_guard"].get("native_initialization",{})
            if not native.get("complete_mapping") or native.get("iteration")!=0:
                raise RuntimeError("Missing actual first-iterate native start readback")
            start=phase["start"]
            if start["primal_continuation_preserved"]:
                preserved_starts+=1
                if (interval["interval"]<=1 or start["dual_transfer_used"]
                        or start["options"]["warm_start_init_point"]!="no"
                        or start["options"]["mu_init"]!=1e-6
                        or any(start["options"][k]!=1e-8 for k in
                            ("bound_push","bound_frac","slack_bound_push","slack_bound_frac"))
                        or native["maximum_absolute_change_from_requested_start"]>1e-6):
                    raise RuntimeError("Primal continuation was reset or claimed a dual warm start")
    if not preserved_starts:
        raise RuntimeError("Time-varying fixture did not exercise a continued-hour fallback")
    used_transfers=0
    for interval in hot_repair_stats["ac_intervals"]:
        correction=interval["reserve_ac"]["correction"]
        if (correction["policy"]!="network_slp_continuous_hot_repair_v3"
            or correction["final_model_residual"]>1e-8 or correction["internal_primal_target"]!=1e-10
            or any(x!=round(x) for x in correction["final_discrete_settings"].values())
            or "no dual certificate claimed" not in interval["warm_start"]):
            raise RuntimeError("Hot repair did not preserve discrete/original-model acceptance")
        for phase in interval["reserve_ac"]["phases"]:
            if phase["phase"]=="continuous_shunt_fallback":
                guard=phase["native_primal_guard"]
                if (guard["policy"]!="verified_continuous_shunt_candidate_v1"
                    or not guard["candidate_only"] or guard["discrete_solution_claimed"]):
                    raise RuntimeError("Continuous candidate guard made an invalid discrete claim")
            if phase["phase"]=="rounded_shunt_fallback" and phase["start"]["dual_transfer_used"]:
                used_transfers+=1
                start=phase["start"]
                if (not start["dual_start"]["complete_current_mapping"]
                    or start["dual_start"]["accepted_interface_count"]!=start["dual_start"]["constraint_count"]
                    or not start["complete_primal_start"]["complete"] or start["dual_certificate_claimed"]
                    or start["options"]["warm_start_init_point"]!="yes"):
                    raise RuntimeError("Same-hour primal/dual transfer was not fully audited")
    if used_transfers==0:
        raise RuntimeError("Tiny hot-repair pipeline never exercised its registered transfer")
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
                    correction_certificate,continuous_correction_certificate,hot_repair_certificate,
                    continuation_certificate,original_guard_certificate,guarded_recovery_certificate,
                    native_scheduling_certificate,exact_ramp_certificate,dc_audit["certificate"],
                    bounded_reserve_dc["certificate"],disk_dc["certificate"],isolated_dc["certificate"],
                    compacted_dc["certificate"],handoff_dc["certificate"],
                    symbolic_ac["verification"]["certificate"],initialized_ac["verification"]["certificate"],
                    zero_reserve_ac["verification"]["certificate"]):
        if (not checked["pass"] or not checked["complete"] or checked["official_phys_feas"]!=1 or
                checked["contingencies_completed"]!=9 or checked["contingencies_required"]!=9):
            raise RuntimeError("A complete tiny pipeline failed physical/exhaustive verification")
    coverage_records={}
    for name in ("worker","separated_worker","hipo_worker","dominance_worker",
                 "reserve_ac_worker","source_features_worker","cold_seed_worker","correction_worker",
                 "continuous_correction_worker","hot_repair_worker","continuation_worker","original_guard_worker",
                 "guarded_recovery_worker","native_scheduling_worker","exact_ramp_worker","dc_worker",
                 "bounded_reserve_worker","disk_scheduling_worker","isolated_scheduling_worker","compacted_scheduling_worker",
                 "reserve_handoff_worker","symbolic_ac_worker","initialized_ac_worker","zero_reserve_worker"):
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
                     "ac_primal_start_tests","ac_interval_start_tests","ac_ramp_bound_tests","ac_recovery_tests",
                     "ac_primal_guard_tests","scheduling_seed_tests","scheduling_storage_tests","ac_correction_tests",
                     "dc_device_tests","reserve_storage_tests","scheduling_spool_tests","isolated_scheduling_tests",
                     "scheduling_compaction_tests"))
    julia_counts=re.findall(r"^GO3[^\n]*\|\s+(\d+)\s+(\d+)\s+",julia_logs,re.MULTILINE)
    if not julia_counts or any(a!=b for a,b in julia_counts):
        raise RuntimeError("Julia test summaries missing or not all passed")
    # The new decomposition tests use descriptive (non-GO3-prefixed) names.
    # Count their summaries explicitly rather than silently omitting them.
    for name,expected_sets in (("reserve_benders_certificate_tests",5),
                               ("ac_numerics_tests",2),
                               ("ac_initialization_tests",3),
                               ("ac_zero_reserve_tests",4),
                               ("reserve_benders_partition_tests",3),
                               ("reserve_benders_runtime_tests",2),
                               ("cold_benders_primal_tests",2),
                               ("native_highs_guard_tests",2),
                               ("guarded_reserve_benders_runtime_tests",2),
                               ("native_root_memory_tests",3),
                               ("root_memory_reserve_benders_runtime_tests",2),
                               ("native_root_progress_tests",4),
                               ("root_progress_reserve_benders_runtime_tests",2)):
        counts=re.findall(r"^[^\n|]+\|\s+(\d+)\s+(\d+)\s+",
                          (evidence/(name+".log")).read_text(),re.MULTILINE)
        if len(counts)!=expected_sets or any(a!=b for a,b in counts):
            raise RuntimeError(f"Missing or failing decomposition test summaries: {name}")
        julia_counts.extend(counts)
    from go3cpu.provenance import assert_tested_sources_unchanged
    assert_tested_sources_unchanged(ROOT,tested_sources)
    result={"pass":True,"scope":"Original synthetic 2-bus 3-interval fixture only; no competition-case solve",
        "complete":True,"full_case_runs":0,
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
        "tiny_native_scheduling_certificate":native_scheduling_certificate,
        "tiny_native_scheduling_statistics":native_scheduling_stats,
        "tiny_exact_ramp_certificate":exact_ramp_certificate,
        "tiny_exact_ramp_statistics":exact_ramp_stats,
        "tiny_dc_pipeline":dc_audit,
        "tiny_bounded_reserve_pipeline":bounded_reserve_dc,
        "tiny_reserve_handoff_pipeline":handoff_dc,
        "tiny_reserve_handoff_statistics":handoff_stats,
        "tiny_symbolic_ac_pipeline":symbolic_ac,
        "tiny_initialized_ac_pipeline":initialized_ac,
        "tiny_zero_reserve_pipeline":zero_reserve_ac,
        "tiny_batched_official_pipeline":batched_dc,
        "tiny_trimmed_scheduling_pipeline":trimmed_dc,
        "tiny_trimmed_scheduling_storage":trimmed_storage,
        "tiny_trimmed_scheduling_reserve_storage":trimmed_reserves,
        "tiny_disk_scheduling_pipeline":disk_dc,
        "tiny_disk_scheduling_storage":disk_storage,
        "tiny_disk_scheduling_reserve_storage":disk_reserves,
        "tiny_isolated_scheduling_pipeline":isolated_dc,
        "tiny_isolated_scheduling_storage":isolated_storage,
        "tiny_isolated_scheduling_reserve_storage":isolated_reserves,
        "tiny_compacted_scheduling_pipeline":compacted_dc,
        "tiny_compacted_scheduling_storage":compacted_storage,
        "tiny_compacted_scheduling_reserve_storage":compacted_reserves,
        "tiny_compacted_scheduling_proof":compacted_proof,
        "tiny_compacted_scheduling_original_audit":original_audit,
        "tiny_reserve_benders_integration":benders_result,
        "tiny_native_guard_benders_integration":guard_result,
        "tiny_root_memory_benders_integration":root_memory_result,
        "tiny_root_progress_benders_integration":root_progress_result,
        "tiny_cold_primal_benders_integration":cold_result,
        "tiny_bounded_reserve_storage":bounded_reserve_audit,
        "tiny_forced_recovery_certificate":recovery_certificate,
        "tiny_cold_seed_certificate":cold_seed_certificate,
        "tiny_cold_seed_scheduling":seed_stats,
        "tiny_network_correction_certificate":correction_certificate,
        "tiny_network_correction_statistics":correction_stats,
        "tiny_continuous_correction_certificate":continuous_correction_certificate,
        "tiny_continuous_correction_statistics":continuous_correction_stats,
        "tiny_hot_repair_certificate":hot_repair_certificate,
        "tiny_hot_repair_statistics":hot_repair_stats,
        "tiny_primal_continuation_certificate":continuation_certificate,
        "tiny_primal_continuation_statistics":continuation_stats,
        "tiny_original_residual_guard_certificate":original_guard_certificate,
        "tiny_original_residual_guard_statistics":original_guard_stats,
        "tiny_guarded_recovery_certificate":guarded_recovery_certificate,
        "tiny_guarded_recovery_statistics":guarded_recovery_stats,
        "tiny_worker_exact_interval_coverage":coverage_records,
        "tiny_source_features_scheduling":feature_stats,
        "tiny_source_features_ac_statistics":source_ac_stats,
        "tiny_reserve_aware_statistics":ac_intervals,"source_sha256":tested_sources}
    atomic_json(ROOT/"manifests/component_tests.json",result)


if __name__=="__main__":
    main()
