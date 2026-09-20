"""Bounded unsolved-matrix partition audit. Never launches a solver experiment."""
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
from run_disk_worker import launch_stage
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import GIB, local_path, storage_check
from go3cpu.provenance import source_hashes


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--original",required=True)
    parser.add_argument("--compact",required=True)
    parser.add_argument("--seconds",type=int,default=600)
    args=parser.parse_args()
    if not 30<=args.seconds<=600:
        raise ValueError("Partition audit must be bounded to 30..600 seconds")
    original,compact=map(local_path,(args.original,args.compact))
    storage_check(ROOT,pending_bytes=4*GIB,floor_bytes=30*GIB)
    os.environ.update(runtime_environment())
    output=Path(tempfile.mkdtemp(prefix="reserve_partition_diagnostic_",dir=ROOT/"tmp"))
    atomic_json(output/"registration.json",{
        "kind":"unsolved_reserve_partition_audit","benchmark":False,"solve_calls":0,
        "reuses_unsolved_matrix_only":True,"raw_model_rebuilt":False,
        "original_manifest_sha256":sha256(original/"manifest.json"),
        "compact_manifest_sha256":sha256(compact/"manifest.json"),
        "implementation_source_sha256":source_hashes(ROOT),"seconds":args.seconds},exclusive=True)
    print("PARTITION_DIAGNOSTIC "+str(output),flush=True)
    started=time.perf_counter();deadline=time.time()+args.seconds
    result={"solve_calls":0,"benchmark":False,"complete":False}
    try:
        pid,code,wall=launch_stage([str(JULIA),"--startup-file=no",f"--project={ROOT}",
            str(ROOT/"src/partition_reserves_worker.jl"),str(original),str(compact),str(output),str(deadline)],
            deadline=deadline,log_path=output/"console.log",memory_path=output/"memory.jsonl",
            progress_path=output/"progress",memory_floor_bytes=2*GIB)
        proof=output/"reserve_partition/proof_verification.json"
        audit=json.loads(proof.read_text())
        if not audit["pass"] or not audit["complete"]:
            raise RuntimeError("Incomplete partition proof")
        result.update(complete=True,pid=pid,process_exit=code,process_wall_seconds=wall,
                      proof_sha256=sha256(proof),error=None)
    except Exception as exc:
        result.update(error=type(exc).__name__+": "+str(exc))
    result["end_to_end_seconds"]=time.perf_counter()-started
    atomic_json(output/"completion.json",result,exclusive=True)
    print(json.dumps({"directory":str(output),**result}),flush=True)
    return 0 if result["complete"] else 1


if __name__=="__main__":
    sys.exit(main())
