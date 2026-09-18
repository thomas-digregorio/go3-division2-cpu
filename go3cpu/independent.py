"""Independent GO3 checks using complex AC arithmetic and explicit outage LU.

No optimizer state, presolved matrix, or official evaluator arrays are used.
Supported features are deliberately gated by contract.require_supported.
"""

import time
import numpy as np
from scipy import sparse
from scipy.sparse.linalg import splu
from scipy.sparse.csgraph import connected_components

from .contract import RESERVES, SECTIONS, require_supported

HARD_TOL = 1e-8
TIME_TOL = 1e-6


def trajectories(g, ts, u, dt):
    """End-of-interval GO3 startup/shutdown power, including prior state."""
    u = np.asarray(u, dtype=float)
    prev = np.r_[g["initial_status"]["on_status"], u[:-1]]
    su, sd = np.maximum(u-prev, 0), np.maximum(prev-u, 0)
    end = np.cumsum(dt)
    start = np.r_[0.0, end[:-1]]
    psu, psd = np.zeros(len(u)), np.zeros(len(u))
    for event in np.flatnonzero(su > 0.5):
        for k in range(event):
            psu[k] += max(0.0, ts["p_lb"][event] - g["p_startup_ramp_ub"]*(end[event]-end[k]))
    for event in np.flatnonzero(sd > 0.5):
        anchor = g["initial_status"]["p"] if event == 0 else ts["p_lb"][event-1]
        for k in range(event, len(u)):
            psd[k] += max(0.0, anchor - g["p_shutdown_ramp_ub"]*(end[k]-start[event]))
    return su, sd, psu, psd


def startup_window_violations(windows, startups, dt):
    """Counts at interval starts, with the official half-open time convention."""
    starts = np.r_[0.0, np.cumsum(dt)[:-1]]
    return [max(0.0, float(np.sum(np.asarray(startups)[
        (starts >= begin-TIME_TOL) & (starts < end-TIME_TOL)])) - maximum)
        for begin, end, maximum in windows]


def branch_flow(branch, vf, vt, on=1, tm=1.0, ta=0.0):
    y = 1.0 / complex(branch["r"], branch["x"])
    charge = 0.5j * branch["b"]
    tap = np.asarray(tm) * np.exp(1j * np.asarray(ta))
    i_fr = on * ((y+charge) / np.abs(tap)**2 * vf - y / np.conj(tap) * vt)
    i_to = on * ((y+charge) * vt - y / tap * vf)
    return vf * np.conj(i_fr), vt * np.conj(i_to)


def pwl_value(blocks, p, *, consumer=False):
    # Source blocks are unordered offers/bids: cheapest production first,
    # highest consumer marginal benefit first. Never mutate the raw case.
    remaining, cost = float(p), 0.0
    for slope, width in sorted(blocks, key=lambda block: block[0], reverse=consumer):
        take = min(remaining, width)
        cost += slope * take
        remaining -= take
        if remaining <= 0:
            break
    if remaining > HARD_TOL:
        raise ValueError("Dispatch exceeds total source cost block width")
    return cost


