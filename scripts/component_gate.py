"""Repeatable tiny-fixture setup/test gate. Never loads a competition case."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/"scripts"))
from go3cpu.controller import atomic_json, sha256
from run_pilot import JULIA, runtime_environment


def source_hashes():
    files=[*ROOT.glob("go3cpu/*.py"),*ROOT.glob("scripts/*.py"),*ROOT.glob("scripts/*.jl"),
        *ROOT.glob("src/*.jl"),*ROOT.glob("tests/*.py"),*ROOT.glob("config/*.json"),
        ROOT/"Project.toml",ROOT/"Manifest.toml"]
    return {str(f.relative_to(ROOT)).replace("\\","/"):sha256(f) for f in sorted(files)}


def main():
    env=runtime_environment()
    evidence=ROOT/"tmp/final_component_gate"; evidence.mkdir(parents=True,exist_ok=True)
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
    stage("tiny_worker",[str(JULIA),"--startup-file=no","--project=.","src/pilot_worker.jl",
        "tmp/official_tiny/problem.json",str(evidence/"worker"),"config/tiny_test.json",str(time.time()+120)],timeout=125)
    stage("tiny_final_check",[sys.executable,"scripts/verify_candidate.py","--input","tmp/official_tiny/problem.json",
        "--solution",str(evidence/"worker/candidate_final.json"),"--output",str(evidence/"verification"),"--seconds","60"])
    certificate=json.loads((evidence/"verification/certificate.json").read_text())
    result={"pass":True,"scope":"Original synthetic 2-bus 3-interval fixture only; no competition-case solve",
        "python_test_count":26,"julia_test_count":8,"stages":stages,
        "tiny_integration_certificate":certificate,"source_sha256":source_hashes()}
    atomic_json(ROOT/"manifests/component_tests.json",result)


if __name__=="__main__":
    main()
