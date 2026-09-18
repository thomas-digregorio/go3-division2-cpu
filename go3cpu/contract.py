"""Registered GO3 feature gate and immutable input identity."""

import hashlib
import json
import math
from pathlib import Path

from .safety import local_path

SECTIONS = ("bus", "shunt", "simple_dispatchable_device", "ac_line",
            "dc_line", "two_winding_transformer")
RESERVES = ("p_reg_res_up", "p_reg_res_down", "p_syn_res", "p_nsyn_res",
            "p_ramp_res_up_online", "p_ramp_res_down_online",
            "p_ramp_res_up_offline", "p_ramp_res_down_offline",
            "q_res_up", "q_res_down")


def load_case(path, expected_hash=None):
    raw = local_path(path).read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if expected_hash is not None and digest != expected_hash:
        raise ValueError("Immutable raw-case SHA256 mismatch")
    case = json.loads(raw)
    require_supported(case)
    return case, digest


def require_supported(case):
    n, t = case["network"], case["time_series_input"]
    dt = t["general"]["interval_duration"]
    if len(dt) != t["general"]["time_periods"] or not dt or any(x <= 0 for x in dt):
        raise ValueError("Invalid interval durations")
    for g in n["simple_dispatchable_device"]:
        for feature in ("energy_req_lb", "energy_req_ub", "startup_states"):
            if g[feature]:
                raise NotImplementedError(f"{g['uid']}: {feature} not yet regression-tested")
        for window in g["startups_ub"]:
            if (len(window) != 3 or not all(isinstance(x, (int, float)) and
                    not isinstance(x, bool) and math.isfinite(x) for x in window) or
                not 0 <= window[0] <= window[1] <= sum(dt) + 1e-6 or
                window[2] < 0 or window[2] != int(window[2])):
                raise ValueError(f"{g['uid']}: invalid source startup-count window")
        if g["q_linear_cap"]:
            raise NotImplementedError(f"{g['uid']}: equality P-Q capability is not yet regression-tested")
        if g["q_bound_cap"]:
            if g["q_bound_cap"] != 1 or any(not isinstance(g.get(k),(int,float)) or
                    not math.isfinite(g[k]) for k in ("q_0_lb","q_0_ub","beta_lb","beta_ub")):
                raise ValueError(f"{g['uid']}: invalid source P-Q capability coefficients")
    if n["dc_line"]:
        raise NotImplementedError("DC devices are not yet covered by independent validation")
    for b in n["ac_line"] + n["two_winding_transformer"]:
        if b["additional_shunt"]:
            raise NotImplementedError(f"{b['uid']}: additional branch shunt is not yet supported")
        if b["r"] == 0 and b["x"] == 0:
            raise ValueError("Zero series impedance")
    branch_ids = {x["uid"] for x in n["ac_line"] + n["two_winding_transformer"]}
    ctgs = case["reliability"]["contingency"]
    if len({c["uid"] for c in ctgs}) != len(ctgs):
        raise ValueError("Duplicate contingency identity")
    for c in ctgs:
        if len(c["components"]) != 1 or c["components"][0] not in branch_ids:
            raise NotImplementedError(f"{c['uid']}: require a single source AC branch outage")


def case_manifest(case):
    n = case["network"]
    dt = case["time_series_input"]["general"]["interval_duration"]
    return {"base_mva": n["general"]["base_norm_mva"], "interval_hours": dt,
            "horizon_hours": sum(dt), "interval_count": len(dt),
            "counts": {k: len(v) for k, v in n.items() if isinstance(v, list)},
            "producers": sum(g["device_type"] == "producer" for g in n["simple_dispatchable_device"]),
            "consumers": sum(g["device_type"] == "consumer" for g in n["simple_dispatchable_device"]),
            "contingencies_per_interval": len(case["reliability"]["contingency"]),
            "required_contingency_evaluations": len(dt) * len(case["reliability"]["contingency"])}
