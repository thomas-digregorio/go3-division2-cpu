"""Cold, sequential GO3 quality campaign; published scores are not solver starts."""
import json
import math
import re

from .controller import sha256
from .safety import local_path

NETWORK_ORDER = ("C3E4N02000D2", "C3E4N04224D2", "C3E4N06049D2",
                 "C3E4N06717D2", "C3E4N08316D2", "C3E4N23643D2")


def registered_budget(config):
    seconds = config.get("total_seconds")
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or not math.isfinite(seconds):
        return False
    if config.get("pilot_id", "").startswith("campaign_"):
        return 0 < seconds <= 7200
    return seconds == 1800


def sixth_best_target(report, *, network, scenario, switching=True):
    """One active, feasible Final Event result per competitor, excluding benchmark."""
    competitors = {}
    rejected = []
    for row in report["records"]:
        reason = None
        try:
            matches = (row["model"] == network and int(float(row["scenario"])) == int(scenario)
                       and int(float(row["SW"])) == int(switching)
                       and int(float(row["Div."])) == 2)
            eligible = (float(row["feas"]) == 1 and float(row["is_active"]) == 1
                        and float(row["evaluation_feas"]) == 1)
            score = float(row["score"])
            objective = float(row["objective"])
            if not matches or not eligible or row["team"] == "ARPA-e Benchmark":
                reason = "unmatched, inactive, infeasible or benchmark"
            elif not math.isfinite(score) or not math.isfinite(objective):
                reason = "nonfinite score/objective"
            elif abs(score - max(objective, 0.0)) > max(1e-5, 1e-9 * abs(score)):
                raise ValueError("Published score does not match the registered feasible scoring rule")
        except (TypeError, KeyError):
            reason = "missing comparison fields"
        if reason:
            rejected.append({"source_row": row.get("source_row"), "reason": reason})
            continue
        team = row["team"]
        if team in competitors:
            raise ValueError(f"Ambiguous duplicate active competitor: {team}")
        competitors[team] = {"team": team, "score": score, "objective": objective,
                             "runtime_seconds": float(row["runtime"]),
                             "source_row": row["source_row"], "uuid": row["uuid"]}
    ranking = sorted(competitors.values(), key=lambda r: (-r["score"], r["team"]))
    if len(ranking) < 6 or ranking[5]["score"] <= 0:
        raise ValueError("Need six unambiguous positive eligible competitor scores")
    sixth = ranking[5]["score"]
    return {"network": network, "scenario": f"{int(scenario):03d}", "division": 2,
            "official_allow_switching": switching, "metric": "sixth_best_eligible_score",
            "relative_shortfall_limit": 0.10, "sixth_best_score": sixth,
            "minimum_score": 0.90 * sixth, "top_six": ranking[:6],
            "eligible_competitors": len(ranking), "rejected": rejected,
            "note": "Comparison with published scores, not a global-optimality certificate."}


def quality_gate(certificate, target, *, pipeline_completed, within_deadline):
    score = None
    objective = certificate.get("objective") if certificate else None
    if isinstance(objective, (float, int)) and math.isfinite(objective):
        score = max(float(objective), 0.0)
    verification = bool(certificate and certificate.get("pass") and certificate.get("complete")
        and certificate.get("official_feas") == 1 and certificate.get("official_phys_feas") == 1
        and certificate.get("independent_hard_pass") and certificate.get("objective_agreement")
        and certificate.get("contingencies_required", 0) > 0
        and certificate.get("contingencies_completed") == certificate.get("contingencies_required"))
    shortfall = None if score is None else max(0.0, (target["sixth_best_score"] - score) / target["sixth_best_score"])
    return {"pass": bool(verification and pipeline_completed and within_deadline
                         and score is not None and score >=
                         (1.0-target["relative_shortfall_limit"])*target["sixth_best_score"]),
            "score": score, "relative_shortfall_from_sixth": shortfall,
            "verification_pass": verification, "pipeline_completed": pipeline_completed,
            "within_deadline": within_deadline, "target": target}


def experiment_exit_code(result, *, total_seconds, budget_seconds):
    """A hard-feasible but low-quality campaign attempt is not campaign success."""
    complete = (bool(result.get("verified_incumbent")) and result.get("pipeline_completed")
                and total_seconds < budget_seconds)
    if "quality_target" in result:
        complete = complete and result.get("quality_gate", {}).get("pass", False)
    return 0 if complete else 2


def campaign_latch(root, config):
    """Explicitly registered attempts only; preceding networks must have verified evidence."""
    root = local_path(root)
    identifier = config["pilot_id"]
    if not re.fullmatch(r"campaign_n\d{5}_s\d{3}_r\d{2}", identifier):
        raise ValueError("Invalid campaign attempt identifier")
    auth = json.loads((root / "manifests/authorization_campaign.json").read_text())
    network = config["network"]
    if (auth["network_order"] != list(NETWORK_ORDER) or network not in NETWORK_ORDER
        or not auth["cold_start_required"] or auth["reference_rank"] != 6
        or auth["relative_shortfall_limit"] != 0.10
        or auth["maximum_end_to_end_seconds"] != 7200 or not registered_budget(config)):
        raise ValueError("Campaign authorization does not match the user request")
    registered = auth["attempts"].get(identifier)
    identity = {k: config[k] for k in ("network", "scenario", "input_sha256")}
    if registered != identity or not config["cold_start"] or config["allow_pop_solution"]:
        raise ValueError("Attempt not explicitly registered, or not cold")
    index = NETWORK_ORDER.index(network)
    for preceding in NETWORK_ORDER[:index]:
        evidence = auth["completed_networks"].get(preceding)
        if not evidence:
            raise ValueError(f"Preceding network has not passed: {preceding}")
        result_path = local_path(root / evidence["result_path"])
        completion_path = local_path(root / evidence["completion_path"])
        if sha256(result_path) != evidence["result_sha256"] or sha256(completion_path) != evidence["completion_sha256"]:
            raise ValueError("Preceding campaign evidence changed")
        result = json.loads(result_path.read_text())
        completion = json.loads(completion_path.read_text())
        certificate = result.get("verified_incumbent")
        gate = quality_gate(certificate, result["quality_target"],
                            pipeline_completed=result["pipeline_completed"],
                            within_deadline=completion["within_local_deadline"])
        if not gate["pass"] or result["preflight"]["config"]["network"] != preceding:
            raise ValueError(f"Preceding network evidence does not pass: {preceding}")
    return root / "runs" / (identifier + "_latch.json")
