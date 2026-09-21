"""Tiny-fixture focused check only; no competition-case solve."""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from scripts.run_pilot import JULIA,runtime_environment
from scripts.component_gate import zero_reserve_pipeline_audit
evidence=Path(tempfile.mkdtemp(prefix="focused_ac_zero_reserves_",dir=ROOT/"tmp"))
print(evidence,flush=True)
commands=[
    ("unit",[str(JULIA),"--startup-file=no","--project=.","scripts/test_ac_zero_reserves.jl"]),
    ("python",[sys.executable,"-m","unittest","discover","-s","tests","-v"]),
    ("worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json",str(evidence/"zero_reserve_worker"),"config/tiny_ac_zero_reserves.json"]),
    ("verify",[sys.executable,"scripts/verify_candidate.py","--input","tmp/official_tiny/dc_problem.json",
        "--solution",str(evidence/"zero_reserve_worker/candidate_final.json"),
        "--output",str(evidence/"zero_reserve_verification"),"--seconds","60"]),
]
for name,command in commands:
    started=time.monotonic()
    if name=="worker":command.append(str(time.time()+180))
    with (evidence/(name+".log")).open("w",encoding="utf-8") as log:
        result=subprocess.run(command,cwd=ROOT,env=runtime_environment(),stdout=log,stderr=subprocess.STDOUT,
            timeout=240,creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
    print(json.dumps({"stage":name,"returncode":result.returncode,"seconds":time.monotonic()-started}),flush=True)
    if result.returncode:
        print((evidence/(name+".log")).read_text()[-13000:],flush=True)
        raise SystemExit(result.returncode)
audit=zero_reserve_pipeline_audit(evidence)
print(json.dumps({"pass":True,"certificate":audit["verification"]["certificate"],
    "verified_dual_transfers":audit["verified_dual_transfers"],
    "reductions":[s["reserve_ac"]["zero_reserve_domains"] for s in audit["statistics"]["ac_intervals"]]}),flush=True)
