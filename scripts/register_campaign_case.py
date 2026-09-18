"""Hash and audit an already downloaded raw scenario. Does not solve or read a solution."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from go3cpu.contract import load_case, case_manifest
from go3cpu.controller import atomic_json
from go3cpu.campaign import sixth_best_target
from go3cpu.safety import local_path
from audit_sources import archive_source


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", required=True)
    args = p.parse_args()
    config = json.loads(local_path(args.config).read_text())
    path = local_path(ROOT / config["input_path"])
    case, digest = load_case(path, config["input_sha256"])
    comparison = json.loads((ROOT / config["comparison_manifest_path"]).read_text())
    target = sixth_best_target(comparison, network=config["network"], scenario=config["scenario"],
                               switching=config["official_allow_switching"])
    manifest = {"schema_version": 1, "network": config["network"], "scenario": config["scenario"],
        "input_sha256": digest, "input_bytes": path.stat().st_size,
        "archive_url": archive_source(config["network"])[0],
        "archive_entry": f"D2/{config['network']}/scenario_{config['scenario']}.json",
        "selection_rule": "Smallest numeric public D2 scenario, selected before solve-quality inspection.",
        "initialization": "Cold from raw source conditions only; no supplied POP or saved solution.",
        "official_allow_switching": config["official_allow_switching"],
        "unsupported_required_features_present": [], **case_manifest(case)}
    atomic_json(ROOT / config["case_manifest_path"], manifest, exclusive=True)
    print(json.dumps({"manifest": manifest, "target": target}, indent=2))


if __name__ == "__main__":
    main()
