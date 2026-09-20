"""One cold scheduling attempt, sequential native master/recourse lifetimes.

Internal rounds share one absolute budget. Each proposed schedule is tested in
every source reserve LP; only a full original-model primal audit can establish
an incumbent. This is not an AC/global GO3 optimality certificate.
"""
import json
import math
import os
from pathlib import Path
import shutil
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/"scripts"))
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import local_path, GIB
from run_disk_worker import launch_stage, NativeCallDeadlineExceeded

POLICY="source_reserve_benders_v1"
ROUND_SCHEMA="go3_source_reserve_benders_round_v1"


def artifact(path):
    path=local_path(path)
    return {"path":str(path),"sha256":sha256(path)}


def checked_path(ref):
    path=local_path(ref["path"])
    if sha256(path)!=ref["sha256"]:
        raise ValueError(f"Benders artifact identity mismatch: {path}")
    return path


def scheduling_gap(upper,incumbent):
    if upper is None or incumbent is None:
        return None
    if not math.isfinite(upper) or not math.isfinite(incumbent):
        raise ValueError("Nonfinite Benders objective or bound")
    if upper<incumbent-max(1e-6,1e-10*max(1.0,abs(incumbent))):
        raise ValueError("Scheduling master bound is below a verified incumbent")
    return max(0.0,upper-incumbent)/max(abs(incumbent),1e-10)


def terminal_status(reason,gap_met):
    if gap_met:
        return 7,"OPTIMAL"
    if reason=="round_limit":
        return 14,"ITERATION_LIMIT"
    if reason in ("master_absolute_deadline","recourse_absolute_deadline",
                  "master_native_call_deadline","recourse_native_call_deadline",
                  "scheduling_budget_reserved_for_recourse_and_finalization",
                  "master_returned_no_feasible_primal"):
        return 13,"TIME_LIMIT"
    raise ValueError("Unknown Benders terminal reason")


def validate_configuration(config):
    if (config.get("scheduling_decomposition_policy")!=POLICY
            or config.get("scheduling_storage_policy")!="disk_isolated_native_v1"
            or config.get("scheduling_compaction_policy")!="exact_zero_alias_v1"
            or config.get("scheduling_seed_policy","off")!="off"
            or config.get("scheduling_include_reserves") is not True):
        raise ValueError("Unregistered or source-incomplete Benders configuration")
    for name in ("scheduling_seconds","scheduling_relative_gap","scheduling_benders_master_round_seconds",
                 "scheduling_benders_recourse_seconds","scheduling_benders_recourse_reserve_seconds",
                 "scheduling_benders_finalize_seconds"):
        value=config.get(name)
        if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<=0:
            raise ValueError(f"Invalid Benders budget/tolerance: {name}")
    rounds=config.get("scheduling_benders_max_rounds")
    if isinstance(rounds,bool) or not isinstance(rounds,int) or rounds<1:
        raise ValueError("Invalid Benders round limit")
    if config["scheduling_benders_recourse_reserve_seconds"]+config["scheduling_benders_finalize_seconds"]>=config["scheduling_seconds"]:
        raise ValueError("No scheduling time reserved for a master solve")


def run_stage(common,output,config_path,request,directory,deadline,config):
    directory=local_path(directory)
    if directory.exists():
        raise FileExistsError("Immutable Benders stage exists; no hidden retry")
    directory.mkdir(parents=True)
    request_path=directory/"request.json"
    atomic_json(request_path,request,exclusive=True)
    native_limit=config["scheduling_benders_master_round_seconds"] if request["mode"]=="master" else config["scheduling_benders_recourse_seconds"]
    try:
        pid,code,wall=launch_stage(common+[str(ROOT/"src/solve_reserve_benders_worker.jl"),str(output),
            str(config_path),str(request_path),str(directory),str(deadline)],deadline=deadline,
            log_path=directory/"console.log",memory_path=directory/"memory.jsonl",progress_path=output/"progress",
            memory_floor_bytes=int(config.get("minimum_available_memory_gib",2)*GIB),
            native_call_limit=native_limit)
    except TimeoutError as exc:
        # launch_stage's finally has stopped its owned tree and closed logs.
        # Preserve this interrupted call even though no result.json exists.
        atomic_json(directory/"interruption.json",{"schema":"go3_native_stage_interruption_v1",
            "identity":request["identity"],"request_sha256":sha256(request_path),
            "mode":request["mode"],"round":request["round"],"error":str(exc),
            "kind":"native_call_deadline" if isinstance(exc,NativeCallDeadlineExceeded) else "absolute_stage_deadline",
            "native_call":getattr(exc,"details",None),"launch_cleanup_completed":True,
            "no_relaunch":True,"stage_deadline_epoch":deadline},exclusive=True)
        raise
    path=directory/"result.json"
    record=json.loads(path.read_text())
    if (record.get("schema")!=ROUND_SCHEMA or not record.get("complete")
            or record.get("pid")!=pid or record.get("identity")!=request["identity"]
            or record.get("mode")!=request["mode"] or record.get("request_sha256")!=sha256(request_path)):
        raise ValueError("Incomplete or mismatched Benders stage result")
    atomic_json(directory/"exit.json",{"pid":pid,"returncode":code,"process_wall_seconds":wall,
        "exited_before_next_native_stage":True,"result_sha256":sha256(path)},exclusive=True)
    record["process_wall_seconds"]=wall
    return record,artifact(path)


