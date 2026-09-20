"""Hash-bound, child-process-only HiGHS override; installed JLL stays intact."""
import hashlib
import json
import os
from pathlib import Path
import tomllib

from .safety import local_path

POLICY = "setup_clique_guard_v1"
STOCK_ARTIFACT = "7b3fde6a10989de897c61b0c6880e7e7d97cccd4"
SOURCE_COMMIT = "04024d701f79feb8e2f18bc3df0dffc04ef05088"
MANIFEST = "manifests/native_highs_setup_guard_v1.json"


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def backend_record(config, *, root):
    policy = config.get("scheduling_native_backend_policy", "upstream_jll_v1")
    if policy == "upstream_jll_v1":
        if "scheduling_native_objective_clique_max_size" in config:
            raise ValueError("An objective-clique cap requires the registered native backend")
        return {"policy": policy}
    if policy != POLICY:
        raise ValueError("Unknown native backend policy")
    cap = config.get("scheduling_native_objective_clique_max_size")
    if type(cap) is not int or not 0 <= cap <= 4096:
        raise ValueError("Registered objective-clique cap must be an integer in [0,4096]")
    if (config.get("scheduling_decomposition_policy") != "source_reserve_benders_v1"
            or config.get("scheduling_storage_policy") != "disk_isolated_native_v1"
            or config.get("scheduling_native_threads") != 1
            or config.get("scheduling_native_parallel") != "off"
            or config.get("scheduling_mip_lp_solver") != "simplex"):
        raise ValueError("Local native backend requires the serial isolated simplex route")
    root = local_path(root)
    manifest_path = root / MANIFEST
    record = json.loads(manifest_path.read_text())
    if (record["policy"] != POLICY or record["source_commit"] != SOURCE_COMMIT
            or record["stock_artifact"] != STOCK_ARTIFACT
            or record["floating_point_bits"] != 64 or record["highs_int_bits"] != 32):
        raise ValueError("Native build identity or numeric contract differs")
    for item in record["files"].values():
        path = local_path(root / item["path"])
        if not path.is_relative_to(root) or digest(path) != item["sha256"]:
            raise ValueError("Native build artifact changed or escaped the repository")
    overlay = local_path(root / record["overlay_directory"])
    prefix = local_path(root / record["artifact_directory"])
    if not overlay.is_relative_to(root) or not prefix.is_relative_to(root):
        raise ValueError("Native artifact override must remain local to this repository")
    overrides = tomllib.loads((overlay / "artifacts/Overrides.toml").read_text())
    if overrides != {STOCK_ARTIFACT: str(prefix).replace("\\", "/")}:
        raise ValueError("Unexpected native override; no global JLL changes are permitted")
    return {"policy": policy, "manifest_sha256": digest(manifest_path),
            "manifest": record, "objective_clique_max_size": cap}


def native_environment(config, *, root, base_environment=None):
    record = backend_record(config, root=root)
    if record["policy"] == "upstream_jll_v1":
        return None
    root = local_path(root)
    env = dict(os.environ if base_environment is None else base_environment)
    # All other package artifacts use the unchanged ordinary depot. Only the
    # owned native child receives this overlay; builders/AC use the stock JLL.
    env["JULIA_DEPOT_PATH"] = os.pathsep.join((
        str(local_path(root / record["manifest"]["overlay_directory"])),
        str(local_path(root / "environments/julia-depot"))))
    return env
