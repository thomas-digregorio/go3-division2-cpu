"""Tiny-only round/lifetime integration plus independent official AC checking."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/"scripts"))
from go3cpu.controller import atomic_json, sha256
from go3cpu.provenance import source_hashes
from run_pilot import JULIA, runtime_environment
from run_disk_worker import compact_stage, reserve_partition_stage


def audit_loop(output, *, minimum_rounds=1, expected=None, phase_one=False, require_gap=True):
    summary=json.loads((output/"reserve_decomposition/summary.json").read_text())
    native=json.loads((output/"native_result.json").read_text())
    rows=summary["rounds"]
    if (not summary["complete"] or len(rows)<minimum_rounds
            or not native["storage"]["original_scheduling_audit"]["pass"]
            or (require_gap and (not summary["scheduling_gap_met"] or summary["relative_gap"]>1e-6))):
        raise AssertionError("Tiny decomposition did not converge with a source-feasible incumbent")
    if expected is not None and abs(summary["objective"]-expected)>1e-8:
        raise AssertionError("Benders solution differs from analytically proved joint optimum")
    starts=[];kinds=[];pids=[]
    for row in rows:
        for name in ("master","recourse"):
            ref=row[name];path=Path(ref["path"])
            if sha256(path)!=ref["sha256"]:
                raise AssertionError("Round artifact changed")
            result=json.loads(path.read_text());exit_record=json.loads((path.parent/"exit.json").read_text())
            if (exit_record["pid"]!=result["pid"] or exit_record["returncode"]!=0
                    or not exit_record["exited_before_next_native_stage"] or exit_record["result_sha256"]!=sha256(path)):
                raise AssertionError("Missing native lifetime/exit proof")
            pids.append(result["pid"])
            if name=="master" and result["start"]["supplied"]:
                if not result["start"]["api_accepted"] or not result["start"]["original_master_audit"]["pass"]:
                    raise AssertionError("Prior-round start was not accepted/audited")
                starts.append(result["start"])
            if name=="recourse":
                if result["hours_completed"]!=result["hours_required"]:
                    raise AssertionError("Source reserve hour omitted")
                kinds.extend(h["kind"] for h in result["hours"])
    if minimum_rounds>=2 and not starts:
        raise AssertionError("Multiround component never tested a complete prior primal start")
    if phase_one and "feasibility" not in kinds:
        raise AssertionError("Phase I never exercised a certified continuous-domain feasibility cut")
    return {"objective":summary["objective"],"bound":summary["bound"],"gap":summary["relative_gap"],
        "rounds":len(rows),"solve_calls":summary["solve_calls"],"processes":pids,
        "audited_starts":len(starts),"native_start_consumption_reported":all(s["native_consumption_reported"] for s in starts),
        "feasibility_cuts":kinds.count("feasibility"),"original_audit":native["storage"]["original_scheduling_audit"]}


def main(integration_only=False,native_guard=False):
    evidence=Path(tempfile.mkdtemp(prefix="reserve_loop_components_",dir=ROOT/"tmp"))
    print("BENDERS_COMPONENT_EVIDENCE "+str(evidence),flush=True)
    env=runtime_environment();os.environ.update(env)
    hashes=source_hashes(ROOT);stages=[]
    atomic_json(evidence/"registration.json",{"source_hashes":hashes,"tiny_only":True,"full_case_runs":0},exclusive=True)
    def stage(name,command,seconds=240):
        start=time.perf_counter()
        with (evidence/(name+".log")).open("w",encoding="utf-8") as log:
            process=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
            try:
                code=process.wait(timeout=seconds)
            except BaseException:
                from go3cpu.controller import stop_process
                stop_process(process)
                raise
        row={"name":name,"pid":process.pid,"returncode":code,"seconds":time.perf_counter()-start,
             "log_sha256":sha256(evidence/(name+".log"))}
        stages.append(row);print(json.dumps(row),flush=True)
        if code:
            raise RuntimeError(f"Tiny Benders gate failed: {name}")
        return row
    common=[str(JULIA),"--startup-file=no",f"--project={ROOT}"]
    config=ROOT/("config/tiny_reserve_benders_native_guard.json" if native_guard else "config/tiny_reserve_benders.json")
    results={}
    if not integration_only:
        stage("certificate",common+["scripts/test_reserve_benders_certificate.jl"])
        stage("runtime",common+["scripts/test_reserve_benders_runtime.jl"])
        stage("python",[sys.executable,"-m","unittest","discover","-s","tests","-v"])
    for kind in ("cost_feedback","phase_one","bounded_incumbent"):
        output=evidence/kind;output.mkdir()
        fixture_kind=kind;fixture_config=config
        if kind=="bounded_incumbent":
            fixture_kind="cost_feedback"
            settings=json.loads(config.read_text());settings["scheduling_benders_max_rounds"]=1
            fixture_config=output/"config.json";atomic_json(fixture_config,settings,exclusive=True)
        row=stage(kind+"_build",common+["scripts/build_reserve_benders_fixture.jl",fixture_kind,str(output),str(fixture_config)])
        manifest=output/"scheduling_spool/manifest.json"
        atomic_json(output/"scheduling_spool/builder_exit.json",{"pid":row["pid"],"returncode":0,
            "exited_before_native_launch":True,"process_wall_seconds":row["seconds"],
            "manifest_sha256":sha256(manifest)},exclusive=True)
        compact_stage(common,output/"scheduling_spool",output,time.time()+120)
        reserve_partition_stage(common,output/"scheduling_spool",output,time.time()+120)
        stage(kind+"_loop",[sys.executable,"scripts/run_reserve_benders.py",str(JULIA),str(output),
            str(fixture_config),str(time.time()+180)])
        expected=json.loads((output/"expected.json").read_text())
        if kind=="bounded_incumbent":
            results[kind]=audit_loop(output,expected=-3.0,require_gap=False)
            summary=json.loads((output/"reserve_decomposition/summary.json").read_text())
            native=json.loads((output/"native_result.json").read_text())
            if (summary["reason"]!="round_limit" or summary["scheduling_gap_met"]
                    or summary["relative_gap"]!=1.0 or native["statistics"]["termination"]!="ITERATION_LIMIT"):
                raise AssertionError("Bounded feasible incumbent was incorrectly called gap-certified")
        else:
            results[kind]=audit_loop(output,minimum_rounds=expected["expected_minimum_rounds"],
                expected=expected["objective"],phase_one=kind=="phase_one")
    output=evidence/"dc_worker"
    stage("tiny_source_ac_pipeline",[sys.executable,"scripts/run_disk_worker.py",str(JULIA),
        "tmp/official_tiny/dc_problem.json",str(output),str(config),str(time.time()+240)],seconds=245)
    results["source_dc_loop"]=audit_loop(output)
    stage("independent_official_verification",[sys.executable,"scripts/verify_candidate.py",
        "--input","tmp/official_tiny/dc_problem.json","--solution",str(output/"candidate_final.json"),
        "--output",str(evidence/"dc_verification"),"--seconds","60",
        "--official-contingency-batch-size","2"],seconds=90)
    from component_gate import dc_pipeline_audit
    results["source_dc_ac_pipeline"]=dc_pipeline_audit(evidence)
    if native_guard:
        from go3cpu.native_highs import backend_record
        native=backend_record(json.loads(config.read_text()),root=ROOT)
        checked=[]
        for path in evidence.glob("*/reserve_decomposition/rounds/*/*/result.json"):
            record=json.loads(path.read_text())
            identity=record["native_backend"]
            if (identity["policy"]!=native["policy"] or
                    identity["library_sha256"]!=native["manifest"]["files"]["library"]["sha256"] or
                    identity["manifest_sha256"]!=native["manifest_sha256"] or
                    identity["objective_clique_max_size"]!=0):
                raise AssertionError("Tiny native worker did not load the exact guarded library")
            checked.append(str(path))
        if len(checked)<16:
            raise AssertionError("Incomplete native master/recourse identity coverage")
        results["native_guard"]={"policy":native["policy"],"workers_checked":len(checked),
                                 "library_sha256":native["manifest"]["files"]["library"]["sha256"]}
    if source_hashes(ROOT)!=hashes:
        raise RuntimeError("Source changed during the component gate")
    result={"pass":True,"complete":True,"tiny_only":True,"full_case_runs":0,
        "evidence_directory":str(evidence),"source_hashes":hashes,"stages":stages,"results":results}
    atomic_json(evidence/"result.json",result,exclusive=True)
    print("BENDERS_COMPONENT_PASS "+json.dumps({"evidence_directory":str(evidence),"stages":len(stages),
        "results":results},allow_nan=False),flush=True)


if __name__=="__main__":
    if len(set(sys.argv[1:]))!=len(sys.argv[1:]) or not set(sys.argv[1:])<={"--integration-only","--native-guard"}:
        raise SystemExit("Only --integration-only and --native-guard are supported")
    main(integration_only="--integration-only" in sys.argv,native_guard="--native-guard" in sys.argv)
