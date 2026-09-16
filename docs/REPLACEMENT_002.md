# Registered replacement pilot 002

The user authorized fixing the reported issues and running again. This is one
new cold run, not a restart concealed inside the original authorization.

## Fixed issues

1. **Independent consumer-cost ordering.** GO3 orders producer marginal blocks
   ascending and consumer blocks descending. The checker now uses those orders
   without changing raw costs. Tests include unsorted, negative-slope and
   multi-block curves, comparison with the pinned official implementation, and
   source-array immutability.
2. **Windows publication race.** All active progress and worker publications are
   write-once snapshots. Tests hold an older file open while newer publications
   proceed, and exercise concurrent readers. Verified incumbent files are retained
   in separate hash directories, including the first accepted solution. Final
   checkpoint verification is attempted even after a worker/controller failure.
3. **Underpriced scheduling imbalance.** The new project-owned scheduling adapter
   replaces the approximate helper's energy-window imbalance coefficient with
   the source real/reactive bus-imbalance coefficients and interval durations.
   The source case, pinned upstream package and official evaluator are unchanged.
   Tiny tests cover every coefficient for unequal-duration intervals and a
   counterexample where cheap imbalance would replace generator commitment.

One development assertion initially conflated energy-imbalance incentives with
reserve-driven commitment. The synthetic counterexample now has zero reserve
requirements to isolate the energy-penalty regression; no competition input or
acceptance constraint was changed. This was a tiny component test, not a full run.

## Frozen scope and launch gates

- C3E4N00617D2, scenario 002; source SHA256
  `d143b112b9d6959cc59a2c074b041f1b6dcfed4598539d8ae761ea48bba8d1c9`.
- 48 one-hour intervals, 617 buses, 94 producers, 405 consumers,
  853 AC branches and 562 source outages: 26,976 outage-interval checks.
- Source switching permission is enabled; candidate topology and transformer
  taps remain fixed-source heuristics, with no contingency-feedback reoptimization.
- HiGHS 4-thread whole-horizon scheduling/reserves; Ipopt/MUMPS AC refinement,
  one Julia/BLAS thread. Laptop CPU only. No saved/POP/competitor initialization.
- 1,800 seconds including process imports/JIT, raw loading, case preprocessing,
  factorization, independent/official checks and result serialization. Work cutoff
  1,530 seconds; final evaluation/finalization reserves 240/30 seconds.
- Preserve original pilot artifacts and its latch. One new exclusive latch.
- Pass `scripts/component_gate.py`, freeze/push all code and configuration,
  and report the read-only preflight before launching. No automatic further run.

Machine-readable current test evidence is `manifests/component_tests.json`.
The implementation commit and preflight will be copied into the run record.
The complete result and comparison will be reported separately after the pilot.
