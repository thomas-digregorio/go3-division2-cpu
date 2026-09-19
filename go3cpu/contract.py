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


def _validate_dc_links(network):
    """Lossless controllable links with the original GO3 terminal domains.

    A DC link is not an AC admittance branch and has no on/off output. Outages
    remain separately restricted to the regression-tested AC contingency set.
    """
    buses = {b["uid"] for b in network["bus"]}
    other_ids = {x["uid"] for section in SECTIONS if section != "dc_line"
                 for x in network[section]}
    seen = set()
    for link in network["dc_line"]:
        uid = link["uid"]
        if uid in seen or uid in other_ids:
            raise ValueError(f"{uid}: duplicate DC device identity")
        seen.add(uid)
        if (link["fr_bus"] not in buses or link["to_bus"] not in buses or
                link["fr_bus"] == link["to_bus"]):
            raise ValueError(f"{uid}: invalid DC terminal buses")
        fields = ("pdc_ub", "qdc_fr_lb", "qdc_fr_ub", "qdc_to_lb", "qdc_to_ub")
        initial_fields = ("pdc_fr", "qdc_fr", "qdc_to")
        initial = link["initial_status"]
        values = [link.get(k) for k in fields] + [initial.get(k) for k in initial_fields]
        if any(not isinstance(v, (int, float)) or isinstance(v, bool) or
               not math.isfinite(v) for v in values):
            raise ValueError(f"{uid}: nonfinite or nonnumeric DC source data")
        if (link["pdc_ub"] < 0 or
                not link["qdc_fr_lb"] <= 0 <= link["qdc_fr_ub"] or
                not link["qdc_to_lb"] <= 0 <= link["qdc_to_ub"]):
            raise ValueError(f"{uid}: invalid DC source bounds")
        limits = (("pdc_fr", -link["pdc_ub"], link["pdc_ub"]),
                  ("qdc_fr", link["qdc_fr_lb"], link["qdc_fr_ub"]),
                  ("qdc_to", link["qdc_to_lb"], link["qdc_to_ub"]))
        for field, lo, hi in limits:
            if not lo <= initial[field] <= hi:
                raise ValueError(f"{uid}: source initial {field} outside original bounds")


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
    _validate_dc_links(n)
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
