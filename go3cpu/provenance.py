"""Exact source-inventory coverage for a completed component-test gate."""

from hashlib import sha256
from pathlib import Path


def source_hashes(root: Path) -> dict[str, str]:
    root = Path(root).resolve()
    patterns = (
        "go3cpu/*.py", "scripts/*.py", "scripts/*.jl", "src/*.jl",
        "tests/*.py", "config/*.json", "manifests/authorization_*.json",
        "manifests/campaign/*.json",
    )
    files = {path for pattern in patterns for path in root.glob(pattern)}
    files.update(root / name for name in (
        "Project.toml", "Manifest.toml", "manifests/sources.json"))
    case = root / "manifests/case.json"
    if case.is_file():
        files.add(case)
    return {
        path.relative_to(root).as_posix(): sha256(path.read_bytes()).hexdigest()
        for path in sorted(files)
    }


def assert_tested_sources_unchanged(root: Path, tested: dict[str, str]) -> None:
    """Reject newly added, removed, renamed and modified covered source files.

    Checking only hashes named by an old record misses a newly added module.
    Regenerating the complete inventory prevents that untested-code loophole.
    Generated results, caches and the test record itself are intentionally not
    source inputs; including the record would produce a self-referential hash.
    """
    current = source_hashes(root)
    added = sorted(current.keys() - tested.keys())
    removed = sorted(tested.keys() - current.keys())
    changed = sorted(k for k in current.keys() & tested.keys() if current[k] != tested[k])
    if added or removed or changed:
        raise RuntimeError(
            "Source inventory changed since component tests: "
            f"added={added}; removed={removed}; modified={changed}"
        )
