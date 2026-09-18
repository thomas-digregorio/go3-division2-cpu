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
from run_pilot import JULIA, runtime_environment, runtime_identity


def source_hashes():
    files=[*ROOT.glob("go3cpu/*.py"),*ROOT.glob("scripts/*.py"),*ROOT.glob("scripts/*.jl"),
        *ROOT.glob("src/*.jl"),*ROOT.glob("tests/*.py"),*ROOT.glob("config/*.json"),
        *ROOT.glob("manifests/authorization_*.json"),*ROOT.glob("manifests/campaign/*.json"),
        ROOT/"Project.toml",ROOT/"Manifest.toml"]
    return {str(f.relative_to(ROOT)).replace("\\","/"):sha256(f) for f in sorted(files)}


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
    python_count=int(re.search(r"Ran (\d+) tests",(evidence/"python_tests.log").read_text()).group(1))
    julia_counts=re.findall(r"^GO3[^\n]*\|\s+(\d+)\s+(\d+)\s+",(evidence/"julia_tests.log").read_text(),re.MULTILINE)
    if not julia_counts or any(a!=b for a,b in julia_counts):
        raise RuntimeError("Julia test summaries missing or not all passed")
    result={"pass":True,"scope":"Original synthetic 2-bus 3-interval fixture only; no competition-case solve",
        "runtime":runtime_identity(),
        "python_test_count":python_count,"julia_test_count":sum(int(a) for a,b in julia_counts),"stages":stages,
        "evidence_directory":str(evidence),
        "tiny_integration_certificate":certificate,
        "tiny_separated_reserves_certificate":separated_certificate,
        "tiny_hipo_certificate":hipo_certificate,"source_sha256":source_hashes()}
    atomic_json(ROOT/"manifests/component_tests.json",result)


if __name__=="__main__":
    main()
