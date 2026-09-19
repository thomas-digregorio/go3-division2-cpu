"""Controller seams only; never starts a solver or loads a competition case."""
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("disk_worker",ROOT/"scripts/run_disk_worker.py")
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


class DiskSchedulingTests(unittest.TestCase):
    def test_registration_changes_storage_only(self):
        old=json.loads((ROOT/"config/campaign_n23643_s003_r02.json").read_text())
        new=json.loads((ROOT/"config/campaign_n23643_s003_r03.json").read_text())
        excluded={"pilot_id","scheduling_storage_policy"}
        self.assertEqual({k:v for k,v in old.items() if k not in excluded},
                         {k:v for k,v in new.items() if k not in excluded})
        self.assertEqual(new["scheduling_storage_policy"],"disk_backed_native_v1")

    def test_builder_failure_never_launches_solver(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            root=Path(folder);config=root/"config.json";config.write_text(json.dumps({
                "scheduling_storage_policy":"disk_backed_native_v1"}))
            with patch.object(module,"storage_check"), patch.object(module,"launch_stage",side_effect=RuntimeError("builder failed")) as launch:
                with self.assertRaisesRegex(RuntimeError,"builder failed"):
                    module.main(root/"julia.exe",root/"case",root/"output",config,time.time()+5)
                self.assertEqual(launch.call_count,1)

    def test_no_old_spool_reuse(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as folder:
            root=Path(folder);config=root/"config.json";config.write_text(json.dumps({
                "scheduling_storage_policy":"disk_backed_native_v1"}))
            (root/"output/scheduling_spool").mkdir(parents=True)
            with patch.object(module,"launch_stage") as launch:
                with self.assertRaises(FileExistsError):
                    module.main(root/"julia.exe",root/"case",root/"output",config,time.time()+5)
                launch.assert_not_called()

    def test_expired_deadline_does_not_launch(self):
        with patch.object(module.subprocess,"Popen") as launch:
            with self.assertRaises(TimeoutError):
                module.launch_stage(["never"],deadline=time.time()-1)
            launch.assert_not_called()


if __name__=="__main__":
    unittest.main()
