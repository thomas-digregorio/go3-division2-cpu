"""Original tiny synthetic cases, not competition inputs or supplied solutions."""

from copy import deepcopy
from go3cpu.contract import RESERVES


def tiny_case(dt=(0.5, 1.0, 0.25)):
    dt = list(dt)
    nt = len(dt)
    buses = [{"uid": f"b{i}", "base_nom_volt": 230.0, "vm_lb": 0.9, "vm_ub": 1.1,
              "active_reserve_uids": ["pr"], "reactive_reserve_uids": ["qr"],
              "initial_status": {"vm": 1.0, "va": 0.0}} for i in range(2)]
    devices, series = [], []
    for uid, typ, bus in (("g", "producer", "b0"), ("d", "consumer", "b1")):
        g = {"uid": uid, "device_type": typ, "bus": bus, "startup_cost": 1.0,
             "shutdown_cost": 0.5, "on_cost": 0.1, "in_service_time_lb": 0.75,
             "down_time_lb": 0.5, "startup_states": [], "startups_ub": [],
             "energy_req_lb": [], "energy_req_ub": [], "q_bound_cap": 0,
             "q_linear_cap": 0, "p_ramp_up_ub": 2.0, "p_ramp_down_ub": 2.0,
             "p_startup_ramp_ub": 2.0, "p_shutdown_ramp_ub": 2.0,
             "initial_status": {"on_status": 1, "p": 1.0, "q": 0.0,
                                "accu_up_time": 1.0, "accu_down_time": 0.0}}
        for key in RESERVES:
            if key.startswith("p_"):
                g[key + "_ub"] = 0.5 if typ == "producer" else 0.0
        devices.append(g)
        s = {"uid": uid, "on_status_lb": [0 if typ == "producer" else 1]*nt,
             "on_status_ub": [1]*nt, "p_lb": [0.2 if typ == "producer" else 1.0]*nt,
             "p_ub": [3.0 if typ == "producer" else 1.0]*nt,
             "q_lb": [-2.0 if typ == "producer" else 0.0]*nt,
             "q_ub": [2.0 if typ == "producer" else 0.0]*nt,
             "cost": [[[10.0 if typ == "producer" else 1000.0, 4.0]] for _ in dt]}
        s.update({key + "_cost": [0.01]*nt for key in RESERVES})
        series.append(s)
    branch = {"uid": "a0", "fr_bus": "b0", "to_bus": "b1", "r": 0.01,
              "x": 0.1, "b": 0.02, "mva_ub_nom": 3.0, "mva_ub_em": 4.0,
              "connection_cost": 0.01, "disconnection_cost": 0.01,
              "additional_shunt": 0, "initial_status": {"on_status": 1}}
    branch2 = deepcopy(branch)
    branch2["uid"] = "a1"
    transformer = deepcopy(branch)
    transformer.update({"uid": "x0", "tm_lb": 0.95, "tm_ub": 1.05,
                        "ta_lb": 0.0, "ta_ub": 0.0,
                        "initial_status": {"on_status": 1, "tm": 1.0, "ta": 0.0}})
    return {"network": {
        "general": {"base_norm_mva": 100.0}, "bus": buses,
        "simple_dispatchable_device": devices, "ac_line": [branch, branch2],
        "two_winding_transformer": [transformer], "dc_line": [],
        "shunt": [{"uid": "sh", "bus": "b1", "gs": 0.0, "bs": 0.1,
                   "step_lb": 0, "step_ub": 2, "initial_status": {"step": 0}}],
        "violation_cost": {"p_bus_vio_cost": 1000.0, "q_bus_vio_cost": 1000.0,
                           "s_vio_cost": 500.0, "e_vio_cost": 1000.0},
        "active_zonal_reserve": [{"uid": "pr", "REG_UP": 0.01, "REG_DOWN": 0.01,
            "SYN": 0.05, "NSYN": 0.05, **{k + "_vio_cost": 100.0 for k in
            ("REG_UP", "REG_DOWN", "SYN", "NSYN", "RAMPING_RESERVE_UP", "RAMPING_RESERVE_DOWN")}}],
        "reactive_zonal_reserve": [{"uid": "qr", "REACT_UP_vio_cost": 100.0,
                                     "REACT_DOWN_vio_cost": 100.0}]},
        "time_series_input": {"general": {"time_periods": nt, "interval_duration": dt},
            "simple_dispatchable_device": series,
            "active_zonal_reserve": [{"uid": "pr", "RAMPING_RESERVE_UP": [0.0]*nt,
                                       "RAMPING_RESERVE_DOWN": [0.0]*nt}],
            "reactive_zonal_reserve": [{"uid": "qr", "REACT_UP": [0.0]*nt, "REACT_DOWN": [0.0]*nt}]},
        "reliability": {"contingency": [{"uid": f"c{i}", "components": [key]}
                                            for i, key in enumerate(("a0", "a1", "x0"))]}}


