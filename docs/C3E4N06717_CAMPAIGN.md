# C3E4N06717D2 scenario 002: cold quality campaign

## Registration before the first attempt

Selected scenario **002**, the smallest numeric public Division 2 scenario,
before inspecting our solve quality. The archive contains 18 raw D2 scenarios:
002, 004, 005, 008, 010, 011, 014, 016, 017, 020, 026, 032, 038, 044, 050, 056,
062, and 068. Only the selected raw JSON was extracted. No provided POP solution
or earlier optimized point was retrieved or used.

- Source archive: <https://data.openei.org/files/5997/C3E4N06717_20231002.zip>
- Exact entry: `D2/C3E4N06717D2/scenario_002.json`.
- Archive ETag: `"23310f77-617cc5cb65f58"`.
- Raw bytes: 104,661,506. Extraction transferred 13,265,495 bytes by HTTP ranges;
  the preceding central-directory-only listing transferred 19,851 bytes.
- Raw SHA256: `bccfff47a3f6de9d28117d8c76aabf47716afb92a16982067764dcc6f34f769e`.
- The audited raw size exceeds the previous 64 MiB safety cap. A tested,
  network-specific 128 MiB cap now applies only to C3E4N06717D2. The 16 MiB
  compressed transfer cap and refusal of full-archive fallback remain unchanged.

The raw case passes the required-feature gate without changing any source value.
It has no startup-count windows or affine/equality P-Q capability devices, unlike
the preceding 6,049-bus case. The feature audit alone does not imply AC feasibility.

| Property | Value |
| --- | ---: |
| Buses | 6,717 |
| Producers / consumers | 731 / 5,095 |
| AC lines / two-winding transformers | 7,173 / 1,967 |
| Shunts / DC lines | 634 / 0 |
| Active / reactive reserve zones | 9 / 12 |
| Intervals / total duration | 48 / 48 hours |
| Source contingencies per interval | 2,670 |
| Required exhaustive contingency-interval evaluations | 128,160 |

## Frozen published reference

The unchanged official Final Event workbook is read-only. Comparison is the same
network, scenario, Division 2 and switching permission (`SW=1`). Eligibility uses
the published active and feasibility fields; missing scores, infeasible entries
and the ARPA-e benchmark are excluded. There are nine eligible competitors.

Source: <https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx>, `data` sheet.
Workbook SHA256:
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
Exact rows, UUIDs and eligibility fields are retained in
`manifests/campaign/published_C3E4N06717D2_s002.json`.

| Published rank | Team | Score | Published runtime (s) | Source row |
| --- | --- | ---: | ---: | ---: |
| 1 | YongOptimization | 798,048,810.838310 | 1,781 | 9897 |
| 2 | GravityX | 798,014,001.114725 | 7,215 | 3876 |
| 3 | GOT-BSI-OPF | 796,752,986.348886 | 1,044 | 3207 |
| 4 | quasiGrad | 791,263,521.853814 | 6,850 | 7221 |
| 5 | TIM-GO | 789,365,501.736817 | 4,116 | 9228 |
| 6 | Occams razor | 755,375,223.938404 | 4,416 | 5214 |

The requested minimum is **679,837,701.5445635** (90% of sixth place). We do not
exclude officially eligible rows based on a separately reported runtime; timing
boundaries can differ. Our own limit remains 7,200 seconds end to end. This is a
published-score comparison, not an official placement, hardware-matched speed
comparison or global-optimality certificate.

## First attempt protocol

`config/campaign_n06717_s002_r01.json` copies the successful 6,049-bus r03 numerical
settings without alteration. Differences are case identity, raw digest and
provenance paths only. The implementation includes the complete-residual rounded-
iterate guard, bounded numerical recovery and protected finalization budget.
No previous solution is imported. Within-attempt primal/dual transfer remains
allowed and logged. All 48 AC intervals and all source contingency checks must
finish; a partial horizon is not success.

The cold scheduling MILP has at most 3,600 seconds, subject to the global budget.
Continuous/rounded/recovery AC budgets are at most 90/240/360 seconds per solve,
again limited by time remaining. Reserve finalization has a protected 90 seconds.
The controller reserves 600 seconds for exhaustive verification and 30 seconds
for result finalization. Source PMIN, bounds, costs and all acceptance tolerances
are unchanged. Native early-stop statuses are never described as local/global
optimality. Source-priced overload penalties remain part of the score.

Before launch: complete fixture-only component tests, freeze and push the clean
revision, verify prior-network completion hashes and check physical disk space.
The permanent r01 latch permits one full cold attempt only. No full run has yet
been executed at the time of this registration.

