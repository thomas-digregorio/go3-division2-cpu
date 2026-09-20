"""Single cold attempt, sequential processes. The builder never optimizes.

The ordinary run controller supervises this complete process tree, including
memory, physical disk and the original end-to-end deadline. No retry path.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from go3cpu.official import configure_imports
configure_imports(ROOT)
from go3cpu.controller import atomic_json, sha256, stop_process
from go3cpu.safety import local_path, storage_check, GIB
from go3cpu.process_memory import MemoryTimeline
from go3cpu.controller import latest_snapshot


def launch_stage(command, *, deadline, log_path=None, memory_path=None, progress_path=None,
                 memory_floor_bytes=2*GIB):
    if time.time()>=deadline:
        raise TimeoutError("Work deadline exhausted before process launch")
    stream=local_path(log_path).open("w",encoding="utf-8") if log_path else None
    process=None
    memory=None
    started=time.perf_counter()
    try:
        process=subprocess.Popen(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
        if memory_path:
            memory=MemoryTimeline(memory_path,floor_bytes=memory_floor_bytes)
        while process.poll() is None:
            if time.time()>=deadline:
                raise TimeoutError("Work deadline exhausted during process stage")
            if memory:
                event=latest_snapshot(progress_path) if progress_path else {}
                memory.observe(process.pid,event.get("event",event.get("stage","process_startup")))
            time.sleep(0.25)
        code=process.returncode
        if code:
            raise RuntimeError(f"Scheduling worker stage failed: {Path(command[3]).name}; exit={code}")
        return process.pid,code,time.perf_counter()-started
    finally:
        if process is not None:
            stop_process(process)
        if stream:
            stream.close()
        if memory:
            memory.close()


def main(julia,case,output,config_path,deadline):
    julia,case,output,config_path=map(local_path,(julia,case,output,config_path))
    config=json.loads(config_path.read_text())
    isolated=config.get("scheduling_storage_policy")=="disk_isolated_native_v1"
    if config.get("scheduling_storage_policy") not in ("disk_backed_native_v1","disk_isolated_native_v1"):
        raise ValueError("Only registered disk-backed scheduling may use this launcher")
    if config.get("scheduling_seed_policy","off")!="off":
        raise ValueError("Disk worker must start cold, without external or constructed starts")
    output.mkdir(parents=True,exist_ok=True)
    spool=output/"scheduling_spool"
    if spool.exists():
        raise FileExistsError("An old spool must never be reused for a new cold attempt")
    storage_check(output,pending_bytes=4*GIB,floor_bytes=int(config.get("minimum_free_gib",30)*GIB))
    common=[str(julia),"--startup-file=no",f"--project={ROOT}"]
    arguments=[str(case),str(output),str(config_path),str(deadline)]
    pid,code,wall=launch_stage(common+[str(ROOT/"src/build_scheduling_spool.jl")]+arguments,
        deadline=deadline,log_path=output/"scheduling_build_console.log")
    manifest=spool/"manifest.json"
    record=json.loads(manifest.read_text())
    if (not record.get("complete") or record.get("builder_pid")!=pid or record.get("builder_solve_calls")!=0
            or not record.get("cold_unsolved") or record["identity"]["input_sha256"]!=sha256(case)
            or record["identity"]["config"]!=config):
        raise RuntimeError("Builder did not complete an unchanged, cold, complete model")
    atomic_json(spool/"builder_exit.json",{"pid":pid,"returncode":code,"exited_before_native_launch":True,
        "process_wall_seconds":wall,"manifest_sha256":sha256(manifest)},exclusive=True)
    if isolated:
        if config.get("scheduling_compaction_policy","off")!="off":
            if config["scheduling_compaction_policy"]!="exact_zero_alias_v1":
                raise ValueError("Unknown compaction policy")
            compact_stage(common,spool,output,deadline,config.get("minimum_available_memory_gib",2))
        decomposition=config.get("scheduling_decomposition_policy","off")
        if decomposition not in ("off","source_reserve_benders_v1"):
            raise ValueError("Unknown scheduling decomposition policy")
        native_command=common+[str(ROOT/"src/solve_scheduling_native.jl")]+arguments
        if decomposition=="source_reserve_benders_v1":
            from run_reserve_benders import validate_configuration
            validate_configuration(config)
            reserve_partition_stage(common,spool,output,deadline,config.get("minimum_available_memory_gib",2))
            native_command=[sys.executable,str(ROOT/"scripts/run_reserve_benders.py"),str(julia),
                str(output),str(config_path),str(deadline)]
        pid,code,wall=launch_stage(native_command,
            deadline=deadline,log_path=output/"native_console.log",
            memory_path=output/"native_memory.jsonl",progress_path=output/"progress",
            memory_floor_bytes=int(config.get("minimum_available_memory_gib",2)*GIB))
        result_path=output/"native_result.json"
        result=json.loads(result_path.read_text())
        if (not result.get("complete") or result.get("diagnostic_only") or not native_pid_matches(result,pid,decomposition)
                or result["identity"]!=record["identity"] or result["spool_manifest_sha256"]!=sha256(manifest)):
            raise RuntimeError("Native result identity or completion mismatch")
        atomic_json(output/"native_exit.json",{"pid":result["pid"],"launcher_pid":pid,"returncode":code,"exited_before_ac_launch":True,
            "process_wall_seconds":wall,"result_sha256":sha256(result_path)},exclusive=True)
        if not result["statistics"]["has_primal"]:
            raise RuntimeError("Native scheduling returned no feasible primal; AC cannot start")
    launch_stage(common+[str(ROOT/"src/pilot_worker.jl")]+arguments,deadline=deadline)


def native_pid_matches(result,launcher_pid,decomposition):
    # Windows venv python.exe can be a synchronous launcher for its base
    # interpreter. Accept exactly that observed parent relationship for the
    # Python coordinator, not an arbitrary different PID or a Julia worker.
    return result.get("pid")==launcher_pid or (
        decomposition=="source_reserve_benders_v1"
        and result.get("coordinator_parent_pid")==launcher_pid
        and result.get("storage",{}).get("decomposition_policy")==decomposition)


def compact_stage(common,spool,output,deadline,memory_floor_gib=2):
    pid,code,wall=launch_stage(common+[str(ROOT/"src/compact_scheduling_worker.jl"),str(spool),
        str(output),str(deadline)],deadline=deadline,log_path=output/"compaction_console.log",
        memory_path=output/"compaction_memory.jsonl",progress_path=output/"progress",
        memory_floor_bytes=int(memory_floor_gib*GIB))
    proof=output/"compact_spool/proof_verification.json"
    checked=json.loads(proof.read_text())
    if not checked["pass"] or not checked["complete"]:
        raise RuntimeError("Exact compaction proof incomplete or failed")
    atomic_json(output/"compaction_exit.json",{"pid":pid,"returncode":code,
        "process_wall_seconds":wall,"exited_before_native_launch":True,"proof_sha256":sha256(proof)},exclusive=True)


def reserve_partition_stage(common,spool,output,deadline,memory_floor_gib=2):
    directory=output/"reserve_decomposition"
    if directory.exists():
        raise FileExistsError("Reserve partition already exists; cannot reuse another attempt")
    directory.mkdir()
    pid,code,wall=launch_stage(common+[str(ROOT/"src/partition_reserves_worker.jl"),str(spool),
        str(output/"compact_spool"),str(directory),str(deadline)],deadline=deadline,
        log_path=directory/"partition_console.log",memory_path=directory/"partition_memory.jsonl",
        progress_path=directory/"progress",memory_floor_bytes=int(memory_floor_gib*GIB))
    proof=directory/"reserve_partition/proof_verification.json"
    checked=json.loads(proof.read_text())
    if (not checked["pass"] or not checked["complete"] or
            checked["partition_manifest_sha256"]!=sha256(directory/"reserve_partition/manifest.json")):
        raise RuntimeError("Source reserve partition proof incomplete or failed")
    atomic_json(output/"reserve_partition_exit.json",{"pid":pid,"returncode":code,
        "process_wall_seconds":wall,"exited_before_native_launch":True,"proof_sha256":sha256(proof)},exclusive=True)


if __name__=="__main__":
    if len(sys.argv)!=6:
        raise SystemExit("julia case output config absolute_work_deadline_epoch required")
    try:
        main(*sys.argv[1:5],float(sys.argv[5]))
    except Exception as exc:
        output=local_path(sys.argv[3]); error=output/"worker_error.json"
        if not error.exists():
            atomic_json(error,{"stage":"disk_worker_orchestration","error":str(exc),
                "resource_stop":getattr(exc,"record",None)},exclusive=True)
        raise
