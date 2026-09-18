import json
from pathlib import Path
import tempfile
import os
import sys
import time
import unittest
import threading

from go3cpu.controller import (Deadline, Incumbent, Snapshots, atomic_json, claim_pilot,
    latest_candidate, latest_snapshot, registered_latch, sha256, run_bounded,
    partial_worker_timings, partial_scheduling_statistics)
from go3cpu.official import configure_imports

ROOT = Path(__file__).resolve().parents[1]
configure_imports(ROOT)


class ControllerTests(unittest.TestCase):
    def test_partial_timings_survive_no_schedule_and_prefer_later_stage(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            worker=Path(directory)
            self.assertEqual(partial_worker_timings(worker), {})
            timing=worker/"timing_snapshots"
            progress={"loading_and_preprocessing":1.5,
                      "scheduling_elapsed_to_last_event":20.0,
                      "last_scheduling_event":"construction_audit_complete"}
            atomic_json(timing/"scheduling_events/00000001.json",progress)
            self.assertEqual(partial_worker_timings(worker),progress)
            early={"loading_and_preprocessing":1.5, "scheduling":42.0}
            atomic_json(timing/"scheduling.json",early)
            self.assertEqual(partial_worker_timings(worker),early)
            late={**early,"initial_reserves":3.0}
            atomic_json(timing/"initial.json",late)
            self.assertEqual(partial_worker_timings(worker),late)

    def test_partial_scheduling_statistics_preserve_phases_and_ordered_events(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            worker=Path(directory)
            self.assertEqual(partial_scheduling_statistics(worker),
                             {"scheduling_phases":{},"scheduling_events":[]})
            atomic_json(worker/"statistics/online_commitment_construction.json",{"pass":True})
            for n in (2,1):
                atomic_json(worker/f"statistics/scheduling_events/{n:08d}.json",{"sequence":n})
            atomic_json(worker/"statistics/scheduling_events/unrelated.json",{"ignore":True})
            self.assertEqual(partial_scheduling_statistics(worker),{
                "scheduling_phases":{"online_commitment_construction":{"pass":True}},
                "scheduling_events":[{"sequence":1},{"sequence":2}]})

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
            retained=Path(inc.record["retained_solution"])
            old=retained.read_bytes()
            atomic_json(source,{"state":2})
            self.assertFalse(inc.consider(source,{**certificate,"pass":False}))
            self.assertFalse(inc.consider(source,{**certificate,"objective":4,"candidate_sha256":sha256(source)}))
            self.assertEqual(old,retained.read_bytes())
            with self.assertRaises(ValueError):
                inc.consider(source,certificate)

    def test_reader_held_status_cannot_block_next_snapshot(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            snapshots=Snapshots(Path(directory)/"progress")
            first=snapshots.publish({"n":1})
            with first.open("r") as reader:
                second=snapshots.publish({"n":2})
                self.assertNotEqual(first,second)
                self.assertEqual(json.load(reader),{"n":1})
                self.assertEqual(latest_snapshot(snapshots.directory),{"n":2})
            self.assertEqual(json.loads(first.read_text()),{"n":1})

    def test_concurrent_snapshot_reader(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            snapshots=Snapshots(directory); snapshots.publish({"n":0})
            done=threading.Event(); errors=[]
            def read_loop():
                try:
                    while not done.is_set():
                        value=latest_snapshot(directory)
                        if not isinstance(value.get("n"),int):
                            errors.append("partial publication")
                except Exception as e:
                    errors.append(repr(e))
            thread=threading.Thread(target=read_loop); thread.start()
            try:
                for n in range(1,51):
                    snapshots.publish({"n":n})
            finally:
                done.set(); thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors,[])
            self.assertEqual(latest_snapshot(directory),{"n":50})

    def test_open_first_incumbent_survives_better_incumbent(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory); source=d/"candidate.json"; inc=Incumbent(d/"retained")
            atomic_json(source,{"state":1})
            inc.consider(source,{"pass":True,"complete":True,"objective":1,"candidate_sha256":sha256(source)})
            first=Path(inc.record["retained_solution"])
            with first.open("r") as held:
                atomic_json(source,{"state":2})
                self.assertTrue(inc.consider(source,{"pass":True,"complete":True,"objective":2,"candidate_sha256":sha256(source)}))
                self.assertEqual(json.load(held),{"state":1})
            self.assertTrue(first.exists())
            self.assertEqual(json.loads(Path(inc.record["retained_solution"]).read_text()),{"state":2})

    def test_replacement_latch_preserves_first_authorization(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory); old=d/"runs/pilot_latch.json"
            claim_pilot(old,{"first_run":"untouched"})
            before=old.read_bytes()
            atomic_json(d/"manifests/authorization_pilot_002.json",{"pilot_id":"pilot_002",
                "maximum_full_runs":1,"input_sha256":"test-only"})
            cfg={"pilot_id":"pilot_002","input_sha256":"test-only"}
            new=registered_latch(d,cfg)
            self.assertNotEqual(old,new)
            claim_pilot(new,{"replacement":1})
            with self.assertRaises(FileExistsError):
                claim_pilot(new,{"replacement":2})
            self.assertEqual(before,old.read_bytes())
            with self.assertRaises(ValueError):
                registered_latch(d,{**cfg,"pilot_id":"pilot_003"})

    def test_latest_complete_checkpoint_selected_after_worker_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory)
            self.assertIsNone(latest_candidate(d))
            atomic_json(d/"candidate_schedule.json",{})
            atomic_json(d/"checkpoints/candidate_ac_0001.json",{})
            atomic_json(d/"checkpoints/candidate_ac_0047.json",{})
            self.assertEqual(latest_candidate(d).name,"candidate_ac_0047.json")
            atomic_json(d/"candidate_final.json",{})
            self.assertEqual(latest_candidate(d).name,"candidate_final.json")

    def test_exclusive_publication_never_rewrites(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            path=Path(directory)/"original.json"
            atomic_json(path,{"state":1},exclusive=True)
            with self.assertRaises(FileExistsError):
                atomic_json(path,{"state":2},exclusive=True)
            self.assertEqual(json.loads(path.read_text()),{"state":1})

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

    def test_campaign_preserves_physical_point_over_higher_scoring_hard_only(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory); source=d/"candidate.json"
            inc=Incumbent(d/"retained",prefer_physical=True)
            def submit(state,objective,physical,**extra):
                atomic_json(source,{"state":state})
                cert={"pass":True,"complete":True,"objective":objective,
                    "candidate_sha256":sha256(source),"official_feas":1,
                    "official_phys_feas":physical,"independent_hard_pass":True,
                    "objective_agreement":True,"contingencies_required":9,
                    "contingencies_completed":9,**extra}
                return inc.consider(source,cert)
            self.assertTrue(submit(1,100,0))
            hard=Path(inc.record["retained_solution"])
            hard_bytes=hard.read_bytes()
            self.assertFalse(submit(2,200,1,contingencies_completed=8))
            self.assertTrue(submit(3,90,1))
            physical=Path(inc.record["retained_solution"])
            self.assertFalse(submit(4,300,0))
            self.assertFalse(submit(5,90,1))
            self.assertEqual(physical,Path(inc.record["retained_solution"]))
            self.assertTrue(submit(6,95,1))
            self.assertEqual(hard.read_bytes(),hard_bytes)
            self.assertEqual(json.loads(physical.read_text()),{"state":3})
            for snapshot in (d/"retained").iterdir():
                certificate=json.loads((snapshot/"certificate.json").read_text())
                self.assertEqual(sha256(snapshot/"solution.json"),certificate["candidate_sha256"])
            self.assertEqual(len(list((d/"retained").iterdir())),3)

    def test_historical_objective_only_order_is_unchanged(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as directory:
            d=Path(directory); source=d/"candidate.json"; inc=Incumbent(d/"retained")
            atomic_json(source,{"state":1})
            self.assertTrue(inc.consider(source,{"pass":True,"complete":True,
                "objective":100,"official_phys_feas":0,"candidate_sha256":sha256(source)}))
            atomic_json(source,{"state":2})
            self.assertFalse(inc.consider(source,{"pass":True,"complete":True,
                "objective":90,"official_phys_feas":1,"candidate_sha256":sha256(source)}))


if __name__ == "__main__":
    unittest.main()
