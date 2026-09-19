"""Memory-bounded dispatch of the pinned official contingency routine.

No upstream file or numerical routine is rewritten. Each invocation retains the
full monitored network and all periods. Only its outage columns are partitioned;
the official caller still computes its global minimum/mean from the full t_k_z.
Use only in the dedicated, single-evaluation verification process.
"""
from contextlib import contextmanager
from copy import copy, deepcopy
import hashlib
import json
from pathlib import Path
import threading
import time

import numpy as np

PINNED_CTG_SHA256 = "0876bc72009fa9c91040ae0442fef1a74f854852b5ca994ecce1b912305d6f00"
_LOCK = threading.Lock()
VIOLATION_FIELDS = tuple(f"viol_{monitor}_{outage}_t_s_max_ctg"
                         for outage in ("acl", "dcl", "xfr") for monitor in ("acl", "xfr"))


def validate_batch_size(size):
    if type(size) is not int or not 1 <= size <= 4096:
        raise ValueError("Official contingency batch size must be an integer in [1, 4096]")


def _tie_key(problem, field, violation):
    _, monitor, outage, *_ = field.split("_")
    idx = violation["idx"]
    return (int(idx[2]), int(getattr(problem, monitor + "_map")[idx[0]]),
            int(getattr(problem, outage + "_map")[idx[1]]))


def _merge_violations(problem, aggregate, batch):
    for field in VIOLATION_FIELDS:
        value = getattr(batch, field)
        if not np.isfinite(value["val"]) or value["val"] < 0:
            raise ValueError("Nonfinite or negative official maximum violation")
        previous = aggregate.get(field)
        if (previous is None or value["val"] > previous["val"]
                or (value["val"] == previous["val"] and value["val"] > 0
                    and _tie_key(problem, field, value) < _tie_key(problem, field, previous))):
            aggregate[field] = deepcopy(value)


def _check_deadline(deadline):
    if deadline is not None and time.perf_counter() >= deadline:
        raise TimeoutError("Official exhaustive contingency batching reached the shared deadline")


def _evaluate_batches(evaluator, original, size, audit, deadline, progress):
    problem = evaluator.problem
    nk, nt = int(problem.num_k), int(problem.num_t)
    if audit["invocations"] != 0:
        raise RuntimeError("Official batching hook invoked more than once")
    audit["invocations"] += 1
    uids = [str(uid) for uid in problem.k_uid]
    if len(uids) != nk or len(set(uids)) != nk:
        raise ValueError("Source contingency identities are not unique and complete")
    if evaluator.t_k_z.shape != (nt, nk):
        raise ValueError("Official full contingency objective shape differs from source")
    # Fail closed if the pinned array schema changes. All other data are shared,
    # including the full-network physics and previously checked base solution.
    vectors = {}
    for name, value in vars(problem).items():
        if not name.startswith("k_") or name == "k_map":
            continue
        if not isinstance(value, np.ndarray) or value.shape != (nk,):
            raise ValueError(f"Unexpected official contingency field: {name}")
        vectors[name] = value
    audit.update({"source_contingencies": nk, "intervals": nt,
                  "required_checks": nk * nt, "completed_checks": 0,
                  "source_uid_sha256": hashlib.sha256(json.dumps(uids, separators=(",", ":")).encode()).hexdigest(),
                  "monitored_ac_branches": int(problem.num_acl + problem.num_xfr),
                  "network_buses": int(problem.num_bus), "source_order_preserved": True})
    evaluator.t_k_z[:] = np.nan
    covered = np.zeros(nk, dtype=np.uint8)
    aggregate = {}
    ranges = [(start, min(start + size, nk)) for start in range(0, nk, size)] or [(0, 0)]
    for start, stop in ranges:
        _check_deadline(deadline)
        begin = time.perf_counter()
        batch = copy(evaluator)
        batch.problem = copy(problem)
        batch.problem.num_k = stop - start
        for name, value in vectors.items():
            setattr(batch.problem, name, value[start:stop].copy())
        batch.problem.k_map = {str(uid): i for i, uid in enumerate(batch.problem.k_uid)}
        batch.t_k_z = np.full((nt, stop - start), np.nan, dtype=np.float64)
        original(batch)
        _check_deadline(deadline)
        if batch.t_k_z.shape != (nt, stop - start) or not np.isfinite(batch.t_k_z).all():
            raise ValueError("Incomplete or nonfinite official batch penalties")
        _merge_violations(problem, aggregate, batch)
        evaluator.t_k_z[:, start:stop] = batch.t_k_z
        covered[start:stop] += 1
        audit["batches"].append({"start_inclusive": start, "stop_exclusive": stop,
            "checks": nt * (stop - start), "seconds": time.perf_counter() - begin})
        audit["completed_checks"] += nt * (stop - start)
        print("OFFICIAL_CONTINGENCY_BATCH " + json.dumps(audit["batches"][-1]), flush=True)
        del batch  # no network-by-all-outages factors survive a batch invocation
        if progress:
            progress(audit)
    if not (np.all(covered == 1) and np.isfinite(evaluator.t_k_z).all()
            and audit["completed_checks"] == nk * nt):
        raise ValueError("Official exhaustive contingency coverage incomplete")
    for field, value in aggregate.items():
        setattr(evaluator, field, value)
    audit["complete"] = True
    audit["max_batch_columns"] = max(stop - start for start, stop in ranges)
    if progress:
        progress(audit)


@contextmanager
def official_contingency_batches(size, *, deadline=None, progress=None):
    """Temporarily wrap the pinned hook; always restore it, including on failure.

    The original evaluator checks connectedness for the COMPLETE source set
    before calling this hook. Skipping that hook never yields a complete audit.
    """
    validate_batch_size(size)
    from datautilities import ctgmodel
    source = Path(ctgmodel.__file__)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != PINNED_CTG_SHA256:
        raise ValueError("Official contingency source differs from the audited pinned revision")
    if not _LOCK.acquire(blocking=False):
        raise RuntimeError("Concurrent or nested official batching is unsupported")
    original = ctgmodel.eval_post_contingency_model
    audit = {"policy": "pinned_official_outage_batches_v1", "batch_size": size,
             "complete": False, "invocations": 0, "batches": [],
             "original_source_sha256": digest, "upstream_files_modified": False,
             "all_monitored_branches_retained": True,
             "global_aggregation": "original_evaluator_over_complete_source_order_t_k_z"}
    try:
        def dispatch(evaluator):
            return _evaluate_batches(evaluator, original, size, audit, deadline, progress)
        ctgmodel.eval_post_contingency_model = dispatch
        yield audit
    finally:
        ctgmodel.eval_post_contingency_model = original
        _LOCK.release()
        if progress:
            progress(audit)
