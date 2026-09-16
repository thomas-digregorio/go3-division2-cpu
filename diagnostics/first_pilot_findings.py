"""Post-run diagnosis only: tiny regressions and saved-evidence extraction.

Never launches an optimizer, loads a POP, changes the frozen algorithm, or
re-evaluates a competition-case solution. The original run/certificates stay intact.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT)); sys.path.insert(0,str(ROOT/"tests"))
from fixtures import tiny_case, tiny_solution
from test_contract_physics import OfficialCrossChecks
from go3cpu.independent import check
from go3cpu.controller import atomic_json, sha256


def main():
    case=tiny_case(); solution=tiny_solution(case)
    demand=case["time_series_input"]["simple_dispatchable_device"][1]
    demand["cost"]=[[[100.0,0.5],[1000.0,1.0]] for _ in range(3)]
    with contextlib.redirect_stdout(io.StringIO()):
        independent=check(case,solution)
        official=OfficialCrossChecks().official(case,solution)
    delta=official.get_obj()-independent["objective"]
    assert abs(delta-787.5)<1e-8
    finding={"diagnostic_only":True,"solver_or_evaluator_changed":False,
        "tiny_consumer_block_test":{"blocks":[[100.0,0.5],[1000.0,1.0]],"dispatch_pu":1.0,
            "interval_hours":[0.5,1.0,0.25],"correct_benefit_per_hour":1000.0,
            "frozen_check_benefit_per_hour":550.0,"total_objective_discrepancy":delta,
            "known_checker_bug_reproduced":True},
        "windows_lock_test":None}
    # A generated throwaway fixture tests Windows file-sharing behavior, not ACL bypass.
    with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
        old=Path(directory)/"status.json"; pending=Path(directory)/"status.pending"
        old.write_text("old"); pending.write_text("new")
        with old.open("r"):
            try:
                os.replace(pending,old)
                finding["windows_lock_test"]={"replacement_blocked":False}
            except PermissionError as error:
                finding["windows_lock_test"]={"replacement_blocked":True,"winerror":error.winerror,
                    "error":str(error),"same_error_class_as_pilot":error.winerror==5}
    run=Path(json.loads((ROOT/"runs/pilot_latch.json").read_text())["run"])
    result=json.loads((run/"result.json").read_text())
    stats=json.loads((run/"worker/solver_statistics.json").read_text())
    cert=json.loads((run/"verification/schedule/certificate.json").read_text())
    saved_official=json.loads((run/"verification/schedule/official/summary.json").read_text())["evaluation"]
    finding["pilot_demand_benefit_difference"]=saved_official["z_value"]-cert["costs_total"]["demand_benefit"]
    finding["pilot_objective_discrepancy"]=cert["objective_discrepancy"]
    raw=json.loads((ROOT/result["preflight"]["config"]["input_path"]).read_text())
    companion=json.loads((run/"verification/schedule/independent.json").read_text())
    finding["scheduling_configuration_risk"]={
        "setting":"relax_balances=true in pinned LANL copperplate helper",
        "upstream_code":"src/scheduling_model.jl:1310-1323",
        "source_penalties":raw["network"]["violation_cost"],
        "helper_balance_penalty_field":"e_vio_cost",
        "hour_5_generation_mw":sum(g["p_mw"][4] for g in companion["devices"] if g["device_type"]=="producer"),
        "hour_5_consumption_mw":sum(g["p_mw"][4] for g in companion["devices"] if g["device_type"]=="consumer"),
        "conclusion":"Candidate construction underprices imbalance; this subproblem objective/gap does not certify full GO3 quality."}
    finding["finding_scope"]="Saved initial-candidate objective components plus tiny counterexamples; not a new full evaluation or replacement run."
    output=ROOT/"evidence/pilot_001"; output.mkdir(parents=True,exist_ok=True)
    atomic_json(output/"diagnosis.json",finding)
    for relative,name in (("result.json","result.json"),("completion.json","completion.json"),
            ("worker/solver_statistics.json","solver_statistics.json"),
            ("verification/schedule/certificate.json","initial_candidate_certificate.json")):
        data=json.loads((run/relative).read_text())
        atomic_json(output/name,data)
    evidence={"implementation_commit":result["preflight"]["commit"],"retained_run":str(run),
        "initial_candidate_note":"Official hard-feasible but NOT accepted by project objective-agreement gate",
        "partial_candidate_note":"Last serialized AC checkpoint; NOT finally verified; do not call it a passed result",
        "raw_objective_initial_candidate":cert["objective"],"computed_rule_score_initial_candidate":max(0.0,cert["objective"]),
        "no_final_verified_objective":True,"source_files":{str(p.relative_to(run)).replace("\\","/"):
            {"bytes":p.stat().st_size,"sha256":sha256(p)} for p in sorted(run.rglob("*")) if p.is_file()},
        "ac_intervals_finished":len(stats["ac_intervals"]),
        "ac_completed_interval_wall_seconds":sum(a["wall_seconds"] for a in stats["ac_intervals"]),
        "ac_final_solve_iterations":sum(a["barrier_iterations"] for a in stats["ac_intervals"])}
    atomic_json(output/"retained_manifest.json",evidence)
    print(json.dumps(finding,indent=2))


if __name__=="__main__":
    main()
