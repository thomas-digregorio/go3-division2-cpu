"""Run a no-solve reserve-only source audit with local paths and resource guards."""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from scripts.run_pilot import JULIA, runtime_environment, psutil

evidence=Path(tempfile.mkdtemp(prefix="reserve_zero_audit_",dir=ROOT/"tmp"))
print(evidence,flush=True)
source=sys.argv[1]
started=time.monotonic()
with (evidence/"console.log").open("w",encoding="utf-8") as log:
    p=subprocess.Popen([str(JULIA),"--startup-file=no","--project=.","tmp/diagnose_reserve_zero_rows.jl",source],
        cwd=ROOT,env=runtime_environment(),stdout=log,stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
    while p.poll() is None:
        if time.monotonic()-started>240 or psutil.virtual_memory().available<2*2**30:
            p.terminate();p.wait(timeout=10)
            raise RuntimeError("No-solve structural audit exceeded its resource guard")
        time.sleep(0.5)
print(json.dumps({"returncode":p.returncode,"seconds":time.monotonic()-started,"optimization_calls":0}),flush=True)
print((evidence/"console.log").read_text()[-9000:],flush=True)
raise SystemExit(p.returncode)
