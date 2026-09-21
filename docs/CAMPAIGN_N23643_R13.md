# Cold 23,643-bus r13: derivative selection confirmed, AC convergence still failed

**NO_VERIFIED_INCUMBENT.** The single cold attempt finished in
**3,488.519688 seconds (58 min 8.520 s)**. Scheduling and its original-model
audit passed. AC interval 1 exhausted its three registered phase allowances
without meeting the unchanged `1e-8` residual screen. No AC interval passed;
intervals 2--48 were not attempted.

This is not an out-of-memory failure, a global two-hour timeout, an
infeasibility proof, a verified GO3 score, or a global-optimality certificate.
The backend-selection bug was fixed and confirmed on the actual large model;
the remaining convergence problem was not solved by this experiment.

## Frozen identity and gate

- Case: C3E4N23643D2 scenario 003, 23,643 buses, 18,005 dispatchable devices,
  48 one-hour periods and 26,870 source contingencies per period.
- Input SHA256:
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Frozen implementation: `630fd7fdcb89ab37703751f8cb76d90ef6e0d6f1`.
- Config: `config/campaign_n23643_s003_r13.json`, SHA256
  `2115cc6b5f3fcc61366e1d8771d516ed1754897b7bccd641ecffc37ac74479b0`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r13_20260921T081605Z`.
- Pre-run component gate: **83 stages, 166 Python tests, 16,640 Julia
  assertions**. All 207 source fingerprints, runtime identity and 123 stage-log
  hashes were checked, including five nested decomposition integrations.
- Component manifest SHA256:
  `1869faf8a35e1b15ceddfe87916c380eb8f6efe1992137ad1d92d8476e2a6782`.
- The final-source symbolic tiny pipeline passed independent/official checking
  for all 9/9 contingencies, both feasibility flags one, objective agreement,
  all three intervals and final reserves. This did not certify the large case.

The run remained CPU-only and FP64, cold from source conditions, without an
external optimized start, reused run spool or duplicate solve. Source PMIN,
operating constraints, periods, contingency set and acceptance tolerances were
unchanged. The 7,200-second global cap, 2,400-second evaluation reserve,
30-second serialization reserve, 2 GiB available-RAM floor and 30 GiB disk floor
remained in force. Code/configuration was not changed during the attempt.

## What changed and what was confirmed

The new opt-in policy selects the modern `MOI.Nonlinear.SymbolicMode` through
the supported optimizer attribute and enables the adaptive barrier from the
first phase. The old legacy differentiation keyword did not select the
backend for the pinned source's modern nonlinear constraints. See
[AC_NUMERICS_R13.md](AC_NUMERICS_R13.md) for the reproduced issue and tests.

Every large-case AC call, including the fresh recovery optimizer, reported
the instantiated `MathOptInterface.Nonlinear.SymbolicAD.Evaluator`, FP64,
unchanged structure/bounds and the requested adaptive policy. No backend
mismatch or silent fallback occurred.

Only four config fields differ from r12: the attempt ID, numerical policy,
a 600-second first-period continuous-shunt allowance, and the rule that an
incomplete/failed horizon is retained unverified without an expensive final
evaluation. Complete horizons still require exhaustive independent and
official verification. No acceptance criterion was weakened.

## Scheduling and timing

| Stage | Wall seconds | Result |
|---|---:|---|
| Cold builder process | 912.869 | Complete unsolved source model exported |
| Exact compaction process | 194.588 | Original-model equivalence proof passed |
| Source reserve partition process | 122.592 | Complete partition |
| Construction native call | 414.350 | Construction objective optimal, primal available |
| Fixed-integer economic native LP | 141.808 | Optimal for that fixed commitment |
| Scheduling coordinator process | 704.608 | Includes both solves, 48 reserve LPs and audits |
| Scheduling total reported by controller | 1,944.484 | Passed original-row/domain/objective audit |
| First AC interval, including all phases/overhead | 1,431.591 | Failed residual screen |
| End-to-end through result serialization | **3,488.520** | **Failed attempt; within global cap** |

Rows overlap and must not all be added. Native HiGHS solve timers were
414.272896 and 141.737025 seconds; simplex iteration counts were 1,248,520
and 1,252,683. All 48 source reserve subproblems completed. The source scheduling
model had 19,323,456 variables and 20,211,928 rows. The reconstructed point
passed the complete original audit with maximum residual
`6.000000010719653e-10`, below `1e-8`, and objective agreement.

Its scheduling objective including reserve recourse was
`-20572608194.137283`, identical to r12's scheduling objective. This is **not**
a verified GO3 score. The original economic MILP bound/gap are null:
construction optimality and a fixed-integer LP are not a proof for the
original economic MILP or the full nonconvex problem.

## Exact first-interval AC outcome

| Phase | Configured limit (s) | Ipopt algorithm wall (s) | Optimizer-reported time (s) | Optimization API wall (s) | Iterations | Audited maximum residual |
|---|---:|---:|---:|---:|---:|---:|
| Continuous shunts | 600 | 600.564 | 609.333 | 641.458 | 248 | 4.946453475e-3 |
| Rounded shunts | 240 | 242.872 | 254.298 | 254.298 | 89 | 5.658237701e-4 |
| Fresh numerical recovery | 360 | 361.513 | 369.731 | 398.870 | 129 | 1.908807238e-5 |

All returned `TIME_LIMIT` with `INFEASIBLE_POINT`. These labels describe the
returned iterates, not a proof of model infeasibility. The final residual is
about **1,909 times** the required threshold. Transient lower values in the
iteration log are not independently checked final points and are not accepted
as successful solutions.

The first model build took 36.744 seconds. Explicit residual audits took
16.604, 16.734 and 15.219 seconds. The complete first-interval wall time includes
these audits, model construction, optimizer setup, starts, rounding and other
wrapper work; it must not be called pure numerical-solve time.

The native `OverallAlgorithm` timing blocks totaled 1,204.949 wall seconds.
The nested `PDSystemSolverTotal` blocks totaled 865.582 seconds, about 72% of
that time. This identifies the primal-dual linear-system solver block as the
largest recorded native block; it does not isolate factorization alone or
prove that derivatives are now optimal. These nested blocks are not additive
to the algorithm totals. Small algorithm-limit overruns and optimizer/API
overhead are separately visible above; the overall run stayed below 7,200 s.

Both internal starts supplied all 643,822 primal values. The rounded phase
received no duals from the unconverged first point. The recovery instantiated
a fresh optimizer and cleared 1,697,950 dual-start attributes. First-to-rounded
mapping adjusted 26,995 start values to original bounds; recovery mapping
required no such adjustment. These are start adjustments, not changed source
bounds. Neither guarded phase requested early acceptance or passed an original
residual probe.

## Memory, verification and clean exit

- Peak controller-sampled process-tree RSS: **15.778309 GiB**.
- Minimum available host memory among 6,681 retained native-process memory
  samples: **5.927299 GiB**, above the 2 GiB floor. This is the sampled minimum,
  not a claim of continuous measurement of every process stage.
- No RAM-floor, disk-floor or global-deadline stop occurred. All owned run
  processes were confirmed exited after completion.
- Successful AC intervals: **0/48**; one attempted-interval record.
- Final reserve optimization and full independent/official verification were
  not reached. None of the required **1,289,760** complete-candidate
  contingency checks is claimed as certified.
- The incomplete checkpoint is explicitly **UNVERIFIED**. The controller
  correctly skipped final evaluation and reported `NO_VERIFIED_INCUMBENT`.
- Verified objective/score, full-model bound and full-model certified gap:
  **not available**. The existing quality target therefore failed, not passed.

The compact archive `evidence/campaign/campaign_n23643_s003_r13` contains
522 copied evidence files plus its summary and retained-file manifest. Copy
hashes were checked. The original 1,520-file, 8,177,378,381-byte run remains
local; no files were deleted. Result SHA256:
`ac0cb41ecb10daa18b7d8486ebdbe5d104de356b2b04a92d8f74cc7b3d3c6d3b`.
The r13 latch remains consumed. No replacement full-case run was launched
as part of this result archival.
