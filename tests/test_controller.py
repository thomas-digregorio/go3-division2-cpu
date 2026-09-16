import json
from pathlib import Path
import tempfile
import os
import sys
import time
import unittest

from go3cpu.controller import Deadline, Incumbent, atomic_json, claim_pilot, sha256, run_bounded
from go3cpu.official import configure_imports

ROOT = Path(__file__).resolve().parents[1]
configure_imports(ROOT)


class ControllerTests(unittest.TestCase):
    def test_global_budget_not_reset_per_stage(self):
        now = [10.0]
        d = Deadline(20,reserve=5,clock=lambda:now[0])
        self.assertEqual(d.remaining(work=True),15)
        now[0] = 25
        self.assertEqual(d.remaining(work=True),0)
        self.assertEqual(d.remaining(),5)
        now[0] = 31
        self.assertEqual(d.remaining(),0)

    def test_only_one_pilot(self):
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            latch=Path(directory)/"latch.json"
            claim_pilot(latch,{"run":1})
            with self.assertRaises(FileExistsError):
                claim_pilot(latch,{"run":2})

    def test_retention_rejects_partial_and_inferior_candidates(self):
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            d=Path(directory); source=d/"candidate.json"
            atomic_json(source,{"state":1})
            inc=Incumbent(d/"retained")
            certificate={"pass":True,"complete":True,"objective":5,"candidate_sha256":sha256(source)}
            self.assertTrue(inc.consider(source,certificate))
            old=(d/"retained/solution.json").read_bytes()
            atomic_json(source,{"state":2})
            self.assertFalse(inc.consider(source,{**certificate,"pass":False}))
            self.assertFalse(inc.consider(source,{**certificate,"objective":4,"candidate_sha256":sha256(source)}))
            self.assertEqual(old,(d/"retained/solution.json").read_bytes())
            with self.assertRaises(ValueError):
                inc.consider(source,certificate)

    def test_actual_owned_process_cancellation(self):
        import psutil
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            seen = []
            before = time.perf_counter()
            result = run_bounded([sys.executable,"-c","import time; time.sleep(30)"],
                Path(directory)/"cancel.log",cwd=ROOT,env=os.environ.copy(),
                deadline=before+0.4,observer=lambda p:seen.append(p.pid))
            self.assertTrue(result["timeout"])
            self.assertLess(time.perf_counter()-before,5)
            self.assertFalse(psutil.pid_exists(seen[-1]))

    def test_nonfinite_incumbent_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory); source=d/"candidate.json"
            atomic_json(source,{"state":1})
            with self.assertRaises(ValueError):
                Incumbent(d/"retained").consider(source,{"pass":True,"complete":True,
                    "objective":float("nan"),"candidate_sha256":sha256(source)})


if __name__ == "__main__":
    unittest.main()
