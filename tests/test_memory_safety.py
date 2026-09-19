from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import json
import tempfile
import unittest

from go3cpu.safety import (GIB, configured_memory_floor, available_memory_check,
                          HostMemoryPressureError)
from go3cpu.controller import Deadline
from scripts.run_pilot import Monitor

ROOT=Path(__file__).resolve().parents[1]


class MemorySafetyTests(unittest.TestCase):
    def test_opt_in_does_not_change_historical_configs(self):
        self.assertIsNone(configured_memory_floor({}))
        self.assertEqual(configured_memory_floor({"minimum_available_memory_gib":2}),2*GIB)
        for value in (0,0.5,True,float("inf"),float("nan"),"2"):
            with self.assertRaises(ValueError):
                configured_memory_floor({"minimum_available_memory_gib":value})

    def test_exact_floor_and_low_memory_evidence(self):
        self.assertEqual(available_memory_check(2*GIB,32*GIB,floor_bytes=2*GIB)["available_bytes"],2*GIB)
        with self.assertRaises(HostMemoryPressureError) as caught:
            available_memory_check(48*1024**2,32*GIB,floor_bytes=2*GIB)
        self.assertEqual(caught.exception.record["available_bytes"],48*1024**2)
        self.assertIn("not an infeasibility",caught.exception.record["scope"])

    def test_invalid_measurements_fail_closed(self):
        for available,total,floor in ((-1,GIB,GIB),(2*GIB,GIB,GIB),(GIB,GIB,2*GIB),
                                      (True,GIB,GIB),(GIB,float("nan"),GIB)):
            with self.assertRaises(ValueError):
                available_memory_check(available,total,floor_bytes=floor)

    def test_monitor_preserves_resource_reason_and_does_not_kill_other_apps(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            monitor=Monitor(Path(d),Deadline(30),{"minimum_available_memory_gib":2,
                "total_seconds":30,"minimum_free_gib":30})
            with patch("scripts.run_pilot.psutil.virtual_memory",
                       return_value=SimpleNamespace(available=GIB,total=32*GIB)):
                with self.assertRaises(HostMemoryPressureError):
                    monitor.observe()
            record=json.loads((Path(d)/"resource_stop.json").read_text())
            self.assertEqual(record["floor_bytes"],2*GIB)
            self.assertEqual(record["available_bytes"],GIB)
            self.assertEqual(monitor.owned,[])
            self.assertGreaterEqual(record["elapsed_seconds"],0)


if __name__=="__main__":
    unittest.main()
