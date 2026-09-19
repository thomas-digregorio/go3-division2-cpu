"""Focused DC feature gate on original two-bus fixtures, never a full case.

This records a component milestone, not the complete preflight test manifest.
The full component gate also includes every DC test and integration below.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT/"scripts")]
from component_gate import dc_pipeline_audit, bounded_reserve_pipeline_audit
from go3cpu.controller import atomic_json, sha256
from go3cpu.provenance import source_hashes
from run_pilot import JULIA, runtime_environment, runtime_identity


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bounded-reserves",action="store_true",
                        help="Also verify the storage-only reserve wrapper, using the same tiny DC case")
    args=parser.parse_args()
    env = runtime_environment()
    prefix="reserve_feature_gate_" if args.bounded_reserves else "dc_feature_gate_"
    evidence = Path(tempfile.mkdtemp(prefix=prefix, dir=ROOT/"tmp"))
    print("DC_FEATURE_EVIDENCE " + str(evidence), flush=True)
    tested_sources = source_hashes(ROOT)
    stages = []

    def stage(name, command, timeout=120):
        begin = time.perf_counter()
        log_path = evidence/(name+".log")
        with log_path.open("w", encoding="utf-8") as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                stderr=subprocess.STDOUT, timeout=timeout,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        entry = dict(name=name, returncode=result.returncode,
                     seconds=time.perf_counter()-begin, log_sha256=sha256(log_path))
        stages.append(entry)
        print(json.dumps(entry), flush=True)
        if result.returncode:
            raise RuntimeError(f"Focused tiny DC stage failed: {name}; see {log_path}")

    stage("official_fixture", [sys.executable, "scripts/test_official_adapter.py"])
    stage("python_tests", [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"])
    stage("dc_device_tests", [str(JULIA), "--startup-file=no", "--project=.", "scripts/test_dc_devices.jl"])
    if args.bounded_reserves:
        stage("reserve_storage_tests", [str(JULIA), "--startup-file=no", "--project=.", "scripts/test_reserve_storage.jl"])
    config="config/tiny_reserve_bounded.json" if args.bounded_reserves else "config/tiny_ac_exact_ramp.json"
    stage("tiny_dc_worker", [str(JULIA), "--startup-file=no", "--project=.", "src/pilot_worker.jl",
        "tmp/official_tiny/dc_problem.json", str(evidence/"dc_worker"),
        config, str(time.time()+120)], timeout=125)
    stage("tiny_dc_check", [sys.executable, "scripts/verify_candidate.py",
        "--input", "tmp/official_tiny/dc_problem.json",
        "--solution", str(evidence/"dc_worker/candidate_final.json"),
        "--output", str(evidence/"dc_verification"), "--seconds", "60"])
    audit = dc_pipeline_audit(evidence)
    reserve_audit=bounded_reserve_pipeline_audit(evidence,"dc_worker") if args.bounded_reserves else None
    if source_hashes(ROOT) != tested_sources:
        raise RuntimeError("Sources changed during the DC feature gate")
    record = dict(schema_version=1, passed=True, evidence_directory=str(evidence),
        scope="Original 2-bus, 3-interval DC fixture only; not a full-case preflight authorization",
        stages=stages, dc_pipeline=audit, reserve_storage=reserve_audit,
        runtime=runtime_identity(), source_sha256=tested_sources)
    atomic_json(evidence/"result.json", record)
    print(json.dumps({"passed": True, "evidence_directory": str(evidence),
                      "certificate": audit["certificate"]}), flush=True)


if __name__ == "__main__":
    main()
