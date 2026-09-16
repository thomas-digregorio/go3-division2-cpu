# Component-test evidence before the single pilot

All tests use an original two-bus, three-interval synthetic fixture, with
durations 0.5, 1.0 and 0.25 hours, parallel lines, a transformer, shunt,
producer, consumer, reserve zones and three source-style outages. No real
competition-case solve is a component test.

On 2026-09-16 (final machine-readable gate: `manifests/component_tests.json`):

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
