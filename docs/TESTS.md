# Component-test evidence

All tests use an original two-bus, three-interval synthetic fixture, with
durations 0.5, 1.0 and 0.25 hours, parallel lines, a transformer, shunt,
producer, consumer, reserve zones and three source-style outages. No real
competition-case solve is a component test.

## Original pilot 001 (historical gate)

On 2026-09-16, before the original `3ad6ef2` pilot:

- Python `unittest discover -s tests -v`: **26/26 passed**, 1.030 s.
- Julia `scripts/test_solver.jl`: **8/8 passed**, 26.0 s including fixture
  model/JIT work. HiGHS 4-thread scheduling followed by 4-thread reserve LPs
  succeeds; Ipopt/MUMPS returns `LOCALLY_SOLVED` for the AC fixture.
- Tiny whole-worker integration: 3 intervals completed. Both independent and
  unmodified official checks passed, with 9/9 contingency-interval checks.
  Objective 1732.0994148700997; objective discrepancy 1.25e-11;
  maximum P imbalance 1.80e-13 pu, Q imbalance 2.20e-14 pu, hard residual 0.
  The final whole-worker integration also used the final 4-thread HiGHS settings
  and passed in 35.002 s including process imports/JIT. Its independent plus
  official verification process took 0.834 s. These tiny-fixture times are not
  competition-case performance results.

Covered gates: exact conditional PMIN/PMAX, initial minimum up/down times,
startup/shutdown trajectories, ramps over unequal intervals, unsupported energy/
startup features rejected, reserve headroom/eligibility, complex AC losses/taps/
phase shifts/shunts, discrete controls, source PWL/interval weights, worst-plus-
average contingency penalties, UID/field/interval serialization, immutable input
hashes, negative official bound/ramp/reserve tests, independent validation,
OneDrive/storage guards, nonfinite/partial/inferior candidate rejection, exclusive
single-pilot latch, an absolute budget that cannot reset between stages, and actual
cancellation of an owned sleeping child process.

Optional plotting is not installed; the evaluator's `cannot load matplotlib`
message is nonfatal. Its CSC-conversion warnings do not indicate failed checks.
No commercial optimization is invoked by the evaluator adapter.

Retained development evidence is under ignored `tmp/`; the full pilot's evidence
will be separate under `runs/`. Passing tiny tests is a launch prerequisite, not
evidence that the real-case pilot has passed.

## Authorized replacement 002

The current machine-readable gate is `manifests/component_tests.json`.
All stages passed on 2026-09-16, before any replacement competition-case solve:

| Stage | Result | Wall time |
|---|---|---:|
| Official synthetic fixture creation/check | PASS | 0.676 s |
| Python component tests | 36/36 PASS | 1.268 s |
| Julia scheduling/AC and penalty assertions | 25/25 PASS | 30.791 s |
| Complete tiny worker, 3 unequal-duration intervals | PASS | 35.427 s |
| Independent and official final check | PASS, 9/9 outage-interval checks | 0.813 s |

Tiny final objective: 1732.0994148700997. Independent/official difference:
1.25e-11; maximum hard residual 0; maximum P/Q imbalance 1.80e-13/2.20e-14 pu.
These are synthetic-fixture development timings, not competition benchmarks.

Added regressions cover producer/consumer marginal-block ordering and raw-array
immutability; held/open and concurrent snapshot readers; preserving the first
verified incumbent when a better one arrives; independent authorization latches;
latest fully published checkpoint selection; refusal to replace immutable files;
real/reactive source-penalty coefficients over unequal-duration intervals; and
a cheap-imbalance commitment counterexample with reserve drivers isolated.

All 23 retained files listed for pilot 001 were also rehashed unchanged before
the replacement. That was an integrity check, not a rerun or re-evaluation.
