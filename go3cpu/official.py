"""Unmodified pinned evaluator adapter. No commercial optimization is invoked."""

from pathlib import Path
from contextlib import nullcontext
import sys


def configure_imports(root):
    root = Path(root).resolve()
    for p in (root / ".cache/pydeps", root / ".cache/upstream/GO-3-data-model",
              root / ".cache/upstream/C3DataUtilities"):
        sys.path.insert(0, str(p))


def evaluate(problem_path, solution_path, output, *, root, allow_switching=True,
             contingency_batch_size=None, deadline=None):
    configure_imports(root)
    from datautilities import validation
    import json
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    config = Path(root) / ".cache/upstream/C3DataUtilities/config.json"
    parameters = {"do_opt_solves": False, "use_cost_defaults": False,
                  "acl_switch_up_allowed": allow_switching,
                  "acl_switch_dn_allowed": allow_switching,
                  "xfr_switch_up_allowed": allow_switching,
                  "xfr_switch_dn_allowed": allow_switching}
    from .controller import atomic_json
    from .official_batching import official_contingency_batches
    context = (nullcontext(None) if contingency_batch_size is None else
               official_contingency_batches(contingency_batch_size, deadline=deadline,
                   progress=lambda audit: atomic_json(output / "contingency_batch_audit.json", audit)))
    with context as audit:
        result = validation.check_data(str(problem_path), str(solution_path), str(config),
                                 None, json.dumps(parameters), str(output / "summary.csv"),
                                 str(output / "summary.json"), str(output / "data_errors.txt"),
                                 str(output / "ignored_errors.txt"), str(output / "solution_errors.txt"),
                                 None)
    if audit is not None:
        result["contingency_batch_audit"] = audit
        if not audit["complete"]:
            raise RuntimeError("Official exhaustive batched evaluation did not complete")
    return result
