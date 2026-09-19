"""Only tiny synthetic lifecycle artifacts; no solver or competition case."""
import json
from pathlib import Path
import tempfile
import time
import unittest
import subprocess
import sys
from unittest.mock import patch

from test_scheduling_spool import ROOT,module
from go3cpu.controller import atomic_json,sha256
from go3cpu.process_memory import MemoryTimeline


class IsolatedSchedulingTests(unittest.TestCase):
    def test_fresh_orchestrator_resolves_monitor_dependency_before_launch(self):
        completed=subprocess.run([sys.executable,"-c",
            "import sys; sys.path.insert(0,'scripts'); import run_disk_worker; import psutil; print(psutil.__version__)"],
            cwd=ROOT,capture_output=True,text=True,timeout=15)
        self.assertEqual(completed.returncode,0,completed.stderr)
        self.assertTrue(completed.stdout.strip())

    def test_registered_changes_are_storage_options_only(self):
        old=json.loads((ROOT/"config/campaign_n23643_s003_r03.json").read_text())
        new=json.loads((ROOT/"config/campaign_n23643_s003_r04.json").read_text())
        changes={"pilot_id","scheduling_storage_policy","scheduling_native_threads",
                 "scheduling_native_parallel","scheduling_analysis_level"}
        self.assertEqual({k:v for k,v in old.items() if k not in changes},
                         {k:v for k,v in new.items() if k not in changes})
        self.assertEqual(new["scheduling_native_threads"],1)
        self.assertEqual(new["scheduling_native_parallel"],"off")
        self.assertEqual(new["minimum_available_memory_gib"],2)

    def test_three_process_order_and_exit_proofs(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            root=Path(folder);source=root/"case.json";source.write_text("{}")
            config={"scheduling_storage_policy":"disk_isolated_native_v1"}
            config_path=root/"config.json";atomic_json(config_path,config)
            output=root/"worker";spool=output/"scheduling_spool";calls=[]
            identity={"input_sha256":sha256(source),"config":config}
            def launch(command,**kwargs):
                stage=Path(command[3]).name;calls.append(stage)
                if stage=="build_scheduling_spool.jl":
                    atomic_json(spool/"manifest.json",{"complete":True,"builder_pid":101,
                        "builder_solve_calls":0,"cold_unsolved":True,"identity":identity})
                    return 101,0,1.0
                if stage=="solve_scheduling_native.jl":
                    self.assertTrue((spool/"builder_exit.json").is_file())
                    atomic_json(output/"native_result.json",{"complete":True,"diagnostic_only":False,
                        "pid":102,"identity":identity,"spool_manifest_sha256":sha256(spool/"manifest.json"),
                        "statistics":{"has_primal":True}})
                    return 102,0,2.0
                self.assertTrue((output/"native_exit.json").is_file())
                return 103,0,3.0
            with patch.object(module,"storage_check"),patch.object(module,"launch_stage",side_effect=launch):
                module.main(root/"julia.exe",source,output,config_path,time.time()+20)
            self.assertEqual(calls,["build_scheduling_spool.jl","solve_scheduling_native.jl","pilot_worker.jl"])
            self.assertTrue(json.loads((output/"native_exit.json").read_text())["exited_before_ac_launch"])

    def test_memory_timeline_records_real_process_without_solver(self):
        import os
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            path=Path(folder)/"memory.jsonl"
            timeline=MemoryTimeline(path)
            try:
                with patch("go3cpu.process_memory.available_memory_check") as check:
                    row=timeline.observe(os.getpid(),"unit_fixture")
                self.assertGreater(row["rss_bytes"],0)
                self.assertEqual(check.call_count,1)
            finally:
                timeline.close()
            self.assertEqual(json.loads(path.read_text())["stage"],"unit_fixture")


if __name__=="__main__":
    unittest.main()
