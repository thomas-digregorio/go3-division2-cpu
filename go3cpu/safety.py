"""Local path and physical-storage guards; no cleanup side effects."""

from pathlib import Path
import os
import shutil
import math

GIB = 1024 ** 3
MIN_FREE_BYTES = 30 * GIB


class HostMemoryPressureError(RuntimeError):
    def __init__(self, record):
        self.record = record
        super().__init__(f"Host memory gate: {record['available_bytes']/GIB:.3f} GiB available, "
                         f"need {record['floor_bytes']/GIB:.3f} GiB; stop owned work only")


def configured_memory_floor(config):
    value = config.get("minimum_available_memory_gib")
    if value is None:
        return None  # Historical configurations retain their registered behavior.
    if (isinstance(value, bool) or not isinstance(value, (int, float))
            or not math.isfinite(value) or value < 1):
        raise ValueError("Configured available-memory floor must be finite and at least 1 GiB")
    return int(value * GIB)


def available_memory_check(available_bytes, total_bytes, *, floor_bytes):
    if (any(isinstance(v, bool) or not isinstance(v, int)
            for v in (available_bytes, total_bytes, floor_bytes))
            or not 0 <= available_bytes <= total_bytes or not 0 < floor_bytes <= total_bytes):
        raise ValueError("Invalid physical-memory measurement or floor")
    record = {"policy": "host_available_memory_floor_v1", "available_bytes": available_bytes,
              "total_physical_bytes": total_bytes, "floor_bytes": floor_bytes,
              "scope": "Global host availability; resource stop, not an infeasibility proof"}
    if available_bytes < floor_bytes:
        raise HostMemoryPressureError(record)
    return record


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
