"""Absolute deadlines, immutable candidate evidence and one-pilot latch."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from .safety import local_path
from .selection import prefer_verified_candidate


def atomic_json(path, data, *, exclusive=False):
    path = local_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if exclusive and path.exists():
        raise FileExistsError(f"Immutable artifact already exists: {path}")
    temp = path.with_name(path.name+"."+uuid.uuid4().hex+".pending")
    temp.write_text(json.dumps(data, indent=2, allow_nan=False), encoding="utf-8")
    os.replace(temp,path)


class Snapshots:
    """Single-writer immutable publications: readers never block replacement."""
    def __init__(self, directory):
        self.directory=local_path(directory)
        self.directory.mkdir(parents=True,exist_ok=True)
        self.sequence=max((int(p.stem) for p in self.directory.glob("*.json") if p.stem.isdigit()),default=0)

    def publish(self, data):
        self.sequence+=1
        path=self.directory/f"{self.sequence:08d}.json"
        atomic_json(path,data,exclusive=True)
        return path


def latest_snapshot(directory):
    paths=sorted(p for p in local_path(directory).glob("*.json") if p.stem.isdigit())
    return json.loads(paths[-1].read_text()) if paths else {}


def partial_worker_timings(worker_dir):
    """Prefer the most advanced completed stage; never infer a missing subtotal."""
    directory = local_path(worker_dir) / "timing_snapshots"
    for name in ("initial.json", "scheduling.json"):
        path = directory / name
        if path.is_file():
            return json.loads(path.read_text())
    return {}


def registered_latch(root, config):
    """Each explicit authorization has a separate immutable one-run latch."""
    root=local_path(root)
    pilot_id=config.get("pilot_id","pilot_001")
    if pilot_id.startswith("campaign_"):
        from .campaign import campaign_latch
        return campaign_latch(root,config)
    if pilot_id=="pilot_001":
        return root/"runs/pilot_latch.json"
    if pilot_id!="pilot_002":
        raise ValueError("No registered user authorization for this pilot identifier")
    authorization=json.loads((root/"manifests/authorization_pilot_002.json").read_text())
    if (authorization["pilot_id"]!=pilot_id or authorization["maximum_full_runs"]!=1 or
        authorization["input_sha256"]!=config["input_sha256"] or not (root/"runs/pilot_latch.json").exists()):
        raise ValueError("Replacement authorization or preceding-run record mismatch")
    return root/"runs/pilot_002_latch.json"


def latest_candidate(worker_dir):
    worker_dir=local_path(worker_dir)
    final=worker_dir/"candidate_final.json"
    if final.exists():
        return final
    checkpoints=sorted((worker_dir/"checkpoints").glob("candidate_ac_*.json"))
    if checkpoints:
        return checkpoints[-1]
    initial=worker_dir/"candidate_schedule.json"
    return initial if initial.exists() else None


def sha256(path):
    with local_path(path).open("rb") as stream:
        return hashlib.file_digest(stream,"sha256").hexdigest()


def claim_pilot(path, identity):
    path = local_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation never removes a previous latch, including failed runs.
    with path.open("x", encoding="utf-8") as f:
        json.dump(identity,f,indent=2)


class Deadline:
    def __init__(self, seconds, *, reserve=0, clock=time.perf_counter):
        if seconds <= 0 or reserve < 0 or reserve >= seconds:
            raise ValueError("Invalid global deadline/reserve")
        self.clock, self.start, self.seconds, self.reserve = clock, clock(), seconds, reserve

    @property
    def end(self):
        return self.start+self.seconds

    def remaining(self, *, work=False):
        return max(0.0, self.end-self.clock()-(self.reserve if work else 0.0))


def stop_process(process):
    """Only terminate this explicitly owned process and its descendants."""
    if process.poll() is not None:
        return
    import psutil
    try:
        parent = psutil.Process(process.pid)
        owned = parent.children(recursive=True)+[parent]
        for p in reversed(owned):
            try:
                p.terminate()
            except psutil.NoSuchProcess:
                pass
        _, alive = psutil.wait_procs(owned, timeout=1)
        for p in alive:
            try:
                p.kill()
            except psutil.NoSuchProcess:
                pass
    except psutil.NoSuchProcess:
        pass
    process.wait(timeout=2)


def run_bounded(command, log_path, *, cwd, env, deadline, observer=None):
    log_path = local_path(log_path)
    with log_path.open("w",encoding="utf-8") as log:
        process = subprocess.Popen(command,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
        try:
            while process.poll() is None:
                if observer:
                    observer(process)
                if time.perf_counter() >= deadline:
                    stop_process(process)
                    return {"timeout":True,"returncode":process.returncode}
                time.sleep(0.1)
            return {"timeout":False,"returncode":process.returncode}
        finally:
            stop_process(process)


class Incumbent:
    def __init__(self, output, *, prefer_physical=False):
        self.output, self.record = local_path(output), None
        self.prefer_physical = prefer_physical

    def consider(self, candidate, verification):
        if not verification.get("pass") or not verification.get("complete"):
            return False
        if verification.get("candidate_sha256") != sha256(candidate):
            raise ValueError("Candidate changed after verification")
        import math
        objective = verification["objective"]
        if not math.isfinite(objective):
            raise ValueError("Nonfinite verified objective")
        if not prefer_verified_candidate(verification, self.record,
                                         prefer_physical=self.prefer_physical):
            return False
        snapshot=self.output/verification["candidate_sha256"]
        snapshot.mkdir(parents=True,exist_ok=False)
        destination = snapshot/"solution.json"
        temporary = snapshot/"solution.json.pending"
        shutil.copyfile(candidate,temporary)
        if sha256(temporary) != verification["candidate_sha256"]:
            raise ValueError("Incumbent copy failed verification")
        os.replace(temporary,destination)
        record = dict(verification)
        record["retained_solution"]=str(destination)
        atomic_json(snapshot/"certificate.json",record,exclusive=True)
        self.record=record
        return True