def run(julia,output,config_path,deadline):
    julia,output,config_path=map(local_path,(julia,output,config_path))
    config=json.loads(config_path.read_text());validate_configuration(config)
    if (output/"native_result.json").exists():
        raise FileExistsError("Completed scheduling result already exists")
    root=output/"reserve_decomposition"
    rounds_path=root/"rounds"
    if rounds_path.exists():
        raise FileExistsError("Cold Benders attempt already started; no retry")
    rounds_path.mkdir()
    source=json.loads((output/"scheduling_spool/manifest.json").read_text())
    partition=json.loads((root/"reserve_partition/manifest.json").read_text())
    if source["identity"]["config"]!=config:
        raise ValueError("Scheduling config differs from source construction")
    identity={"partition_manifest_sha256":sha256(root/"reserve_partition/manifest.json"),
              "source_manifest_sha256":sha256(output/"scheduling_spool/manifest.json")}
    common=[str(julia),"--startup-file=no",f"--project={ROOT}"]
    started=time.perf_counter()
    scheduling_end=min(deadline,time.time()+config["scheduling_seconds"])
    solve_end=scheduling_end-config["scheduling_benders_finalize_seconds"]
    history=[];rounds=[];interruptions=[];best=None;best_ref=None;upper=None;reason="round_limit"
    options=None;solve_calls=0
    for number in range(1,config["scheduling_benders_max_rounds"]+1):
        master_end=solve_end-config["scheduling_benders_recourse_reserve_seconds"]
        if time.time()>=master_end:
            reason="scheduling_budget_reserved_for_recourse_and_finalization";break
        request={"mode":"master","round":number,"identity":identity,
                 "recourse_history":history,"start":best_ref}
        directory=rounds_path/f"round_{number:04d}"
        try:
            master,master_ref=run_stage(common,output,config_path,request,directory/"master",master_end,config)
        except TimeoutError as exc:
            reason="master_native_call_deadline" if isinstance(exc,NativeCallDeadlineExceeded) else "master_absolute_deadline"
            interruptions.append(artifact(directory/"master/interruption.json"));break
        options=master["options"];solve_calls+=master["solve_calls"]
        stats=master["statistics"]
        if stats["native_status"]==8 and best is not None:
            raise RuntimeError("Master declared infeasible despite a fully audited prior incumbent")
        if stats["bound"] is not None and stats["native_status"]!=8:
            upper=stats["bound"] if upper is None else min(upper,stats["bound"])
        row={"round":number,"master":master_ref,"master_statistics":stats,"master_start":master["start"],
             "master_process_wall_seconds":master["process_wall_seconds"],"master_upper_bound":upper,
             "recourse":None,"verified_incumbent":None if best is None else best["objective"]}
        if not stats["has_primal"]:
            reason="master_returned_no_feasible_primal"
            rounds.append(row);atomic_json(directory/"summary.json",row,exclusive=True);break
        request={"mode":"recourse","round":number,"identity":identity,"master_result":master_ref}
        try:
            recourse,recourse_ref=run_stage(common,output,config_path,request,directory/"recourse",solve_end,config)
        except TimeoutError as exc:
            reason="recourse_native_call_deadline" if isinstance(exc,NativeCallDeadlineExceeded) else "recourse_absolute_deadline"
            interruptions.append(artifact(directory/"recourse/interruption.json"))
            row["termination"]=reason
            rounds.append(row);atomic_json(directory/"summary.json",row,exclusive=True)
            break
        if recourse["hours_completed"]!=len(partition["periods"]) or recourse["hours_required"]!=len(partition["periods"]):
            raise ValueError("Incomplete source reserve hour set")
        solve_calls+=recourse["solve_calls"]
        history.append(recourse_ref)
        if recourse["all_hours_feasible"]:
            audit=recourse["original_audit"]
            if not (audit["complete"] and audit["pass"] and audit["objective_agreement"]):
                raise ValueError("Candidate has no passing original scheduling audit")
            if best is None or recourse["objective"]>best["objective"]:
                best=recourse;best_ref=recourse_ref
        gap=scheduling_gap(upper,None if best is None else best["objective"])
        row.update({"recourse":recourse_ref,"recourse_process_wall_seconds":recourse["process_wall_seconds"],
            "all_source_hours_feasible":recourse["all_hours_feasible"],"added_cuts":len(recourse["cuts"]),
            "verified_incumbent":None if best is None else best["objective"],"relative_gap":gap})
        rounds.append(row);atomic_json(directory/"summary.json",row,exclusive=True)
        print("BENDERS_ROUND "+json.dumps(row,allow_nan=False),flush=True)
        if gap is not None and gap<=config["scheduling_relative_gap"]:
            reason="scheduling_gap_met";break
    gap=scheduling_gap(upper,None if best is None else best["objective"])
    summary={"schema":"go3_source_reserve_benders_summary_v1","complete":True,"pid":os.getpid(),
        "policy":POLICY,"identity":identity,"reason":reason,"rounds":rounds,"solve_calls":solve_calls,
        "solve_calls_scope":"Returned calls in completed stages; interrupted stage evidence is separate",
        "interrupted_stages":interruptions,
        "incumbent":best_ref,"objective":None if best is None else best["objective"],"bound":upper,
        "relative_gap":gap,"scheduling_gap_met":gap is not None and gap<=config["scheduling_relative_gap"],
        "all_source_hours_required":partition["periods"],"wall_seconds":time.perf_counter()-started,
        "native_master_and_recourse_processes_never_overlap":True,
        "scope":"Original joint scheduling subproblem only; not full AC or GO3 optimality"}
    atomic_json(root/"summary.json",summary,exclusive=True)
    if best is None:
        raise RuntimeError(f"Benders scheduling has no source-feasible incumbent: {reason}")
    if time.time()>=scheduling_end:
        raise TimeoutError("Benders finalization deadline exhausted")
    primal=checked_path(best["source_primal"])
    destination=output/"native_primal.bin"
    if destination.exists():
        raise FileExistsError("Native primal output already exists")
    shutil.copyfile(primal,destination)
    if sha256(destination)!=best["source_primal"]["sha256"]:
        raise ValueError("Benders final primal copy mismatch")
    terminal,label=terminal_status(reason,summary["scheduling_gap_met"])
    statistics={"native_status":terminal,"termination":label,
        "termination_origin":"decomposition_gap_or_budget_not_a_single_HiGHS_status",
        "has_primal":True,"objective":best["objective"],"bound":upper,"relative_gap":gap,
        "solve_seconds":sum(r["master_statistics"]["solve_seconds"] for r in rounds),
        "solve_wall_seconds":summary["wall_seconds"],
        "simplex_iterations":sum(r["master_statistics"]["simplex_iterations"] for r in rounds),
        "barrier_iterations":sum(r["master_statistics"]["barrier_iterations"] for r in rounds),
        "nodes":sum(r["master_statistics"]["nodes"] for r in rounds),"decomposition":summary}
    unavailable_counts={key for key in ("simplex_iterations","barrier_iterations")
        if any(r["master_statistics"][key]<0 for r in rounds)}
    # Account for ALL reserve/Phase-I calls, not just the retained incumbent.
    for ref in history:
        recourse=json.loads(checked_path(ref).read_text())
        for hour in recourse["hours"]:
            entries=[hour["statistics"]]
            if hour["kind"]=="feasibility":
                entries.append(hour["ordinary_cost_statistics"])
            for entry in entries:
                for key in ("solve_seconds","simplex_iterations","barrier_iterations"):
                    statistics[key]+=entry[key]
                    if entry[key]<0:
                        unavailable_counts.add(key)
    for key in unavailable_counts:
        statistics[key]=None
    master_manifest=json.loads((root/"reserve_partition/master/manifest.json").read_text())
    storage={"policy":"disk_isolated_native_v1","decomposition_policy":POLICY,
        "whole_model_copy":False,"builder_exited_before_native_load":True,"builder_solve_calls":0,
        "cold_unsolved":True,"variables":source["variables"],"rows":source["rows"],"nonzeros":source["nonzeros"],
        "rows_or_columns_eliminated":0,"source_rows_partitioned_not_dropped":True,"source_values_changed":False,
        "compaction_policy":"exact_zero_alias_v1","original_scheduling_audit":best["original_audit"],
        "native_variables":master_manifest["variables"],"native_rows":master_manifest["rows"],
        "native_nonzeros":master_manifest["nonzeros"],"native_julia_per_row_metadata":False,
        "raw_case_parsed_in_native_process":False,"extraction_metadata_loaded_in_native_process":False,
        "native_master_and_recourse_processes_never_overlap":True,"solve_calls":solve_calls,
        "options":options,"decomposition_summary":artifact(root/"summary.json")}
    result={"schema":"go3_isolated_native_result_v1","complete":True,"diagnostic_only":False,
        "pid":os.getpid(),"coordinator_parent_pid":os.getppid(),"identity":source["identity"],"spool_manifest_sha256":identity["source_manifest_sha256"],
        "primal_sha256":sha256(destination),"primal_bytes":destination.stat().st_size,
        "statistics":statistics,"storage":storage,"options":options}
    atomic_json(output/"original_scheduling_audit.json",best["original_audit"],exclusive=True)
    atomic_json(output/"statistics/original_economic_mip.json",statistics,exclusive=True)
    atomic_json(output/"native_result.json",result,exclusive=True)
    return result


if __name__=="__main__":
    if len(sys.argv)!=5:
        raise SystemExit("julia output config absolute_work_deadline required")
    run(*sys.argv[1:4],float(sys.argv[4]))
