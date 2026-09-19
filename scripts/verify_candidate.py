"""Independent and official exhaustive evaluation, as a cancellable process."""
import argparse
import contextlib
import gzip
import json
from pathlib import Path
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from go3cpu.contract import load_case
from go3cpu.controller import atomic_json, sha256
from go3cpu.official import configure_imports, evaluate
from go3cpu.safety import local_path
configure_imports(ROOT)
from go3cpu.independent import check


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input",required=True)
    parser.add_argument("--solution",required=True)
    parser.add_argument("--output",required=True)
    parser.add_argument("--input-sha256")
    parser.add_argument("--seconds",type=float,required=True)
    parser.add_argument("--official-contingency-batch-size",type=int)
    args = parser.parse_args()
    begin = time.perf_counter()
    output = local_path(args.output)
    output.mkdir(parents=True,exist_ok=True)
    record = {"pass":False,"complete":False,"candidate_sha256":sha256(args.solution)}
    try:
        case,digest = load_case(args.input,args.input_sha256)
        sol = json.loads(local_path(args.solution).read_text(encoding="utf-8"))
        record["input_sha256"] = digest
        with gzip.open(output/"contingency_violations.jsonl.gz","wt",encoding="utf-8") as stream:
            independent = check(case,sol,deadline=begin+args.seconds-2,
                violation_sink=lambda row:stream.write(json.dumps(row)+"\n"))
        atomic_json(output/"independent.json",independent)
        record["independent_seconds"] = time.perf_counter()-begin
        stage = time.perf_counter()
        with (output/"official.log").open("w",encoding="utf-8") as log, contextlib.redirect_stdout(log):
            official = evaluate(local_path(args.input),local_path(args.solution),output/"official",root=ROOT,
                contingency_batch_size=args.official_contingency_batch_size,deadline=begin+args.seconds-2)
        record["official_seconds"] = time.perf_counter()-stage
        ev = official["evaluation"]
        if "contingency_batch_audit" in official:
            record["official_contingency_batch_audit"] = official["contingency_batch_audit"]
            if (not record["official_contingency_batch_audit"]["complete"] or
                    record["official_contingency_batch_audit"]["completed_checks"] != independent["contingencies_required"]):
                raise RuntimeError("Official and independent exhaustive coverage disagree")
        objective = float(ev["z"])
        error = abs(objective-independent["objective"])
        agreement = error <= max(1e-5,1e-9*abs(objective))
        record.update({"complete":independent["complete"],"objective":objective,
            "official_feas":ev["feas"],"official_phys_feas":ev["phys_feas"],
            "independent_hard_pass":independent["hard_constraints_pass"],
            "max_hard_residual":independent["max_hard_residual"],
            "objective_discrepancy":error,"objective_agreement":agreement,
            "contingencies_completed":independent["contingencies_completed"],
            "contingencies_required":independent["contingencies_required"],
            "max_p_imbalance_pu":independent["max_p_imbalance_pu"],
            "max_q_imbalance_pu":independent["max_q_imbalance_pu"],
            "max_contingency_overload_pu":independent["max_contingency_overload_pu"],
            "costs_total":independent["costs_total"],
            "verification_directory":str(output)})
        record["pass"] = bool(record["complete"] and ev["feas"]==1 and independent["hard_constraints_pass"] and agreement)
    except Exception:
        record["error"] = traceback.format_exc()
    record["total_verification_seconds"] = time.perf_counter()-begin
    atomic_json(output/"certificate.json",record)
    print(json.dumps(record,indent=2))
    return 0 if record["pass"] else 2


if __name__ == "__main__":
    sys.exit(main())
