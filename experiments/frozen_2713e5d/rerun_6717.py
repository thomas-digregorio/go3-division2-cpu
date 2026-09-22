"""One newly authorized cold 6717 attempt; frozen numerical runner is untouched."""
import argparse
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run as registration

ROOT = registration.ROOT
AUTH = HERE / "rerun_6717_authorization.json"
REPORT = HERE / "rerun_6717_test_report.json"
PILOT = "campaign_r3_06717"
SOURCE_NAMES = (
    "rerun_6717.py", "test_rerun_6717.py", "rerun_6717_authorization.json",
    "configs/C3E4N06717D2_s002_r3.json",
)


def authorization():
    auth = registration.load(AUTH)
    expected = {
        "algorithm_commit": registration.ALGORITHM,
        "explicit_user_authorization": True, "preserve_previous_attempt": True,
        "pilot_id": PILOT, "network": "C3E4N06717D2", "scenario": "002",
        "input_sha256": "bccfff47a3f6de9d28117d8c76aabf47716afb92a16982067764dcc6f34f769e",
        "config_path": "experiments/frozen_2713e5d/configs/C3E4N06717D2_s002_r3.json",
        "cold_start_required": True, "maximum_full_runs": 1,
        "total_seconds": 7200, "automatic_retry": False,
    }
    if any(auth.get(k) != v for k, v in expected.items()):
        raise RuntimeError("Different rerun authorization or case identity")
    return auth


def validate_config(config):
    auth = authorization()
    previous = registration.load(HERE / "configs/C3E4N06717D2_s002.json")
    expected = dict(previous, pilot_id=PILOT)
    if config != expected:
        raise RuntimeError("Only the experiment ID may differ from the interrupted 6717 run")
    if any(config[k] != auth[k] for k in ("pilot_id", "network", "scenario", "input_sha256")):
        raise RuntimeError("Rerun identity mismatch")
    registration.output_path_audit(config)


def registered_latch(root, config):
    if registration.local_path(root) != ROOT.resolve():
        raise RuntimeError("Unexpected experiment root")
    validate_config(config)
    return ROOT / "runs" / (PILOT + "_latch.json")


def preflight():
    identity = registration.validate_frozen_identity()
    auth = authorization()
    # Preserve the existing tested queue/path adapter as well as all numerical files.
    original = registration.load(HERE / "harness_test_report.json")
    for name, digest in original["source_sha256"].items():
        if registration.sha256(HERE / name) != digest:
            raise RuntimeError(f"Original registration changed: {name}")
    tested = registration.load(REPORT)
    if tested.get("pass") is not True or set(tested["source_sha256"]) != set(SOURCE_NAMES):
        raise RuntimeError("New one-use registration component tests have not passed")
    for name, digest in tested["source_sha256"].items():
        if registration.sha256(HERE / name) != digest:
            raise RuntimeError(f"Rerun registration changed after tests: {name}")
    registration.frozen.registered_latch = registered_latch
    path = ROOT / auth["config_path"]
    config, env, record = registration.frozen.preflight(path)
    record.update(identity)
    record["experiment_authorization_sha256"] = registration.sha256(AUTH)
    record["registration_tests_sha256"] = registration.sha256(REPORT)
    record["output_path_audit"] = registration.output_path_audit(config)
    record["previous_user_stopped_attempt"] = auth["previous_attempt"]
    return path, config, env, record


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--run", action="store_true")
    args = parser.parse_args()
    path, config, env, record = preflight()
    if args.check:
        print(json.dumps({"pass": True, "preflight": record}, indent=2))
        return 0
    # The exclusive latch is claimed by the original runner before any solver starts.
    # No other case, restart loop, solver override or numerical modification exists here.
    return registration.frozen.execute(path, config, env, record)


if __name__ == "__main__":
    sys.exit(main())
