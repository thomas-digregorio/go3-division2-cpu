"""One explicitly requested bounded diagnostic; never a cold benchmark or AC run.

Reuses an immutable UNSOLVED numerical spool, not a solution, start, or basis.
Results are marked diagnostic and cannot be consumed by the production reader.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/"scripts"))
from run_pilot import JULIA, runtime_environment
from run_disk_worker import launch_stage, compact_stage
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import local_path, storage_check, GIB
from go3cpu.provenance import source_hashes


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--spool",required=True)
    parser.add_argument("--case",required=True)
    parser.add_argument("--config",required=True)
    parser.add_argument("--seconds",type=int,default=90)
    parser.add_argument("--compact",action="store_true")
    args=parser.parse_args()
    if not 10<=args.seconds<=180:
        raise ValueError("Startup diagnostic must be bounded to 10..180 seconds")
    spool,case,config=map(local_path,(args.spool,args.case,args.config))
    storage_check(ROOT,pending_bytes=GIB)
    os.environ.update(runtime_environment())
    output=Path(tempfile.mkdtemp(prefix="native_startup_diagnostic_",dir=ROOT/"tmp"))
    options={"threads":1,"parallel":"off","highs_analysis_level":384}
    if args.compact:
        options["compaction_policy"]="exact_zero_alias_v1"
    atomic_json(output/"options.json",options,exclusive=True)
    atomic_json(output/"registration.json",{"kind":"bounded_native_startup_diagnostic",
        "benchmark":False,"raw_model_rebuilt":False,"raw_case_sha256":sha256(case),
        "spool_manifest_sha256":sha256(spool/"manifest.json"),"config_sha256":sha256(config),
        "implementation_source_sha256":source_hashes(ROOT),
        "seconds":args.seconds,"options_override":options,"starts_supplied":0},exclusive=True)
    print("STARTUP_DIAGNOSTIC "+str(output),flush=True)
    started=time.perf_counter()
    deadline=time.time()+args.seconds
    try:
        if args.compact:
            compact_stage([str(JULIA),"--startup-file=no",f"--project={ROOT}"],spool,output,deadline)
        pid,code,wall=launch_stage([str(JULIA),"--startup-file=no",f"--project={ROOT}",
            str(ROOT/"src/solve_scheduling_native.jl"),str(case),str(output),str(config),
            str(deadline),str(spool),str(output/"options.json")],
            deadline=deadline+5,log_path=output/"console.log",
            memory_path=output/"memory.jsonl",progress_path=output/"progress")
        result={"process_exit":code,"pid":pid,"native_process_wall_seconds":wall,
                "process_wall_seconds":time.perf_counter()-started,"error":None}
    except Exception as exc:
        result={"process_wall_seconds":time.perf_counter()-started,"error":type(exc).__name__+": "+str(exc)}
    atomic_json(output/"completion.json",result,exclusive=True)
    print(json.dumps({"directory":str(output),**result}),flush=True)
    return 1 if result["error"] else 0


if __name__=="__main__":
    sys.exit(main())