The complete fixture-only gate passed before freezing: **73 Python tests and
776 Julia assertions**, plus seven complete tiny verification pipelines. Each
checked all nine fixture contingency-interval combinations with official hard
and physical feasibility. All six normal worker variants had exact 3/3 AC
interval coverage. Evidence: `tmp/pilot002_component_gate_cm9yu1_y` and the
hash-indexed `manifests/component_tests.json`. No competition-case solve was used
as a test or warmup.

## Completed r01: scheduling timed out without an integer incumbent

Frozen revision `f4fae8e021dd9e9728db7eb1ed2cc5a716b2bc4a` ran once cold.
The attempt ended normally under controller supervision after **4,526.428029 s**
(75 min 26.428 s), inside the two-hour end-to-end limit. The worker returned an
error because scheduling supplied no feasible integer point. AC refinement and
verification were not started. This is **not a proof of case infeasibility**.

| Measured item | r01 result |
| --- | ---: |
| Run status | NO_VERIFIED_INCUMBENT |
| Scheduling termination / primal status | TIME_LIMIT / NO_SOLUTION |
| Full objective / certified gap | unavailable / unavailable |
| Scheduling upper bound, subproblem only | 799,405,661.053180 |
| HiGHS API solve time | 4,130.641710 s |
| Native MIP report time | 4,099.02 s |
| Requested native scheduling time limit | 3,600 s |
| Reported scheduling model build | 110.757 s |
| Original variables / non-bound constraints | 6,774,624 / 6,473,756 |
| Presolved columns / rows | 2,870,631 / 1,351,501 |
| Presolved binary / continuous columns | 62,005 / 2,808,626 |
| LP iterations / processed nodes | 307,097 / 0 |
| AC intervals / exhaustive checks completed | 0 / 0 |
| Peak sampled process-tree RSS | 21.954704 GiB |
| End to end, including result serialization | 4,526.428029 s |
| Quality target | FAIL: no candidate, no verification |

The solver's native report prints `Gap 0%` alongside an infinite primal bound and
no solution. It is **not** a gap certificate. The project wrapper already guards
against this: objective, relative gap and native relative gap are null in the
saved scheduling record. No complete or feasible result is inferred from the
native gap line. The reported bound applies only to candidate scheduling, not to
the complete AC/security-constrained GO3 problem.

### Measured delay and timing limits

The native MIP progress trace was:

| Native elapsed (s) | Scheduling bound | Incumbent | LP iterations | Cut pool / LP cuts |
| --- | ---: | --- | ---: | ---: |
| 332.2 | 799,446,995.0375 | none | 297,244 | 0 / 0 |
| 1,771.2 | 799,411,665.1988 | none | 301,718 | 3,811 / 510 |
| 3,049.8 | 799,405,661.0532 | none | 307,097 | 6,464 / 739 |
| 4,099.0 | 799,405,661.0532 | none | 307,097 | 8,376 / 839 |

The intervals between these records were 1,439.0, 1,278.6 and 1,049.2 seconds.
The final interval increased cuts without completing additional LP iterations.
The native end profile attributes 217.10 s to one basis-free dual-simplex call
and 118.93 s to ten basis-based calls: about 8.2% of the native MIP time. An
analytic-centre IPX call on another thread took 277.15 s; concurrent timings must
not simply be summed as sequential wall time. Most delay was therefore in
non-LP root work, with the trace pointing to cut generation and associated root
processing. Finer internal timers are needed to separate those components.
There was no explored branch-and-bound tree.

The requested native limit was exceeded by about 499 s in the native MIP report
(531 s in the API runtime). Native limits are checkpoint-based, not a substitute
for the controller's external deadline. The global hard limit was not reached or
relaxed. Stage build/import/cleanup overhead also counts in the end-to-end time.
The worker did not persist its accumulated stage-timing dictionary before the
no-schedule exception, so no exact overall scheduling-stage wall subtotal is
invented from that missing artifact. Build, API, native and end-to-end values
above are separately measured.

