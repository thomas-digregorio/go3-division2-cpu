"""The separately approved, single cold 6049-bus speedup experiment."""
import json
from .controller import sha256
from .safety import local_path


def speedup_latch(root, config):
    root = local_path(root)
    auth = json.loads((root / "manifests/authorization_speedup_001.json").read_text())
    identity = {k: config[k] for k in ("pilot_id", "network", "scenario", "input_sha256")}
    if (identity != auth["identity"] or config["total_seconds"] != 1800
            or auth["maximum_full_runs"] != 1 or config["maximum_full_runs"] != 1
            or not config["cold_start"] or config["allow_pop_solution"]
            or config["evaluation_reserve_seconds"] < 450
            or config["finalization_reserve_seconds"] < 30
            or config["scheduling_relative_gap"] != 0.001
            or config.get("scheduling_seed_policy", "off") != "off"
            or config["ac_correction_policy"] != "network_slp_fixed_shunts_v1"
            or config["intermediate_verification"] != "skip_unverified_schedule_v1"):
        raise ValueError("Speedup experiment differs from its single-run authorization")
    baseline = auth["baseline"]
    for key in ("result", "completion", "configuration", "comparison"):
        if sha256(root / baseline[key + "_path"]) != baseline[key + "_sha256"]:
            raise ValueError("Frozen speedup baseline evidence changed: " + key)
    return root / "runs" / (identity["pilot_id"] + "_latch.json")


def skip_intermediate_verification(config):
    policy = config.get("intermediate_verification", "verify")
    if policy not in ("verify", "skip_unverified_schedule_v1"):
        raise ValueError("Unknown intermediate verification policy")
    return policy == "skip_unverified_schedule_v1"


def final_verification_required(config, progress, returncode, statistics, hours):
    if not config.get("pilot_id", "").startswith("speedup_"):
        return True
    from .campaign import pipeline_coverage
    return pipeline_coverage(progress, returncode, statistics, hours)["complete"]