def check(case, solution, *, deadline=float("inf"), exhaustive=True, violation_sink=None):
    require_supported(case)
    begin = time.perf_counter()
    n, tsi, out = case["network"], case["time_series_input"], solution["time_series_output"]
    dt = np.array(tsi["general"]["interval_duration"], dtype=float)
    nt, nb = len(dt), len(n["bus"])
    maps = {}
    for section in SECTIONS:
        records = out[section]
        maps[section] = {r["uid"]: r for r in records}
        if len(maps[section]) != len(records) or set(maps[section]) != {r["uid"] for r in n[section]}:
            raise ValueError(f"Missing, duplicate or extra {section} identities")
        for r in records:
            for key, values in r.items():
                if key == "uid":
                    continue
                a = np.asarray(values, dtype=float)
                if a.shape != (nt,) or not np.all(np.isfinite(a)):
                    raise ValueError(f"{r['uid']}/{key}: nonfinite or incorrect interval coverage")
    hard = {}
    def record(name, value):
        arr = np.asarray(value, dtype=float)
        if not np.all(np.isfinite(arr)):
            raise ValueError(f"Nonfinite check: {name}")
        hard[name] = max(hard.get(name, 0.0), float(np.max(arr, initial=0.0)))
    def bound(name, x, lo, hi):
        record(name, np.maximum(np.asarray(lo)-x, np.asarray(x)-hi))
    def discrete(name, x):
        record(name, np.abs(x - np.rint(x)))
    def tick():
        if time.perf_counter() >= deadline:
            raise TimeoutError("Independent exhaustive verification deadline")

    costs = {key: np.zeros(nt) for key in ("production", "demand_benefit", "on", "startup", "shutdown",
        "reserve_awards", "switching", "real_imbalance", "reactive_imbalance", "base_overload", "reserve_shortfall")}
    buses = {b["uid"]: i for i, b in enumerate(n["bus"])}
    voltage = np.empty((nb, nt), complex)
    injection = np.zeros((nb, nt), complex)
    for b in n["bus"]:
        x = maps["bus"][b["uid"]]
        vm = np.asarray(x["vm"])
        bound("voltage", vm, b["vm_lb"], b["vm_ub"])
        voltage[buses[b["uid"]]] = vm * np.exp(1j*np.asarray(x["va"]))
    series = {g["uid"]: g for g in tsi["simple_dispatchable_device"]}
    device_details = []
    p_actual, reserves = {}, {}
    for g in n["simple_dispatchable_device"]:
        tick()
        uid = g["uid"]
        ts, x = series[uid], maps["simple_dispatchable_device"][uid]
        u, p, q = (np.asarray(x[k], dtype=float) for k in ("on_status", "p_on", "q"))
        r = {key: np.asarray(x[key], dtype=float) for key in RESERVES}
        reserves[uid] = r
        discrete("commitment_integrality", u)
        bound("commitment_bounds", u, ts["on_status_lb"], ts["on_status_ub"])
        su, sd, psu, psd = trajectories(g, ts, u, dt)
        record("maximum_startups", startup_window_violations(g["startups_ub"],su,dt))
        actual = p+psu+psd
        p_actual[uid] = actual
        active = ((u > 0.5) | (psu > 0) | (psd > 0)).astype(float)
        bound("conditional_pmin_pmax", p, u*np.asarray(ts["p_lb"]), u*np.asarray(ts["p_ub"]))
        up, down = g["initial_status"]["accu_up_time"], g["initial_status"]["accu_down_time"]
        for t in range(nt):
            if su[t] > 0.5 and down < g["down_time_lb"] - TIME_TOL:
                record("minimum_down_time", 1.0)
            if sd[t] > 0.5 and up < g["in_service_time_lb"] - TIME_TOL:
                record("minimum_up_time", 1.0)
            up = up + dt[t] if u[t] > 0.5 else 0.0
            down = down + dt[t] if u[t] < 0.5 else 0.0
        delta = actual - np.r_[g["initial_status"]["p"], actual[:-1]]
        ru = dt*((u-su)*g["p_ramp_up_ub"] + (1-u+su)*g["p_startup_ramp_ub"])
        rd = dt*(u*g["p_ramp_down_ub"] + (1-u)*g["p_shutdown_ramp_ub"])
        bound("ramping", delta, -rd, ru)
        for key in RESERVES:
            record("reserve_nonnegative", -r[key])
            costs["reserve_awards"] += dt*r[key]*np.asarray(ts[key+"_cost"])
        rgu, rgd, syn, nsyn, up_on, dn_on, up_off, dn_off, qu, qd = (r[key] for key in RESERVES)
        for key, award, status in (
            ("p_reg_res_up", rgu, u), ("p_reg_res_down", rgd, u),
            ("p_syn_res", rgu+syn, u), ("p_nsyn_res", nsyn, 1-u),
            ("p_ramp_res_up_online", rgu+syn+up_on, u),
            ("p_ramp_res_down_online", rgd+dn_on, u),
            ("p_ramp_res_up_offline", nsyn+up_off, 1-u),
            ("p_ramp_res_down_offline", dn_off, 1-u)):
            record("reserve_capability", award-g[key+"_ub"]*status)
        prod = g["device_type"] == "producer"
        hi_award, lo_award = (rgu+syn+up_on, rgd+dn_on) if prod else (rgd+dn_on, rgu+syn+up_on)
        bound("reserve_p_headroom", p, u*np.asarray(ts["p_lb"])+lo_award,
              u*np.asarray(ts["p_ub"])-hi_award)
        record("offline_reserve_headroom", psu+psd+(nsyn+up_off if prod else dn_off)-(1-u)*np.asarray(ts["p_ub"]))
        record("offline_reserve_eligibility", dn_off if prod else nsyn+up_off)
        bound("reactive_reserve_headroom", q, active*np.asarray(ts["q_lb"])+(qd if prod else qu),
              active*np.asarray(ts["q_ub"])-(qu if prod else qd))
        if g["q_bound_cap"]:
            bound("reactive_power_capability", q,
                  g["q_0_lb"]*active+g["beta_lb"]*actual+(qd if prod else qu),
                  g["q_0_ub"]*active+g["beta_ub"]*actual-(qu if prod else qd))
        injection[buses[g["bus"]]] += (1 if prod else -1)*(actual+1j*q)
        costs["on"] += dt*u*g["on_cost"]
        costs["startup"] += su*g["startup_cost"]
        costs["shutdown"] += sd*g["shutdown_cost"]
        costs["production" if prod else "demand_benefit"] += dt*np.array([pwl_value(ts["cost"][t], actual[t], consumer=not prod) for t in range(nt)])
        device_details.append({"uid": uid, "device_type": g["device_type"], "on_status": u.tolist(),
            "startup": su.tolist(), "shutdown": sd.tolist(), "p_su_pu": psu.tolist(), "p_sd_pu": psd.tolist(),
            "p_pu": actual.tolist(), "p_mw": (actual*n["general"]["base_norm_mva"]).tolist(),
            "q_pu": q.tolist(), "q_mvar": (q*n["general"]["base_norm_mva"]).tolist(),
            "reserves_pu": {k: v.tolist() for k,v in r.items()},
            "reserves_mw_or_mvar": {k: (v*n["general"]["base_norm_mva"]).tolist() for k,v in r.items()}})
    for sh in n["shunt"]:
        k = np.asarray(maps["shunt"][sh["uid"]]["step"], dtype=float)
        discrete("shunt_integrality", k)
        bound("shunt_bounds", k, sh["step_lb"], sh["step_ub"])
        b = buses[sh["bus"]]
        injection[b] -= k*np.abs(voltage[b])**2*complex(sh["gs"], -sh["bs"])
    residual = injection.copy()
    branches = n["ac_line"] + n["two_winding_transformer"]
    nl = len(branches)
    phase, status, reactive = np.zeros((nl, nt)), np.empty((nl, nt)), np.empty((nl, nt))
    flow_details = []
    fr, to, coeff = [], [], []
    for j, b in enumerate(branches):
        is_xfr = "tm_lb" in b
        x = maps["two_winding_transformer" if is_xfr else "ac_line"][b["uid"]]
        u = np.asarray(x["on_status"], dtype=float)
        discrete("branch_integrality", u)
        bound("branch_status", u, 0, 1)
        tm = np.asarray(x["tm"]) if is_xfr else 1.0
        ta = np.asarray(x["ta"]) if is_xfr else 0.0
        if is_xfr:
            bound("tap_magnitude", tm, b["tm_lb"], b["tm_ub"])
            bound("phase_shift", ta, b["ta_lb"], b["ta_ub"])
        f, t = buses[b["fr_bus"]], buses[b["to_bus"]]
        sf, st = branch_flow(b, voltage[f], voltage[t], u, tm, ta)
        residual[f] -= sf
        residual[t] -= st
        fr.append(f); to.append(t)
        coeff.append(-complex(1.0/complex(b["r"], b["x"])).imag)
        phase[j], status[j] = ta, u
        reactive[j] = np.maximum(np.abs(sf.imag), np.abs(st.imag))
        over = np.maximum(0, np.maximum(np.abs(sf), np.abs(st))-b["mva_ub_nom"])
        costs["base_overload"] += dt*over*n["violation_cost"]["s_vio_cost"]
        change = u-np.r_[b["initial_status"]["on_status"], u[:-1]]
        costs["switching"] += np.maximum(change, 0)*b["connection_cost"]+np.maximum(-change, 0)*b["disconnection_cost"]
        flow_details.append({"uid": b["uid"], "p_fr_pu": sf.real.tolist(), "q_fr_pu": sf.imag.tolist(),
            "p_to_pu": st.real.tolist(), "q_to_pu": st.imag.tolist(), "overload_pu": over.tolist(),
            "p_fr_mw": (sf.real*n["general"]["base_norm_mva"]).tolist(),
            "p_to_mw": (st.real*n["general"]["base_norm_mva"]).tolist(),
            "q_fr_mvar": (sf.imag*n["general"]["base_norm_mva"]).tolist(),
            "q_to_mvar": (st.imag*n["general"]["base_norm_mva"]).tolist()})
    costs["real_imbalance"] = dt*np.abs(residual.real).sum(axis=0)*n["violation_cost"]["p_bus_vio_cost"]
    costs["reactive_imbalance"] = dt*np.abs(residual.imag).sum(axis=0)*n["violation_cost"]["q_bus_vio_cost"]

    reserve_shortfalls = []
    bus_data = {b["uid"]: b for b in n["bus"]}
    for category, membership, tskey in (("active_zonal_reserve", "active_reserve_uids", "active_zonal_reserve"),
                                       ("reactive_zonal_reserve", "reactive_reserve_uids", "reactive_zonal_reserve")):
        zts = {r["uid"]: r for r in tsi[tskey]}
        for z in n[category]:
            devices = [g for g in n["simple_dispatchable_device"] if z["uid"] in bus_data[g["bus"]][membership]]
            total = lambda keys: sum((reserves[g["uid"]][k] for g in devices for k in keys), np.zeros(nt))
            if category == "active_zonal_reserve":
                demand = sum((p_actual[g["uid"]] for g in devices if g["device_type"] == "consumer"), np.zeros(nt))
                largest = np.maximum.reduce([np.zeros(nt)]+[p_actual[g["uid"]] for g in devices if g["device_type"] == "producer"])
                reg = z["REG_UP"]*demand-total(["p_reg_res_up"])
                sync = reg+z["SYN"]*largest-total(["p_syn_res"])
                shortages = {"REG_UP": reg, "REG_DOWN": z["REG_DOWN"]*demand-total(["p_reg_res_down"]),
                    "SYN": sync, "NSYN": sync+z["NSYN"]*largest-total(["p_nsyn_res"]),
                    "RAMPING_RESERVE_UP": np.asarray(zts[z["uid"]]["RAMPING_RESERVE_UP"])-total(["p_ramp_res_up_online", "p_ramp_res_up_offline"]),
                    "RAMPING_RESERVE_DOWN": np.asarray(zts[z["uid"]]["RAMPING_RESERVE_DOWN"])-total(["p_ramp_res_down_online", "p_ramp_res_down_offline"])}
            else:
                shortages = {k: np.asarray(zts[z["uid"]][k])-total([r]) for k,r in
                             (("REACT_UP", "q_res_up"), ("REACT_DOWN", "q_res_down"))}
            for product, value in shortages.items():
                short = np.maximum(value, 0)
                costs["reserve_shortfall"] += dt*short*z[product+"_vio_cost"]
                reserve_shortfalls.append({"zone": z["uid"], "product": product, "shortfall_pu": short.tolist()})

    base_seconds = time.perf_counter()-begin
    # Explicit post-outage refactorization: independent from official SMW evaluator.
    incidence = sparse.csc_matrix((np.r_[np.ones(nl), -np.ones(nl)],
                                  (np.r_[fr, to], np.r_[np.arange(nl), np.arange(nl)])), shape=(nb,nl))
    coeff = np.array(coeff)
    balanced = injection.real-injection.real.mean(axis=0)
    ctgs = case["reliability"]["contingency"]
    penalties = np.zeros((len(ctgs),nt))
    violations = []
    max_ctg, completed = 0.0, 0
    groups = {}
    for t in range(nt):
        groups.setdefault(tuple(status[:,t]), []).append(t)
    branch_index = {b["uid"]: j for j,b in enumerate(branches)}
    for topology, times in groups.items():
        active = np.asarray(topology)
        base_lap = incidence @ sparse.diags(active) @ incidence.T
        if connected_components(base_lap, directed=False, return_labels=False) != 1:
            record("base_connectivity", 1)
        if not exhaustive:
            continue
        for k, ctg in enumerate(ctgs):
            tick()
            j = branch_index[ctg["components"][0]]
            live = active.copy(); live[j] = 0
            lap = incidence @ sparse.diags(live) @ incidence.T
            if connected_components(lap, directed=False, return_labels=False) != 1:
                raise ValueError(f"Disconnected source outage {ctg['uid']}")
            g = coeff*live
            lap = (incidence @ sparse.diags(g) @ incidence.T).tocsc()
            rhs = balanced[:,times] + incidence @ (g[:,None]*phase[:,times])
            theta = np.zeros((nb,len(times)))
            theta[1:] = splu(lap[1:,1:]).solve(rhs[1:])
            flows = g[:,None]*(incidence.T @ theta-phase[:,times])
            record("contingency_linear_residual", np.abs(incidence @ flows-balanced[:,times]))
            rating = np.array([b["mva_ub_em"] for b in branches])[:,None]
            over = np.maximum(np.hypot(flows, reactive[:,times])-rating, 0)
            over[live == 0] = 0
            penalties[k,times] = over.sum(axis=0)*dt[times]*n["violation_cost"]["s_vio_cost"]
            maximum = over.max(axis=0)
            max_ctg = max(max_ctg,float(maximum.max(initial=0)))
            violations.append({"uid": ctg["uid"], "outaged_component": ctg["components"][0],
                "intervals_zero_based": times, "maximum_overload_pu": maximum.tolist(),
                "sum_overload_pu": over.sum(axis=0).tolist(), "penalty": penalties[k,times].tolist()})
            if violation_sink is not None:
                for branch, ti in np.argwhere(over > 0):
                    violation_sink({"contingency": ctg["uid"], "branch": branches[branch]["uid"],
                                    "interval": times[ti], "overload_pu": float(over[branch,ti])})
            completed += len(times)
    costs["contingency_worst"] = penalties.max(axis=0) if len(ctgs) else np.zeros(nt)
    costs["contingency_average"] = penalties.mean(axis=0) if len(ctgs) else np.zeros(nt)
    objective = 2*costs["demand_benefit"]-sum(costs.values())
    required = len(ctgs)*nt
    return {"schema_version": 1, "complete": completed == required,
        "hard_constraints_pass": max(hard.values(), default=0) <= HARD_TOL,
        "max_hard_residual": max(hard.values(), default=0), "hard_residuals": hard,
        "max_p_imbalance_pu": float(np.abs(residual.real).max()),
        "max_q_imbalance_pu": float(np.abs(residual.imag).max()),
        "max_contingency_overload_pu": max_ctg, "contingencies_completed": completed,
        "contingencies_required": required, "objective": float(objective.sum()) if exhaustive else None,
        "objective_by_interval": objective.tolist() if exhaustive else None,
        "costs_by_interval": {k: v.tolist() for k,v in costs.items()},
        "costs_total": {k: float(v.sum()) for k,v in costs.items()},
        "base_mva": n["general"]["base_norm_mva"], "interval_hours": dt.tolist(),
        "devices": device_details, "branch_flows": flow_details,
        "reserve_shortfalls": reserve_shortfalls, "contingencies": violations,
        "timing": {"base_and_temporal": base_seconds,
                   "exhaustive_contingencies": time.perf_counter()-begin-base_seconds}}
