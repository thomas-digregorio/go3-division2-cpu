"""Tiny synthetic schema/evaluator integration smoke test, never the pilot case."""
import contextlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "tests")]
from fixtures import (tiny_case, tiny_solution, tiny_consumer_dominance_case,
                      tiny_source_features_case, tiny_primal_continuation_case, tiny_dc_case)
from go3cpu.official import evaluate

out = ROOT / "tmp/official_tiny"
out.mkdir(parents=True, exist_ok=True)
case = tiny_case()
problem, solution = out / "problem.json", out / "solution.json"
problem.write_text(json.dumps(case), encoding="utf-8")
solution.write_text(json.dumps(tiny_solution(case)), encoding="utf-8")
(out / "dominance_problem.json").write_text(
    json.dumps(tiny_consumer_dominance_case()), encoding="utf-8")
(out / "source_features_problem.json").write_text(
    json.dumps(tiny_source_features_case()), encoding="utf-8")
(out / "primal_continuation_problem.json").write_text(
    json.dumps(tiny_primal_continuation_case()), encoding="utf-8")
(out / "dc_problem.json").write_text(json.dumps(tiny_dc_case()), encoding="utf-8")
with (out / "official.log").open("w", encoding="utf-8") as log, contextlib.redirect_stdout(log):
    summary = evaluate(problem, solution, out / "evaluation", root=ROOT)
print(json.dumps({"feas": summary["evaluation"]["feas"],
                  "obj": summary["evaluation"]["z"], "log": str(out / "official.log")}))