The audited source for this installed HiGHS revision shows display lines around
root-separation calls and a `highs_analysis_level` MIP-timing flag of 128:
[root processing](https://github.com/ERGO-Code/HiGHS/blob/04024d701f/highs/mip/HighsMipSolverData.cpp),
[analysis flags](https://github.com/ERGO-Code/HiGHS/blob/04024d701f/highs/lp_data/HConst.h).
This source audit did not change the running solver or launch a diagnostic solve.

Complete failure evidence was hash-audited and retained at
`evidence/campaign/campaign_n06717_s002_r01/`; the full run occupies 305,843 bytes.
No data was deleted. Result SHA256:
`51d5dc952fc828d65fb732aadd961e0a2b1fa5d685bcca13fbf4b42937c6a820`.
Completion SHA256:
`89fd9f5b62bd4bd767d5ad45533292c46b3bba4774cdbfa447e1586dab930373`.
The 6,717-bus network is not marked complete, and the next network is not started.

## r02 design, registered before its cold attempt

The root bottleneck motivates an explicitly bounded, **within-attempt** commitment
construction, not initialization from r01, a competitor, POP, or another case.
The source model, joint reserves, PMIN, temporal constraints, costs and acceptance
tolerances are unchanged. Candidate construction is a heuristic, not a new proof
of full AC feasibility or optimality.

1. Build the same whole-horizon scheduling model from the immutable raw case.
2. For at most 180 requested native seconds, maximize producer-online hours under
   all original scheduling constraints. This auxiliary objective is explicitly
   distinct from source welfare. Restore the exact original objective in a
   `finally` block, even on a construction error.
3. Audit any complete finite integer point against every original scheduling
   row, variable bound and integer domain, with residual limit `1e-8`.
4. Temporarily fix all integer variables to this newly constructed pattern,
   solve the original-cost, joint-reserve LP for at most 600 requested seconds,
   then restore every original integer type, explicit bound and preexisting fix.
   Re-audit the point against the restored model. This restricted LP's bound is
   never substituted for a bound on the full scheduling MILP.
5. Save the extracted within-attempt schedule and audit immediately. Start a
   fresh native HiGHS MILP with the original objective and domains, no inherited
   restricted-LP basis, and the complete audited primal vector. Record interface
   readback and native log evidence separately; interface acceptance alone does
   not establish native acceptance. The economic MILP receives at most 600
   requested seconds, subject to the remaining absolute work deadline.
6. Retain the better locally audited original-model point. If the native solver
   returns no incumbent, the constructed point is not discarded. Selected-point
   objective, balance and provenance are separate from native solver statistics.
   A contradictory native infeasibility declaration stops the worker.
7. Continue the unchanged 48-hour AC/refinement, source reserve allocation,
   independent exhaustive security check, official evaluator and score gate.
   A scheduling point alone is never declared a successful GO3 solution.

The 7,200-second external end-to-end cap, verification and finalization reserves
remain unchanged. Native limits may overrun between solver checkpoints; the
external controller is still the hard backstop. Detailed HiGHS MIP timing is
enabled with analysis flag 128. Completed scheduling-stage timings are now
persisted before a no-schedule error and recovered by the controller.

This is a registered algorithm correction after the failed r01, not a repeated
timing sample of r01. Tiny tests cover source-objective/domain restoration,
exception cleanup, deleted-variable index holes, invalid/incomplete point
rejection, exact schedule extraction, native MIP-start acceptance, and retention
when the main MILP has no usable new point. A separate full tiny pipeline must
also pass before freezing and launching r02.

The complete r02 fixture-only gate passed: **74 Python tests, 823 Julia
assertions, and eight independently checked tiny pipelines**. Every pipeline
checked 9/9 contingency-interval combinations and passed official hard and
physical feasibility. All seven normal worker variants completed exactly 3/3
AC intervals. The cold-construction variant confirmed native MIP-start acceptance
and saved the scheduling timing snapshot. Gate evidence is
`tmp/pilot002_component_gate_p_s3wu_s`, with its exact source inventory in
`manifests/component_tests.json`. No full-case warmup or diagnostic solve occurred.

## Completed r02: stopped early after prolonged post-LP processing

Frozen revision `41d6157b3d79844d3650f5698f90eaa52ae77111` ran once cold.
The supervisor stopped only its owned Julia worker; the controller remained
alive to serialize the failed result. End-to-end time was **3,357.154322 s**
(55 min 57.154 s), **not** the 7,200-second deadline. No other optimizer remains
active. This is an incomplete attempt, not a proof of case infeasibility.

| Item | Observed r02 result |
| --- | ---: |
| Status / full-case objective | NO_VERIFIED_INCUMBENT / unavailable |
| Scheduling model build | 108.459 s |
| Original variables / non-bound rows | 6,774,624 / 6,473,756 |
| Auxiliary construction native MIP time | 49.78 s |
| Auxiliary construction API solve time | 74.359328 s |
| Construction `optimize!` wall time, including transfer | 310.291 s |
| Auxiliary producer-online-hours objective | 35,088 |
| Construction maximum original-model residual | 2.5011104e-12 |
| Audited scheduling constraints, including bounds/integrality | 18,970,652 |
| Fixed-commitment cost LP native time / iterations | 600.25 s / 32,711 |
| Cost LP result | TIME_LIMIT; no feasible returned point |
| AC intervals / exhaustive checks completed | 0 / 0 |
| Peak sampled process-tree RSS | 19.825191 GiB |
| End to end, including serialization | 3,357.154322 s |
| Quality gate | FAIL: no complete candidate or verification |

The construction maximized online hours, not source welfare. Its feasible point
had source scheduling objective approximately **-24.676 billion**, so it was not
an economically useful result by itself. The cost LP retained 266,326 primal
infeasibilities at its native limit; its printed objective is not a valid primal
score and is not reported as one here.

More than 30 minutes then elapsed after the native LP's final log without a
cost-phase completion record or the original economic MILP starting. The worker
continued consuming CPU. Read-only samples showed stable memory and no paging
reads, but do **not** identify the exact slow call. The uninstrumented interval
includes native return/cleanup, statistics extraction, and original-domain
restoration. It would be unjustified to attribute all of it to one of these.
The supervisor ended the attempt to diagnose this transition instead of spending
the remaining budget on it. No live code, limits, or tolerances were changed.

The construction point was held in memory and its residual audit was written;
no complete scheduling-candidate or GO3 solution file had been published before
the stop. This motivates earlier checkpoint publication and finer transition
events in the next revision. There was no verified incumbent to lose or archive.

Hash-audited evidence is retained at
`evidence/campaign/campaign_n06717_s002_r02/`, including the explicit supervisor
stop reason. The full small run and console log remain on disk; no files were
pruned. The result SHA256 is
`f0fa34c9ba186b8cfec457afcbf4ed039db3b5efc3ca685aec8d693df42dd775`.
The next network is still blocked by the 6,717-bus quality gate.

## Registered r03: cache-only transitions and explicit IPX cost LP

This correction keeps the original scheduling rows, bounds, objective, reserves,
AC method and acceptance tolerances. The attempt remains cold, with the same
7,200-second end-to-end deadline and 180/600/600-second requested construction,
fixed-commitment cost LP and original economic MILP limits.

- Publish the audited construction schedule before the cost LP, not after it.
  This is a within-attempt checkpoint, not a verified full GO3 incumbent or an
  input to a subsequent cold attempt.
- Empty the native optimizer while preserving JuMP's authoritative cached model
  before fixed-pattern edits and before restoring integer domains. All edits
  then apply only to the cache, followed by bulk transfer on the next solve.
  This prevents per-variable changes to a resident native model. It addresses a
  plausible overhead source, not an established attribution of r02's delay.
- Use explicit HiGHS `solver="ipx"` with crossover off and IPM tolerance 1e-10
  for the restricted cost LP. In the installed version, `solver="ipm"` selected
  HiPO during a tiny probe; it therefore is not used as a synonym for IPX.
  Main MILP options are restored and a fresh native model uses `solver="choose"`
  with simplex MIP relaxations. No restricted-LP bound is a full-MILP bound.
- Do not reconstruct LP dual bounds or gaps solely for logging. The installed
  solver can report an unknown LP status following dual postsolve warnings even
  when its primal is feasible. Such points require the unchanged independent
  audit against the restored original scheduling model. They are not described
  as optimal or as dual certificates. Full-case success still requires the
  separate raw-input checks, official evaluation and sixth-place score gate.
- Persist fine-grained solver-return, statistics, capture, cache-edit, audit and
  checkpoint events and partial timings even if the worker stops mid-stage.

The new tiny tests verify the native IPX log and nonzero barrier iterations,
empty-native/cache-only domain edits, exact restoration including exceptions and
forced LP timeout, early checkpoint ordering, skipped irrelevant LP dual queries,
native economic-MIP start acceptance, and restored main-MILP solver options.
Full-case execution is prohibited until the complete fixture-only gate passes
for this revision and its configuration and the frozen revision is pushed.

The full fixture gate subsequently passed: 75 Python tests, 859 Julia assertions,
and eight independently/officially verified tiny pipelines. Evidence is
`tmp/pilot002_component_gate_gpa88hnf`. Before any full r03 launch, the user
redirected work to a separate 6,049-bus speedup experiment. **r03 has not run**;
its one-run latch remains unclaimed. The larger-network campaign is paused,
not completed. These tested corrections are preserved before branching.
