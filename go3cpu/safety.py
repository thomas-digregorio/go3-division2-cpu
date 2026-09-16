"""Local path and physical-storage guards; no cleanup side effects."""

from pathlib import Path
import os
import shutil

GIB = 1024 ** 3
MIN_FREE_BYTES = 30 * GIB


def local_path(path):
    raw = str(path)
    if "onedrive" in raw.casefold():
        raise ValueError(f"OneDrive path is forbidden: {raw}")
    resolved = Path(path).expanduser().resolve()
    if "onedrive" in str(resolved).casefold():
        raise ValueError(f"OneDrive resolved path is forbidden: {resolved}")
    return resolved


def storage_check(path, *, pending_bytes=0, floor_bytes=MIN_FREE_BYTES,
                  disk_usage=shutil.disk_usage):
    if floor_bytes < MIN_FREE_BYTES or pending_bytes < 0:
        raise ValueError("Storage floor must be at least 30 GiB; pending bytes >= 0")
    target = local_path(path)
    while not target.exists():
        target = target.parent
    # WSL's virtual free capacity is not a physical C: capacity check.
    physical = Path("C:/") if os.name == "nt" else Path("/mnt/c")
    if not physical.exists():
        raise RuntimeError("Physical Windows C: storage is unavailable; cannot launch")
    usage = disk_usage(physical)
    if usage.free < floor_bytes + pending_bytes:
        raise RuntimeError(
            f"Storage gate: {usage.free/GIB:.3f} GiB free, "
            f"need {floor_bytes/GIB:.3f} GiB floor + "
            f"{pending_bytes/GIB:.3f} GiB pending writes")
    return {"physical_path": str(physical), "free_bytes": usage.free,
            "floor_bytes": floor_bytes, "pending_bytes": pending_bytes,
            "target": str(target)}
