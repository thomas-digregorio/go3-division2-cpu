"""Single cold attempt, two sequential processes. The builder never optimizes.

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
from go3cpu.controller import atomic_json, sha256, stop_process
from go3cpu.safety import local_path, storage_check, GIB


def launch_stage(command, *, deadline, log_path=None):
    if time.time()>=deadline:
        raise TimeoutError("Work deadline exhausted before process launch")
    stream=local_path(log_path).open("w",encoding="utf-8") if log_path else None
    process=None
    started=time.perf_counter()
    try:
        process=subprocess.Popen(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
        code=process.wait(timeout=max(0.001,deadline-time.time()))
        if code:
            raise RuntimeError(f"Scheduling worker stage failed: {Path(command[3]).name}; exit={code}")
        return process.pid,code,time.perf_counter()-started
    finally:
        if process is not None:
            stop_process(process)
        if stream:
            stream.close()


def main(julia,case,output,config_path,deadline):
    julia,case,output,config_path=map(local_path,(julia,case,output,config_path))
    config=json.loads(config_path.read_text())
    if config.get("scheduling_storage_policy")!="disk_backed_native_v1":
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
    launch_stage(common+[str(ROOT/"src/pilot_worker.jl")]+arguments,deadline=deadline)


if __name__=="__main__":
    if len(sys.argv)!=6:
        raise SystemExit("julia case output config absolute_work_deadline_epoch required")
    try:
        main(*sys.argv[1:5],float(sys.argv[5]))
    except Exception as exc:
        output=local_path(sys.argv[3]); error=output/"worker_error.json"
        if not error.exists():
            atomic_json(error,{"stage":"disk_worker_orchestration","error":str(exc)},exclusive=True)
        raise
