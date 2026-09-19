"""Registered cold speedup iterations; each frozen attempt executes only once."""
import json
import re
from .controller import sha256
from .safety import local_path


def speedup_latch(root, config):
    root = local_path(root)
    match = re.fullmatch(r"speedup_n06049_s003_r([0-9]{2})", str(config.get("pilot_id", "")))
    number = int(match[1]) if match else 0
    filename = f"authorization_speedup_{number:03d}.json" if number > 0 else None
    if filename is None or not (root / "manifests" / filename).is_file():
        raise ValueError("No explicit authorization for this speedup attempt")
    auth = json.loads((root / "manifests" / filename).read_text())
    if number >= 3 and auth.get("ongoing_iteration_authorized") is not True:
        raise ValueError("Iterative speedup registration must record the updated user authorization")
    identity = {k: config[k] for k in ("pilot_id", "network", "scenario", "input_sha256")}
    if (identity != auth["identity"]
            or config["total_seconds"] != auth.get("hard_safety_limit_seconds", 1800)
            or config.get("target_seconds", 1800) != auth.get("target_seconds", 1800)
            or auth["maximum_full_runs"] != 1 or config["maximum_full_runs"] != 1
            or not config["cold_start"] or config["allow_pop_solution"]
            or config["evaluation_reserve_seconds"] < 450
            or config["finalization_reserve_seconds"] < 30
            or config["scheduling_relative_gap"] != 0.001
            or config.get("scheduling_seed_policy", "off") != "off"
            or config["ac_correction_policy"] != auth.get("correction_policy", "network_slp_fixed_shunts_v1")
            or config.get("ac_correction_lp_solver", "simplex") != auth.get("correction_lp_solver", "simplex")
            or config["intermediate_verification"] != "skip_unverified_schedule_v1"):
        raise ValueError("Speedup experiment differs from its single-run authorization")
    baseline = auth["baseline"]
    for key in ("result", "completion", "configuration", "comparison"):
        if sha256(root / baseline[key + "_path"]) != baseline[key + "_sha256"]:
            raise ValueError("Frozen speedup baseline evidence changed: " + key)
    previous = auth.get("previous_attempt")
    if previous:
        for key in ("result", "completion"):
            if sha256(root / previous[key + "_path"]) != previous[key + "_sha256"]:
                raise ValueError("Previous speedup evidence changed: " + key)
    return root / "runs" / (identity["pilot_id"] + "_latch.json")


def runtime_target_status(config, elapsed_seconds):
    target = config.get("target_seconds", config["total_seconds"])
    return {"target_seconds": target, "hard_safety_limit_seconds": config["total_seconds"],
            "within_target": elapsed_seconds <= target,
            "within_hard_limit": elapsed_seconds < config["total_seconds"],
            "target_is_hard_deadline": target == config["total_seconds"]}


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
