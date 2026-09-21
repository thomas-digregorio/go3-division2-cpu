"""Read-only first-hour physical diagnostic. Never a solve or certificate."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.run_pilot import psutil, runtime_environment
from go3cpu.safety import local_path


def diagnose():
    import numpy as np
    from go3cpu.contract import SECTIONS, load_case
    from go3cpu.independent import branch_flow, trajectories

    started = time.monotonic()
    cfg = json.loads((ROOT / "config/campaign_n23643_s003_r15.json").read_text())
    manifest = json.loads((ROOT / "evidence/campaign/campaign_n23643_s003_r14/retained_manifest.json").read_text())
    relative = "worker/checkpoints/candidate_ac_0001.json"
    checkpoint = local_path(Path(manifest["retained_run"]) / relative)
    raw = checkpoint.read_bytes()
    checkpoint_hash = hashlib.sha256(raw).hexdigest()
    assert checkpoint_hash == manifest["source_files"][relative]["sha256"]
    solution = json.loads(raw)
    del raw
    case, source_hash = load_case(ROOT / cfg["input_path"], cfg["input_sha256"])
    n, tsi, out = case["network"], case["time_series_input"], solution["time_series_output"]
    dt = np.asarray(tsi["general"]["interval_duration"], dtype=np.float64)
    nt = len(dt)
    maps = {}
    for section in SECTIONS:
        records = out[section]
        maps[section] = {r["uid"]: r for r in records}
        assert len(maps[section]) == len(records)
        assert set(maps[section]) == {r["uid"] for r in n[section]}
        for r in records:
            for key, values in r.items():
                if key != "uid":
                    a = np.asarray(values, dtype=np.float64)
                    assert a.shape == (nt,) and np.all(np.isfinite(a)), (r["uid"], key)
    buses = {b["uid"]: i for i, b in enumerate(n["bus"])}
    voltage = np.empty(len(buses), dtype=np.complex128)
    residual = np.zeros(len(buses), dtype=np.complex128)
    bound_residuals = {}

    def bound(category, uid, value, lower, upper):
        violation = max(0.0, float(lower - value), float(value - upper))
        if violation > bound_residuals.get(category, {}).get("violation", -1.0):
            bound_residuals[category] = {"uid": uid, "violation": violation}

    for b in n["bus"]:
        x = maps["bus"][b["uid"]]
        vm, va = x["vm"][0], x["va"][0]
        voltage[buses[b["uid"]]] = vm * np.exp(1j * va)
        bound("voltage", b["uid"], vm, b["vm_lb"], b["vm_ub"])
    series = {g["uid"]: g for g in tsi["simple_dispatchable_device"]}
    counts = {"producer": {"source": 0, "on": 0}, "consumer": {"source": 0, "on": 0}}
    for g in n["simple_dispatchable_device"]:
        uid = g["uid"]
        x, ts = maps["simple_dispatchable_device"][uid], series[uid]
        u = np.asarray(x["on_status"], dtype=np.float64)
        _, _, psu, psd = trajectories(g, ts, u, dt)
        actual_p = x["p_on"][0] + psu[0] + psd[0]
        q = x["q"][0]
        prod = g["device_type"] == "producer"
        residual[buses[g["bus"]]] += (1 if prod else -1) * complex(actual_p, q)
        bound("conditional_pmin_pmax", uid, x["p_on"][0], u[0]*ts["p_lb"][0], u[0]*ts["p_ub"][0])
        active = float(u[0] > .5 or psu[0] > 0 or psd[0] > 0)
        bound("reactive_box", uid, q, active*ts["q_lb"][0], active*ts["q_ub"][0])
        counts[g["device_type"]]["source"] += 1
        counts[g["device_type"]]["on"] += int(u[0] > .5)
    for sh in n["shunt"]:
        k = maps["shunt"][sh["uid"]]["step"][0]
        b = buses[sh["bus"]]
        residual[b] -= k * abs(voltage[b])**2 * complex(sh["gs"], -sh["bs"])
    for link in n["dc_line"]:
        x = maps["dc_line"][link["uid"]]
        residual[buses[link["fr_bus"]]] -= complex(x["pdc_fr"][0], x["qdc_fr"][0])
        residual[buses[link["to_bus"]]] -= complex(-x["pdc_fr"][0], x["qdc_to"][0])
    overloads = []
    for section in ("ac_line", "two_winding_transformer"):
        for b in n[section]:
            x = maps[section][b["uid"]]
            fr, to = buses[b["fr_bus"]], buses[b["to_bus"]]
            tm = x["tm"][0] if section == "two_winding_transformer" else 1.0
            ta = x["ta"][0] if section == "two_winding_transformer" else 0.0
            sf, st = branch_flow(b, voltage[fr], voltage[to], x["on_status"][0], tm, ta)
            residual[fr] -= sf
            residual[to] -= st
            overloads.append({"uid": b["uid"], "overload_pu": float(max(0.0, max(abs(sf), abs(st))-b["mva_ub_nom"]))})
    base = n["general"]["base_norm_mva"]
    bus_ids = [b["uid"] for b in n["bus"]]

    def largest(values, unit):
        return [{"bus_uid": bus_ids[int(i)], "signed_imbalance_pu": float(values[i]),
                 "signed_imbalance_"+unit: float(values[i]*base)}
                for i in np.argsort(-np.abs(values), kind="stable")[:10]]

    return {
        "diagnostic_only": True, "unverified_checkpoint": str(checkpoint),
        "source_sha256": source_hash, "checkpoint_sha256": checkpoint_hash,
        "intervals_examined": [1], "source_intervals": nt,
        "optimization_calls": 0, "contingency_checks": 0,
        "official_evaluator_calls": 0, "reused_as_solver_start": False,
        "certificate": None, "verified_objective": None,
        "caveat": "Export-projected failed checkpoint, not the raw optimizer iterate. Partial physical diagnostic only; not a feasibility or security certificate. Other 47 intervals not evaluated.",
        "base_mva": base, "commitment_counts": counts,
        "max_p_imbalance_pu": float(np.max(np.abs(residual.real))),
        "max_q_imbalance_pu": float(np.max(np.abs(residual.imag))),
        "sum_abs_p_imbalance_pu": float(np.sum(np.abs(residual.real))),
        "sum_abs_q_imbalance_pu": float(np.sum(np.abs(residual.imag))),
        "top_p_imbalances": largest(residual.real, "mw"),
        "top_q_imbalances": largest(residual.imag, "mvar"),
        "selected_bound_residuals_not_complete": bound_residuals,
        "top_base_overloads_source_soft_limits": [x for x in sorted(overloads, key=lambda x: -x["overload_pu"])[:10] if x["overload_pu"] > 0],
        "diagnostic_seconds": time.monotonic()-started,
    }


if __name__ == "__main__":
    if "--worker" in sys.argv:
        print(json.dumps(diagnose(), indent=2), flush=True)
    else:
        evidence = local_path(Path(tempfile.mkdtemp(prefix="r14_checkpoint_diagnostic_", dir=ROOT/"tmp")))
        print(str(evidence), flush=True)
        started, peak = time.monotonic(), 0
        with (evidence/"diagnostic.json").open("w", encoding="utf-8") as log:
            p = subprocess.Popen([sys.executable, "-u", str(Path(__file__)), "--worker"],
                cwd=ROOT, env=runtime_environment(), stdout=log, stderr=subprocess.STDOUT,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            while p.poll() is None:
                try:
                    owned = [psutil.Process(p.pid), *psutil.Process(p.pid).children(recursive=True)]
                    peak = max(peak, sum(item.memory_info().rss for item in owned))
                except psutil.NoSuchProcess:
                    pass
                if time.monotonic()-started > 120 or psutil.virtual_memory().available < 2*2**30:
                    for child in reversed(psutil.Process(p.pid).children(recursive=True)):
                        child.terminate()
                    p.terminate()
                    p.wait(timeout=10)
                    raise RuntimeError("Read-only diagnostic resource guard reached")
                time.sleep(.5)
        print(json.dumps({"returncode": p.returncode, "peak_rss_gib": peak/2**30,
            "seconds": time.monotonic()-started, "optimization_calls": 0}), flush=True)
        print((evidence/"diagnostic.json").read_text(encoding="utf-8"), flush=True)
        raise SystemExit(p.returncode)