def tiny_solution(case):
    nt = case["time_series_input"]["general"]["time_periods"]
    out = {"bus": [{"uid": f"b{i}", "vm": [1.0]*nt, "va": [0.0]*nt} for i in range(2)],
           "shunt": [{"uid": "sh", "step": [0]*nt}],
           "ac_line": [{"uid": f"a{i}", "on_status": [1]*nt} for i in range(2)],
           "two_winding_transformer": [{"uid": "x0", "on_status": [1]*nt,
                                         "tm": [1.0]*nt, "ta": [0.0]*nt}],
           "dc_line": [], "simple_dispatchable_device": []}
    for uid in ("g", "d"):
        out["simple_dispatchable_device"].append({"uid": uid, "on_status": [1]*nt,
            "p_on": [1.0]*nt, "q": [0.0]*nt, **{key: [0.0]*nt for key in RESERVES}})
    return {"time_series_output": out}


def tiny_consumer_dominance_case():
    """An eligible flexible consumer, for a full independent/official pipeline."""
    case = tiny_case()
    device = next(d for d in case["network"]["simple_dispatchable_device"] if d["uid"] == "d")
    series = next(d for d in case["time_series_input"]["simple_dispatchable_device"] if d["uid"] == "d")
    nt = case["time_series_input"]["general"]["time_periods"]
    device.update({"on_cost": 0.0, "startup_cost": 0.0, "shutdown_cost": 0.0,
                   "in_service_time_lb": 0.0, "down_time_lb": 0.0,
                   "p_ramp_up_ub": 8.0, "p_ramp_down_ub": 8.0,
                   "p_startup_ramp_ub": 8.0, "p_shutdown_ramp_ub": 8.0,
                   "p_ramp_res_down_online_ub": 0.5,
                   "p_ramp_res_down_offline_ub": 0.5})
    series.update({"p_lb": [0.0]*nt, "on_status_lb": [0]*nt,
                   "q_lb": [-1.0]*nt, "q_ub": [1.0]*nt,
                   "p_ramp_res_down_online_cost": [0.01]*nt,
                   "p_ramp_res_down_offline_cost": [0.02]*nt})
    return case


def tiny_source_features_case():
    """Source startup windows and producer P-Q limits, not competition data."""
    case=tiny_consumer_dominance_case()
    for d in case["network"]["simple_dispatchable_device"]:
        d["startups_ub"]=[[0.0,0.5,0],[0.5,1.75,1]]
        if d["device_type"]=="producer":
            d.update(q_bound_cap=1,q_0_lb=-0.3,q_0_ub=0.3,beta_lb=-0.1,beta_ub=0.1)
    return case


def tiny_primal_continuation_case():
    """Vary adjacent-hour demand to force repair of the previous local point."""
    case = tiny_source_features_case()
    consumer = next(d for d in case["time_series_input"]["simple_dispatchable_device"] if d["uid"] == "d")
    consumer["p_ub"] = [1.0, 0.7, 0.9]
    return case
