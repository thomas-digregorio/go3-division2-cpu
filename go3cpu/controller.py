"""Absolute deadlines, immutable candidate evidence and one-pilot latch."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from .safety import local_path


def atomic_json(path, data):
    path = local_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name+".pending")
    temp.write_text(json.dumps(data, indent=2, allow_nan=False), encoding="utf-8")
    os.replace(temp,path)


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
    def __init__(self, output):
        self.output, self.record = local_path(output), None

    def consider(self, candidate, verification):
        if not verification.get("pass") or not verification.get("complete"):
            return False
        if verification.get("candidate_sha256") != sha256(candidate):
            raise ValueError("Candidate changed after verification")
        import math
        objective = verification["objective"]
        if not math.isfinite(objective):
            raise ValueError("Nonfinite verified objective")
        if self.record is not None and objective <= self.record["objective"]:
            return False
        self.output.mkdir(parents=True,exist_ok=True)
        destination = self.output/"solution.json"
        temporary = self.output/"solution.json.pending"
        shutil.copyfile(candidate,temporary)
        if sha256(temporary) != verification["candidate_sha256"]:
            raise ValueError("Incumbent copy failed verification")
        os.replace(temporary,destination)
        self.record = dict(verification)
        atomic_json(self.output/"certificate.json",self.record)
        return True
