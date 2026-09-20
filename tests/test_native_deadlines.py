"""Tiny controller fixtures only; no solver, model data or benchmark launch."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
# Match the native Julia worker's direct PID. Windows venv python.exe is a
# separate synchronous launcher; do not weaken the production PID check.
DIRECT_PYTHON=getattr(sys,"_base_executable",sys.executable)
sys.path.insert(0,str(ROOT/"scripts"))
import run_disk_worker as disk
import run_reserve_benders as benders


class NativeDeadlineTests(unittest.TestCase):
    def event(self, **values):
        return {"event":"reserve_benders_solve_begin","stage":"source_reserve_benders",
            "pid":123,"epoch_seconds":100.0,"actual_limit_seconds":5.0,"mode":"master",**values}

    def test_exact_owned_call_not_loading_or_postsolve(self):
        options={"pid":123,"launched_epoch":99.0,"maximum_seconds":5.0}
        self.assertEqual(disk.native_call_deadline(self.event(),**options),105.0)
        for change in ({"pid":124},{"epoch_seconds":98.0},
                       {"event":"reserve_benders_worker_started"},
                       {"event":"reserve_benders_solve_returned"},
                       {"event":"reserve_benders_stage_complete"}):
            self.assertIsNone(disk.native_call_deadline(self.event(**change),**options))

    def test_malformed_or_expanded_native_limit_is_rejected(self):
        for change in ({"epoch_seconds":float("nan")},{"actual_limit_seconds":True},
                       {"actual_limit_seconds":float("inf")},{"actual_limit_seconds":0},
                       {"actual_limit_seconds":6}):
            with self.subTest(change=change),self.assertRaises(ValueError):
                disk.native_call_deadline(self.event(**change),pid=123,launched_epoch=99,maximum_seconds=5)

    def test_invalid_guard_does_not_launch(self):
        with patch.object(disk.subprocess,"Popen") as launch:
            for limit in (True,0,-1,float("inf")):
                with self.assertRaises(ValueError):
                    disk.launch_stage(["never"],deadline=time.time()+10,progress_path=ROOT/"tmp",
                                      native_call_limit=limit)
            with self.assertRaises(ValueError):
                disk.launch_stage(["never"],deadline=time.time()+10,native_call_limit=1)
            launch.assert_not_called()

    def test_ignored_native_limit_stops_owned_process_and_child(self):
        import psutil
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            progress=Path(folder)/"progress"
            code="""import os,sys,time,subprocess
from pathlib import Path
from go3cpu.controller import atomic_json
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)'],
    creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
atomic_json(Path(sys.argv[1])/'00000001.json',dict(event='reserve_benders_solve_begin',
    stage='source_reserve_benders',pid=os.getpid(),epoch_seconds=time.time(),
    actual_limit_seconds=0.1,mode='master',child_pid=child.pid))
time.sleep(10)
"""
            started=time.perf_counter()
            with self.assertRaises(disk.NativeCallDeadlineExceeded) as caught:
                disk.launch_stage([DIRECT_PYTHON,"-c",code,str(progress)],deadline=time.time()+8,
                    progress_path=progress,native_call_limit=0.1,log_path=Path(folder)/"child.log")
            details=caught.exception.details
            self.assertGreaterEqual(details["native_elapsed_seconds"],0.1)
            self.assertLess(time.perf_counter()-started,5)
            self.assertFalse(psutil.pid_exists(details["pid"]))
            self.assertFalse(psutil.pid_exists(details["begin_event"]["child_pid"]))

    def test_returned_marker_allows_postsolve_audit_time(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            progress=Path(folder)/"progress"
            code="""import os,sys,time
from pathlib import Path
from go3cpu.controller import atomic_json
root=Path(sys.argv[1])
record=dict(event='reserve_benders_solve_begin',stage='source_reserve_benders',
    pid=os.getpid(),epoch_seconds=time.time(),actual_limit_seconds=0.1,mode='master')
atomic_json(root/'00000001.json',record)
record.update(event='reserve_benders_solve_returned',epoch_seconds=time.time())
atomic_json(root/'00000002.json',record)
time.sleep(0.4)
"""
            _,code,wall=disk.launch_stage([DIRECT_PYTHON,"-c",code,str(progress)],
                deadline=time.time()+8,progress_path=progress,native_call_limit=0.1)
            self.assertEqual(code,0)
            self.assertGreaterEqual(wall,0.4)

    def test_interrupted_stage_has_immutable_evidence_and_no_retry(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            root=Path(folder);stage=root/"stage"
            request={"identity":{"fixture":"tiny-only"},"mode":"master","round":1}
            config={"scheduling_benders_master_round_seconds":5}
            failure=disk.NativeCallDeadlineExceeded({"begin_event":self.event()})
            with patch.object(benders,"launch_stage",side_effect=failure) as launch:
                with self.assertRaises(disk.NativeCallDeadlineExceeded):
                    benders.run_stage([],root,root/"config.json",request,stage,time.time()+20,config)
                self.assertEqual(launch.call_count,1)
                self.assertEqual(launch.call_args.kwargs["native_call_limit"],5)
                record=json.loads((stage/"interruption.json").read_text())
                self.assertEqual(record["kind"],"native_call_deadline")
                self.assertEqual(record["identity"],request["identity"])
                self.assertTrue(record["launch_cleanup_completed"])
                self.assertTrue(record["no_relaunch"])
                self.assertFalse((stage/"result.json").exists())
                with self.assertRaises(FileExistsError):
                    benders.run_stage([],root,root/"config.json",request,stage,time.time()+20,config)
                self.assertEqual(launch.call_count,1)


if __name__=="__main__":
    unittest.main()
