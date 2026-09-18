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
    stage("consumer_dominance_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_consumer_dominance.jl"])
    stage("reserve_ac_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_reserve_ac.jl"])
    stage("source_feature_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_source_features.jl"])
    stage("ac_primal_start_tests",[str(JULIA),"--startup-file=no","--project=.",
        "scripts/test_ac_primal_start.jl"])
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
    feature_stats=json.loads((evidence/"source_features_worker/statistics/scheduling.json").read_text())
    source_ac_stats=json.loads((evidence/"source_features_worker/solver_statistics.json").read_text())["ac_intervals"]
    for interval in source_ac_stats:
        reserve=interval["reserve_ac"]
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
                    reserve_ac_certificate,source_features_certificate):
        if (not checked["pass"] or not checked["complete"] or checked["official_phys_feas"]!=1 or
                checked["contingencies_completed"]!=9 or checked["contingencies_required"]!=9):
            raise RuntimeError("A complete tiny pipeline failed physical/exhaustive verification")
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
                     "ac_primal_start_tests"))
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
        "tiny_source_features_scheduling":feature_stats,
        "tiny_source_features_ac_statistics":source_ac_stats,
        "tiny_reserve_aware_statistics":ac_intervals,"source_sha256":source_hashes()}
    atomic_json(ROOT/"manifests/component_tests.json",result)


if __name__=="__main__":
    main()
