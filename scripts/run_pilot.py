"""One cold GO3 pilot, owned-process supervision and exhaustive incumbent checks.

The exclusive latch is never deleted, even on failure. There is no retry path.
Only tiny tests and setup may be repeated without a new user authorization.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time
import traceback

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from go3cpu.contract import load_case, case_manifest
from go3cpu.controller import (Deadline, Incumbent, Snapshots, atomic_json, claim_pilot,
    latest_candidate, latest_snapshot, registered_latch, run_bounded, sha256, stop_process,
    partial_worker_timings, partial_scheduling_statistics)
from go3cpu.official import configure_imports
from go3cpu.safety import (GIB, local_path, storage_check, configured_memory_floor,
                          available_memory_check, HostMemoryPressureError)
from go3cpu.campaign import (sixth_best_target, quality_gate, registered_budget,
                             experiment_exit_code, pipeline_coverage)
from go3cpu.speedup import (skip_intermediate_verification, final_verification_required,
                           runtime_target_status)
configure_imports(ROOT)
import psutil

JULIA=Path("C:/Users/thoma/Documents/goc2-ac-score-check/julia/julia-1.10.11/bin/julia.exe")


def git(*args,cwd=ROOT):
    return subprocess.check_output(["git","-C",str(cwd),*args],text=True).strip()


def runtime_environment():
    env=os.environ.copy()
    env.update(TEMP=str(ROOT/"tmp"),TMP=str(ROOT/"tmp"),
        JULIA_DEPOT_PATH=str(ROOT/"environments/julia-depot"),JULIA_NUM_THREADS="1",
        OPENBLAS_NUM_THREADS="1",OMP_NUM_THREADS="1",MKL_NUM_THREADS="1",
        PYTHONPYCACHEPREFIX=str(ROOT/".cache/python-bytecode"),PYTHONUNBUFFERED="1")
    for key in ("TEMP","TMP","JULIA_DEPOT_PATH","PYTHONPYCACHEPREFIX"):
        local_path(env[key]).mkdir(parents=True,exist_ok=True)
    for p in (ROOT,JULIA,Path(sys.executable),ROOT/"runs",ROOT/".cache",ROOT/"config"):
        local_path(p)
    return env


def runtime_identity():
    import numpy, scipy, pydantic
    return {"python_executable":str(local_path(sys.executable)),"python_version":platform.python_version(),
            "numpy":numpy.__version__,"scipy":scipy.__version__,
            "pydantic":pydantic.__version__,"psutil":psutil.__version__}


def preflight(config_path):
    config=json.loads(local_path(config_path).read_text())
    if (config.get("pilot_ready") is not True or config["maximum_full_runs"]!=1 or
        not registered_budget(config) or not config["cold_start"] or config["allow_pop_solution"]):
        raise RuntimeError("Pilot registration is not ready or scope changed")
    latch=registered_latch(ROOT,config)
    if latch.exists():
        raise RuntimeError("This explicit pilot authorization was already claimed; no automatic replacement")
    if git("status","--porcelain"):
        raise RuntimeError("Freeze and push all code/configuration first: worktree is not clean")
    commit=git("rev-parse","HEAD")
    branch=git("branch","--show-current")
    if git("rev-parse",f"origin/{branch}")!=commit:
        raise RuntimeError("Frozen commit is not recorded as pushed")
    for name,source in json.loads((ROOT/"manifests/sources.json").read_text())["upstream"].items():
        directory=ROOT/".cache/upstream"/name
        if git("rev-parse","HEAD",cwd=directory)!=source["commit"] or git("status","--porcelain","--untracked-files=no",cwd=directory):
            raise RuntimeError(f"Upstream checkout changed: {name}")
        for f,digest in source["tracked_file_sha256"].items():
            if sha256(directory/f)!=digest:
                raise RuntimeError(f"Upstream file hash mismatch: {name}/{f}")
    test_record=json.loads((ROOT/"manifests/component_tests.json").read_text())
    if not test_record.get("pass"):
        raise RuntimeError("Component test gate has not passed")
    if test_record.get("runtime") != runtime_identity():
        raise RuntimeError("Use the same Python/dependency runtime as the completed component tests")
    from go3cpu.provenance import assert_tested_sources_unchanged
    assert_tested_sources_unchanged(ROOT,test_record["source_sha256"])
    if sha256(ROOT/config["input_path"])!=config["input_sha256"]:
        raise RuntimeError("Registered input hash changed")
    case_record=json.loads((ROOT/config.get("case_manifest_path","manifests/case.json")).read_text())
    if any(case_record[k]!=config[k] for k in ("network","scenario","input_sha256")):
        raise RuntimeError("Case identity manifest does not match configuration")
    quality_target=None
    if config.get("comparison_manifest_path"):
        comparison=json.loads((ROOT/config["comparison_manifest_path"]).read_text())
        if comparison["sha256"]!=sha256(ROOT/".cache/sources/results_20240506.xlsx"):
            raise RuntimeError("Comparison workbook hash changed")
        quality_target=sixth_best_target(comparison,network=config["network"],scenario=config["scenario"],
            switching=config["official_allow_switching"])
    env=runtime_environment()
    host_memory=None
    memory_floor=configured_memory_floor(config)
    if memory_floor is not None:
        measurement=psutil.virtual_memory()
        host_memory=available_memory_check(measurement.available,measurement.total,floor_bytes=memory_floor)
    hardware={"platform":platform.platform(),"python":sys.version,"runtime":runtime_identity(),
        "physical_cpu_count":psutil.cpu_count(logical=False),"logical_cpu_count":psutil.cpu_count(),
        "ram_bytes":psutil.virtual_memory().total}
    if os.name=="nt":
        hardware["windows_inventory"]=json.loads(subprocess.check_output([
            "powershell.exe","-NoProfile","-Command",
            "@{ computer=Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory; cpu=Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors } | ConvertTo-Json -Depth 4"],text=True))
    record={"commit":commit,"branch":branch,"config_sha256":sha256(config_path),
        "pilot_id":config.get("pilot_id","pilot_001"),"authorization_latch":str(latch),
        "julia_manifest_sha256":sha256(ROOT/"Manifest.toml"),"source_manifest_sha256":sha256(ROOT/"manifests/sources.json"),
        "component_tests_sha256":sha256(ROOT/"manifests/component_tests.json"),
        "config":config,"case":case_record,"quality_target":quality_target,
        "hardware":hardware,"host_memory":host_memory,"storage":storage_check(ROOT,pending_bytes=GIB,
             floor_bytes=int(config["minimum_free_gib"]*GIB)),
        "setup_exclusions":"Dependency installation, package precompilation, source registration, checkout and download only. Runtime process import/JIT, raw loading, preprocessing and case factors included.",
        "initialization":"Cold; source conditions only, no POP or saved optimized solutions",
        "runtime_target":runtime_target_status(config, 0),
        "benchmark_kind":f"One local cold attempt, {config.get('target_seconds',config['total_seconds'])}-second target and {config['total_seconds']}-second safety limit; not an official competition submission"}
    return config,env,record


class Monitor:
    def __init__(self,run,clock,config):
        self.run,self.clock,self.config=run,clock,config
        self.owned=[]
        self.peak_rss=0
        self.cpu_by_pid={}
        self.next_storage=0
        self.next_report=0
        self.last_stage=None
        self.target_reported=False
        self.memory_floor=configured_memory_floor(config)
        self.next_memory=0
        self.last_host_memory=None
        self.snapshots=Snapshots(run/"live_status")

    def observe(self,process=None):
        if process is not None and process not in self.owned:
            self.owned.append(process)
        memory=0
        seen=set()
        for p in self.owned:
            if p.poll() is not None:
                continue
            try:
                parent=psutil.Process(p.pid)
                for item in [parent]+parent.children(recursive=True):
                    if item.pid in seen:
                        continue
                    seen.add(item.pid)
                    memory+=item.memory_info().rss
                    cpu=item.cpu_times()
                    self.cpu_by_pid[item.pid]=cpu.user+cpu.system
            except (psutil.NoSuchProcess,psutil.AccessDenied):
                pass
        current=psutil.Process()
        memory+=current.memory_info().rss
        cpu=current.cpu_times()
        self.cpu_by_pid[current.pid]=cpu.user+cpu.system
        self.peak_rss=max(self.peak_rss,memory)
        now=time.perf_counter()
        if self.memory_floor is not None and now>=self.next_memory:
            measurement=psutil.virtual_memory()
            try:
                self.last_host_memory=available_memory_check(measurement.available,measurement.total,
                    floor_bytes=self.memory_floor)
            except HostMemoryPressureError as exc:
                self.last_host_memory={**exc.record,"elapsed_seconds":now-self.clock.start}
                atomic_json(self.run/"resource_stop.json",self.last_host_memory)
                raise
            self.next_memory=now+2.0
        if now>=self.next_storage:
            storage_check(ROOT,floor_bytes=int(self.config["minimum_free_gib"]*GIB))
            self.next_storage=now+5
        progress=latest_snapshot(self.run/"worker/progress")
        target=runtime_target_status(self.config,now-self.clock.start)
        if not target["within_target"] and not target["target_is_hard_deadline"] and not self.target_reported:
            print("PILOT_SOFT_TARGET_EXCEEDED "+json.dumps(target),flush=True)
            self.target_reported=True
        stage=(progress.get("stage"),progress.get("interval"))
        if now>=self.next_report or stage!=self.last_stage:
            message={"elapsed_seconds":now-self.clock.start,"remaining_seconds":self.clock.remaining(),
                "worker":progress,"peak_sampled_process_tree_rss_bytes":self.peak_rss,
                "runtime_target":target,"host_memory":self.last_host_memory}
            self.snapshots.publish(message)
            print("PILOT_PROGRESS "+json.dumps(message),flush=True)
            self.next_report=now+30
            self.last_stage=stage


def execute(config_path,config,env,preflight_record):
    stamp=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    pilot_id=config.get("pilot_id","pilot_001")
    run=ROOT/"runs"/f"{config['network']}_s{config['scenario']}_{pilot_id}_{stamp}"
    # Claim before any solver starts. An unsuccessful run still consumes the authorization.
    claim_pilot(registered_latch(ROOT,config),{"pilot_id":pilot_id,"run":str(run),
        "commit":preflight_record["commit"],"created_utc":stamp})
    run.mkdir(parents=True,exist_ok=False)
    worker_dir=run/"worker"; worker_dir.mkdir()
    clock=Deadline(config["total_seconds"],reserve=config["evaluation_reserve_seconds"]+config["finalization_reserve_seconds"])
    monitor=Monitor(run,clock,config)
    incumbent=Incumbent(run/"verified_incumbent",
        prefer_physical=bool(preflight_record.get("quality_target")))
    evaluations=[]
    result={"schema_version":1,"status":"INCOMPLETE","preflight":preflight_record,
        "run_directory":str(run),"global_optimality_certificate":False,
        "full_GO3_certified_gap":None,"evaluations":evaluations}
    if preflight_record.get("quality_target"):
        result["quality_target"]=preflight_record["quality_target"]
    atomic_json(run/"initial_record.json",result,exclusive=True)
    worker=None
    finished=threading.Event()
    # Emergency last resort, not normal cancellation: no optimizer survives the global budget.
    # Normal work cancellation is 270 seconds earlier and final verification ends 30 seconds earlier.
    def last_resort():
        if not finished.wait(max(0.0,clock.remaining()-3)):
            for p in list(monitor.owned):
                stop_process(p)
            atomic_json(run/"hard_deadline.json",{"status":"DEADLINE","elapsed_seconds":time.perf_counter()-clock.start,
                "retained_certificate_directory":str(run/"verified_incumbent"),
                "note":"Only already-written complete certificates remain valid; no incomplete verification is a pass."})
            os._exit(124)
    threading.Thread(target=last_resort,daemon=True).start()

    def verify(candidate,label,max_seconds):
        allowance=min(max_seconds,clock.remaining()-config["finalization_reserve_seconds"])
        if allowance<3:
            return None
        output=run/"verification"/label
        output.mkdir(parents=True,exist_ok=False)
        start=time.perf_counter()
        outcome=run_bounded([sys.executable,str(ROOT/"scripts/verify_candidate.py"),
            "--input",str(ROOT/config["input_path"]),"--input-sha256",config["input_sha256"],
            "--solution",str(candidate),"--output",str(output),"--seconds",str(allowance)],
            output/"process.log",cwd=ROOT,env=env,deadline=start+allowance,observer=monitor.observe)
        file=output/"certificate.json"
        certificate=json.loads(file.read_text()) if file.exists() else {
            "pass":False,"complete":False,"candidate_sha256":sha256(candidate),
            "error":"Verification timed out or exited before writing a complete certificate"}
        entry={"label":label,"solution":str(candidate),"process":outcome,
            "wall_seconds":time.perf_counter()-start,"certificate":certificate}
        evaluations.append(entry)
        if not outcome["timeout"] and outcome["returncode"]==0:
            entry["retained"]=incumbent.consider(candidate,certificate)
        else:
            entry["retained"]=False
        atomic_json(run/"verification_records"/(label+".json"),entry,exclusive=True)
        print("PILOT_VERIFICATION "+json.dumps({"label":label,"retained":entry["retained"],
            "pass":certificate.get("pass"),"complete":certificate.get("complete"),
            "objective":certificate.get("objective"),"wall_seconds":entry["wall_seconds"]}),flush=True)
        return entry

    try:
        started=time.perf_counter()
        case,digest=load_case(ROOT/config["input_path"],config["input_sha256"])
        result["runtime_case_manifest"]=case_manifest(case)
        result["controller_raw_loading_seconds"]=time.perf_counter()-started
        del case
        atomic_json(run/"preflight.json",preflight_record)
        work_epoch=time.time()+clock.remaining(work=True)
        command=[str(JULIA),"--startup-file=no",f"--project={ROOT}",str(ROOT/"src/pilot_worker.jl"),
            str(ROOT/config["input_path"]),str(worker_dir),str(local_path(config_path)),str(work_epoch)]
        initial_checked=False
        with (worker_dir/"console.log").open("w",encoding="utf-8") as log:
            worker=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
            monitor.owned.append(worker)
            while worker.poll() is None:
                monitor.observe()
                if clock.remaining(work=True)<=0:
                    result["work_deadline_reached"]=True
                    stop_process(worker)
                    break
                initial=worker_dir/"candidate_schedule.json"
                if initial.exists() and not initial_checked:
                    if skip_intermediate_verification(config):
                        result["intermediate_verification_skipped"]={
                            "reason":"Aggregate schedule with source voltages is explicitly unverified; protect final exhaustive check",
                            "candidate_sha256":sha256(initial),"incumbent_claimed":False}
                    else:
                        verify(initial,"schedule",min(config["initial_verification_seconds"],clock.remaining(work=True)))
                    initial_checked=True
                    # Generated handshake is not a solver start or a separate experiment.
                    (worker_dir/"continue_after_schedule").write_text("initial candidate policy handled; continue within original deadline\n")
                time.sleep(0.1)
    except Exception as exc:
        result["controller_error"]=traceback.format_exc()
        if isinstance(exc,HostMemoryPressureError):
            result["resource_stop"]={**exc.record,"classification":"HOST_MEMORY_PRESSURE_STOP"}
    finally:
        if worker is not None:
            stop_process(worker)
            result["worker_returncode"]=worker.returncode
        for p in monitor.owned:
            stop_process(p)
        # An interrupted worker must not skip the reserved verification phase.
        # This is verification of an already-written checkpoint, never another solve.
        try:
            candidate=latest_candidate(worker_dir)
            coverage_stats={"ac_intervals":[json.loads(p.read_text()) for p in sorted((worker_dir/"statistics").glob("ac_*.json"))]}
            should_verify=final_verification_required(config,latest_snapshot(worker_dir/"progress"),
                result.get("worker_returncode"),coverage_stats,len(preflight_record["case"]["interval_hours"]))
            if not should_verify:
                result["final_verification_skipped"]="Incomplete horizon/finalization: checkpoint retained as UNVERIFIED; no successful solution claimed"
            if should_verify and candidate is not None and not any(e["certificate"]["candidate_sha256"]==sha256(candidate) for e in evaluations):
                verify(candidate,"final",clock.remaining()-config["finalization_reserve_seconds"])
        except Exception:
            result["final_verification_error"]=traceback.format_exc()
        result["verified_incumbent"]=incumbent.record
        result["progress"]=latest_snapshot(worker_dir/"progress")
        result["penalized_violations_allowed_by_official_rules"]=True
        result["peak_sampled_process_tree_rss_bytes"]=monitor.peak_rss
        result["last_host_memory"]=monitor.last_host_memory
        result["cpu_seconds_by_pid_sampled"]=monitor.cpu_by_pid
        result["cpu_measurement_note"]="Sampled process CPU and sum of RSS, not allocator peak; shared pages may be counted twice."
        result["thread_settings"]={k:config[k] for k in ("highs_threads","julia_threads","blas_threads")}
        for name in ("timings","solver_statistics","worker_error","schedule_balance"):
            p=worker_dir/(name+".json")
            if p.exists():
                result[name]=json.loads(p.read_text())
        if "solver_statistics" not in result:
            result["solver_statistics"]={"ac_intervals":[json.loads(p.read_text()) for p in sorted((worker_dir/"statistics").glob("ac_*.json"))]}
            schedule_stats=worker_dir/"statistics/scheduling.json"
            if schedule_stats.exists():
                result["solver_statistics"]["scheduling"]=json.loads(schedule_stats.read_text())
        result["solver_statistics"].update(partial_scheduling_statistics(worker_dir))
        if "timings" not in result:
            result["timings"]=partial_worker_timings(worker_dir)
            result["timings"]["completed_ac_interval_wall_seconds"]=sum(
                s["wall_seconds"] for s in result["solver_statistics"].get("ac_intervals",[]))
        result["pipeline_coverage"]=pipeline_coverage(result["progress"],
            result.get("worker_returncode"), result["solver_statistics"],
            len(preflight_record["case"]["interval_hours"]))
        result["pipeline_completed"]=result["pipeline_coverage"]["complete"]
        result["status"]=("VERIFIED_HARD_FEASIBLE" if result["pipeline_completed"] else
            "VERIFIED_HARD_FEASIBLE_INCOMPLETE_REFINEMENT") if incumbent.record else "NO_VERIFIED_INCUMBENT"
        serialization=time.perf_counter()
        if "quality_target" in result:
            result["quality_gate"]=quality_gate(incumbent.record,result["quality_target"],
                pipeline_completed=result["pipeline_completed"],within_deadline=clock.remaining()>0)
        result["total_seconds_before_final_serialization"]=serialization-clock.start
        result["runtime_target"]=runtime_target_status(config,serialization-clock.start)
        atomic_json(run/"result.json",result,exclusive=True)
        final_serialization_seconds=time.perf_counter()-serialization
        total_seconds=time.perf_counter()-clock.start
        # Completion marker is written last; latch/provisional result never imply success.
        atomic_json(run/"completion.json",{"status":result["status"],"final_result_serialization_seconds":final_serialization_seconds,
            "result_sha256":sha256(run/"result.json"),"elapsed_through_result_serialization_seconds":time.perf_counter()-clock.start,
            "within_local_deadline":total_seconds<config["total_seconds"],
            "runtime_target":runtime_target_status(config,total_seconds)},exclusive=True)
        finished.set()
    print("PILOT_COMPLETE "+json.dumps({"status":result["status"],"run":str(run),
        "total_seconds":total_seconds,"objective":(incumbent.record or {}).get("objective"),
        "quality_target_pass":result.get("quality_gate",{}).get("pass")}),flush=True)
    return experiment_exit_code(result,total_seconds=total_seconds,budget_seconds=config["total_seconds"])


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--config",default=str(ROOT/"config/pilot.json"))
    p.add_argument("--preflight-only",action="store_true")
    args=p.parse_args()
    config,env,record=preflight(args.config)
    if args.preflight_only:
        print(json.dumps(record,indent=2)); return 0
    return execute(args.config,config,env,record)


if __name__=="__main__":
    sys.exit(main())
