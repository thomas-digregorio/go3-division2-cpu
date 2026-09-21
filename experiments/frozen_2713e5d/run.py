"""New authorization/serial queue around the unchanged 2713e5d experiment runner.

No solver, model, screening, acceptance, or numerical settings are overridden.
Only the old experiment-latch lookup is replaced with this user's new, explicit
one-use registration. Existing pilot/campaign latches are never removed/reused.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import traceback

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
ALGORITHM = "2713e5df972f8cae7b77d8963419eba4e1f28424"
ORDER = ["C3E4N00617D2", "C3E4N02000D2", "C3E4N04224D2", "C3E4N06049D2", "C3E4N06717D2"]
MAX_TEMPORARY_PATH = 240
IDENTITY_FIELDS = {"pilot_id", "campaign_order_policy", "network", "scenario",
                   "input_path", "input_sha256", "case_manifest_path", "comparison_manifest_path"}
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
import run_pilot as frozen
from go3cpu.controller import atomic_json, claim_pilot, latest_snapshot, sha256, Snapshots, stop_process
from go3cpu.provenance import assert_tested_sources_unchanged
from go3cpu.campaign import quality_gate
from go3cpu.safety import local_path


def load(path):
    return json.loads(local_path(path).read_text(encoding="utf-8"))


def authorization():
    auth = load(HERE / "authorization.json")
    if (auth["algorithm_commit"] != ALGORITHM or auth["run_order"] != ORDER
            or auth["explicit_user_authorization"] is not True
            or auth["cold_start_required"] is not True
            or auth["stop_on_first_failure"] is not True
            or auth["maximum_full_runs_per_case"] != 1
            or auth["total_seconds_per_case"] != 7200
            or auth.get("output_path_policy") != {
                "policy": "short_paths_legacy_windows_v1",
                "maximum_temporary_path_characters": MAX_TEMPORARY_PATH,
                "registry_changes_required": False}
            or [x["network"] for x in auth["cases"]] != ORDER):
        raise RuntimeError("Frozen regression differs from the user's explicit authorization")
    return auth


def validate_config(config, baseline):
    a = {k: v for k, v in config.items() if k not in IDENTITY_FIELDS}
    b = {k: v for k, v in baseline.items() if k not in IDENTITY_FIELDS}
    if a != b:
        raise RuntimeError("Numerical settings differ from the frozen 8316 r03 configuration")
    if not config["cold_start"] or config["allow_pop_solution"] or config["maximum_full_runs"] != 1:
        raise RuntimeError("Run must be cold and single-use")


def queue_directory(auth):
    return ROOT / "runs" / auth["experiment_id"]


def output_path_audit(config, root=ROOT):
    """Check the unchanged controller's final AND temporary filenames before solve.

    Include its 64-character candidate hash and 32-character atomic-write UUID.
    The 240-character cap leaves headroom below legacy Windows MAX_PATH even
    when long-path support is disabled. This function creates no directories.
    """
    root = local_path(root)
    run_name = f"{config['network']}_s{config['scenario']}_{config['pilot_id']}_20260921T235959Z"
    run = root / "runs" / run_name
    suffix = "." + "0" * 32 + ".pending"
    paths = [
        run / "verified_incumbent" / ("0" * 64) / ("certificate.json" + suffix),
        run / "verified_incumbent" / ("0" * 64) / "solution.json.pending",
        run / "verification_records" / ("final.json" + suffix),
        run / "worker" / "progress" / ("00000001.json" + suffix),
        run / "worker" / "statistics" / "scheduling_events" / ("00000001.json" + suffix),
        run / ("completion.json" + suffix),
    ]
    longest = max(paths, key=lambda p: len(str(p)))
    count = len(str(longest))
    if count > MAX_TEMPORARY_PATH:
        raise RuntimeError(f"Output temporary path has {count} characters; maximum "
                           f"{MAX_TEMPORARY_PATH}. Shorten checkout/run names before launch: {longest}")
    return {"policy": "short_paths_legacy_windows_v1", "run_name_template": run_name,
            "maximum_temporary_path_characters": count,
            "guard_characters": MAX_TEMPORARY_PATH, "longest_path_template": str(longest),
            "requires_windows_long_paths": False}


def validate_frozen_identity():
    historical = json.loads(frozen.git("show", f"{ALGORITHM}:manifests/component_tests.json"))
    # Includes every original Python/Julia model, solver, controller, checker,
    # test, configuration, upstream identity and dependency-lock file.
    assert_tested_sources_unchanged(ROOT, historical["source_sha256"])
    changes = frozen.git("diff", "--name-only", ALGORITHM, "HEAD").splitlines()
    forbidden = [p for p in changes if p != "manifests/component_tests.json"
                 and not p.startswith("experiments/frozen_2713e5d/")]
    if forbidden:
        raise RuntimeError(f"Unexpected changes relative to frozen algorithm: {forbidden}")
    return {"algorithm_commit": ALGORITHM, "registration_commit": frozen.git("rev-parse", "HEAD"),
            "original_tested_source_files": len(historical["source_sha256"]),
            "original_source_hashes_match": True}


def accepted_result(result, completion):
    certificate = result.get("verified_incumbent") or {}
    target = result.get("quality_target")
    if not target:
        return False
    gate = quality_gate(certificate, target,
                        pipeline_completed=result.get("pipeline_completed") is True,
                        within_deadline=completion.get("within_local_deadline") is True)
    seconds = completion.get("elapsed_through_result_serialization_seconds")
    return bool(gate["pass"] and isinstance(seconds, (int, float))
                and math.isfinite(seconds) and 0 < seconds < 7200)


def read_outcome(case, returncode=None):
    latch = ROOT / "runs" / (case["pilot_id"] + "_latch.json")
    row = {"network": case["network"], "scenario": case["scenario"],
           "algorithm_commit": ALGORITHM, "pilot_id": case["pilot_id"],
           "pass": False, "score": None, "end_to_end_seconds": None,
           "child_returncode": returncode}
    if not latch.is_file():
        return {**row, "failure": "Preflight failed before a full run was claimed"}
    run = local_path(load(latch)["run"])
    if run.parent != (ROOT / "runs").resolve():
        raise RuntimeError("Run evidence points outside the isolated runs directory")
    row["run_directory"] = str(run)
    if not (run / "completion.json").is_file() or not (run / "result.json").is_file():
        return {**row, "failure": "Missing complete result/completion evidence"}
    result, completion = load(run / "result.json"), load(run / "completion.json")
    if sha256(run / "result.json") != completion["result_sha256"]:
        raise RuntimeError("Result hash differs from its completion record")
    config = result["preflight"]["config"]
    if (result["preflight"].get("algorithm_commit") != ALGORITHM
            or any(config[k] != case[k] for k in ("pilot_id", "network", "scenario", "input_sha256"))
            or result["preflight"]["config_sha256"] != sha256(ROOT / case["config_path"])):
        raise RuntimeError("Completed result belongs to a different experiment")
    certificate = result.get("verified_incumbent") or {}
    passed = accepted_result(result, completion) and returncode in (None, 0)
    objective = certificate.get("objective")
    row["pass"] = passed
    row.update(status=result["status"], objective=objective,
               score=max(objective, 0.0) if objective is not None else None,
               end_to_end_seconds=completion["elapsed_through_result_serialization_seconds"],
               official_feas=certificate.get("official_feas"),
               official_phys_feas=certificate.get("official_phys_feas"),
               contingencies_completed=certificate.get("contingencies_completed"),
               contingencies_required=certificate.get("contingencies_required"),
               quality_gate=result.get("quality_gate"),
               result_sha256=completion["result_sha256"],
               completion_sha256=sha256(run / "completion.json"))
    if not passed:
        row["failure"] = result.get("worker_error") or result.get("controller_error") or \
            result.get("final_verification_error") or \
            "Incomplete pipeline, failed verification/quality gate, or exceeded deadline"
    return row


def regression_latch(root, config):
    if local_path(root) != ROOT.resolve():
        raise RuntimeError("Unexpected experiment root")
    auth = authorization()
    matches = [c for c in auth["cases"] if c["pilot_id"] == config.get("pilot_id")]
    if len(matches) != 1 or config != load(ROOT / matches[0]["config_path"]):
        raise RuntimeError("No exact new user authorization for this configuration")
    case = matches[0]
    if any(config[k] != case[k] for k in ("network", "scenario", "input_sha256")):
        raise RuntimeError("Registered case identity changed")
    validate_config(config, load(ROOT / auth["baseline_config"]))
    output_path_audit(config)
    state = latest_snapshot(queue_directory(auth) / "state")
    if state.get("status") != "RUNNING" or state.get("current_pilot_id") != config["pilot_id"]:
        raise RuntimeError("Case was not selected by the stop-on-failure queue")
    for earlier in auth["cases"][:auth["cases"].index(case)]:
        if not read_outcome(earlier)["pass"]:
            raise RuntimeError("A preceding frozen-regression case did not pass; stop")
    return ROOT / "runs" / (config["pilot_id"] + "_latch.json")


def check_registration(require_clean=True):
    auth = authorization()
    identity = validate_frozen_identity()
    for case in auth["cases"]:
        config = load(ROOT / case["config_path"])
        validate_config(config, load(ROOT / auth["baseline_config"]))
        output_path_audit(config)
        if sha256(ROOT / config["input_path"]) != case["input_sha256"]:
            raise RuntimeError(f"Changed input for {case['network']}")
        if (ROOT / "runs" / (case["pilot_id"] + "_latch.json")).exists():
            raise RuntimeError("A regression authorization has already been consumed; no retry")
    if require_clean:
        report = load(HERE / "harness_test_report.json")
        if report.get("pass") is not True:
            raise RuntimeError("Registration and actual certificate-save tests have not passed")
        for name, digest in report["source_sha256"].items():
            if sha256(HERE / name) != digest:
                raise RuntimeError(f"Registration changed after tests: {name}")
        if frozen.git("status", "--porcelain"):
            raise RuntimeError("Commit and push registration/test evidence before launch")
        branch = frozen.git("branch", "--show-current")
        if frozen.git("rev-parse", f"origin/{branch}") != identity["registration_commit"]:
            raise RuntimeError("Registration commit is not pushed")
    return auth, identity


def run_case(identifier):
    auth = authorization()
    identity = validate_frozen_identity()
    case = next(c for c in auth["cases"] if c["pilot_id"] == identifier)
    # The single adapter: register the new user-authorized run, not an old pilot.
    # The original preflight, execution, solver, deadline and checker remain intact.
    frozen.registered_latch = regression_latch
    path = ROOT / case["config_path"]
    config, env, record = frozen.preflight(path)
    record.update(identity)
    record["experiment_authorization_sha256"] = sha256(HERE / "authorization.json")
    record["output_path_audit"] = output_path_audit(config)
    return frozen.execute(path, config, env, record)


def run_queue():
    auth, identity = check_registration()
    directory = queue_directory(auth)
    claim_pilot(ROOT / "runs" / (auth["experiment_id"] + "_latch.json"),
                {**identity, "experiment_id": auth["experiment_id"], "directory": str(directory),
                 "authorization_sha256": sha256(HERE / "authorization.json"), "maximum_runs": 5})
    directory.mkdir(exist_ok=False)
    snapshots = Snapshots(directory / "state")
    completed = []
    child = None
    case = None
    try:
        for index, case in enumerate(auth["cases"]):
            snapshots.publish({"status": "RUNNING", "current_pilot_id": case["pilot_id"],
                               "completed": completed, "remaining": len(auth["cases"]) - index})
            print("REGRESSION_START " + json.dumps(case), flush=True)
            with (directory / (case["pilot_id"] + ".log")).open("w", encoding="utf-8") as log:
                child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--case", case["pilot_id"]],
                                         cwd=ROOT, env=frozen.runtime_environment(), stdout=log,
                                         stderr=subprocess.STDOUT,
                                         creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                atomic_json(directory / (case["pilot_id"] + "_process.json"),
                            {"pid": child.pid, "parent_pid": os.getpid(), "pilot_id": case["pilot_id"]}, exclusive=True)
                code = child.wait()
            row = read_outcome(case, code)
            completed.append(row)
            print("REGRESSION_RESULT " + json.dumps(row), flush=True)
            if not row["pass"]:
                snapshots.publish({"status": "STOPPED_ON_FAILURE", "completed": completed,
                                   "not_started": auth["cases"][index + 1:]})
                return 2
        snapshots.publish({"status": "ALL_PASSED", "completed": completed, "not_started": []})
        return 0
    except BaseException:
        if child is not None:
            stop_process(child)
        snapshots.publish({"status": "STOPPED_ON_ERROR", "completed": completed,
                           "current_pilot_id": case["pilot_id"] if case else None,
                           "error": traceback.format_exc()})
        raise


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--run", action="store_true")
    mode.add_argument("--case")
    args = parser.parse_args()
    if args.check:
        auth, identity = check_registration()
        print(json.dumps({**identity, "pass": True, "cases": auth["cases"]}, indent=2))
        return 0
    if args.case:
        return run_case(args.case)
    return run_queue()


if __name__ == "__main__":
    sys.exit(main())
