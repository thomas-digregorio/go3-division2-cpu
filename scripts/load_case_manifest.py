"""Validate raw input in an exited process; return only its compact manifest."""
import json
from pathlib import Path
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from go3cpu.contract import load_case, case_manifest
from go3cpu.controller import atomic_json


def main(case_path, expected_hash, output):
    started=time.perf_counter()
    case,digest=load_case(case_path,expected_hash)
    atomic_json(output,{"input_sha256":digest,"manifest":case_manifest(case),
        "seconds":time.perf_counter()-started},exclusive=True)


if __name__=="__main__":
    main(*sys.argv[1:])
