# 4,224-bus cold quality campaign

The previous network passed in `campaign_n02000_s005_r04`; its retained result
and completion hashes now authorize this next network in the prescribed order.
This is not a repetition of that successful experiment.

## Registered input and comparison

Select **scenario 002**, the smallest numeric public Division 2 raw scenario,
before inspecting any result from our solver. The archive contains 24 scenarios.
Only `D2/C3E4N04224D2/scenario_002.json` was extracted by HTTP ranges from
<https://data.openei.org/files/5997/C3E4N04224_20231002.zip>. Transfer: 4,529,916
bytes. Decompressed raw file: 34,638,478 bytes. No supplied POP or optimized
solution was downloaded or read. Immutable SHA256:
`e61ef19ea11a20c88f44a3a2b69a4e6a7588e0df77c401766a495199f87e8855`.

There are 48 one-hour intervals, 4,224 buses, 478 producers, 1,673 consumers,
2,605 AC lines, 2,325 transformers, 436 shunts and no DC lines. The 2,313
source contingencies at every interval require **111,024** exhaustive checks.
Every one of the 2,151 devices has two startup-count windows. The first source
device permits at most two starts in each of [0,24) and [24,48). Another 462
devices (producers) have source affine P-Q capability bounds. All such source
rows remain binding; this is not a model with independent P and Q boxes alone.

The frozen official workbook has SHA256
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
The read-only spreadsheet audit preserves raw numeric values, exact row identity,
team, scenario, switching permission and evaluator provenance in
`manifests/campaign/published_C3E4N04224D2_s002.json`. The sixth-best eligible
score is **467,272,744.768504** (Electric-Stampede, source row 1664). The requested
minimum is **420,545,470.291654**. This is a score-quality target, not an optimality
gap certificate. Different contestant hardware/runtime boundaries prevent treating
the comparison as a matched performance benchmark or official placing.

## Source-feature coverage before launch

The original required-feature gate correctly refused this case before any solver
ran. Coverage is extended only with tiny-fixture tests:

- Maximum-startup counts use source windows at interval starts with the official
  half-open convention `begin - 1e-6 <= interval_start < end - 1e-6`. The pinned
  upstream constructor has a different tolerance and edge-case assertions. A
  project-owned adapter uses a private lookup copy to bypass only its startup
  window builder, then adds every original source window with the correct rule.
  Source inputs and all other temporal constraints are untouched. Empty windows,
  shared boundaries, unequal durations, violations and source immutability are tested.
- The independent checker now verifies affine reactive limits against **actual**
  real power, including startup/shutdown trajectories, online/transition status
  and correctly signed producer/consumer reactive reserves. The existing source
  scheduling/AC/reserve rows are retained and cross-checked on small fixtures.
- Independent residuals are compared against the unmodified official evaluator
  at exact and near-boundary cases. Equality P-Q capability, energy windows,
  special startup states, DC devices and other uncovered features still fail the
  explicit gate; none is silently omitted.
- Campaign retention now prefers a completely verified physical point over a
  higher-scoring hard-only point. This does not change scoring or optimization.
  Historical pilot ordering and completed run evidence remain unchanged.

## Registered first attempt

Retain the reserve-aware AC algorithm and guarded consumer dominance that passed
the 2,000-bus case, with original source PMIN, costs, limits and tolerances. Use
**simplex directly** for the scheduling LP relaxations, following the observed
HiPO solve error and native simplex recovery on the completed 2,000-bus attempt.
This is a new registered strategy, not a claim that simplex will necessarily be
faster on this different network. Keep the 1e-3 scheduling gap and four HiGHS CPU
threads. No GPU, commercial solver or imported start is used.

Allow at most 3,600 seconds for scheduling and 90 seconds per AC solver call
(two shunt-rounding solves per interval) to accommodate the larger network.
These caps do not reset or override the **7,200-second end-to-end deadline**.
Reserve 600 seconds for final exhaustive verification and 30 for serialization.
An incomplete pipeline or incomplete check cannot pass. The complete matched-
runtime component gate, clean frozen revision and push must precede the one
registered full cold run. No full 4,224-bus solve has been used as a warmup.

The completed component gate passed **69 Python tests and 356 Julia assertions**.
All six synthetic two-bus, three-interval pipelines passed official hard and
physical feasibility and independent exhaustive verification (9/9 checks each).
The new source-feature pipeline explicitly exercised four startup windows, a
P-Q-bound producer, source reserve co-optimization and direct-simplex scheduling.
Its immutable test logs are recorded by `manifests/component_tests.json`, with
an exact inventory of tested source/configuration/manifest hashes.

## First attempt: stopped after an unusable AC interval

Frozen implementation `87694c5040299e76ace622452bc429776f6507e3`, attempt
`campaign_n04224_s002_r01`, did **not** pass. End-to-end completion, including
independent verification of its saved checkpoint and serialization, was
**960.822473 seconds**. It was deliberately stopped early, not at the two-hour
deadline, and does not establish that the source case is infeasible.

Scheduling found a feasible commitment at objective 498,357,170.280954, bound
498,409,474.782750, relative gap 0.000104953846, in 102.344381 seconds of solver
time (169.399 seconds for that stage). This is only the scheduling subproblem.
Intervals 1, 2 and 4 completed AC refinement. In interval 3 the continuous-shunt
solve converged in 48.972 native seconds, with a 2.92e-10 constraint residual.
The rounded-shunt solve then hit its 90-second local cap (91.287 API seconds)
with an infeasible iterate and a 0.005569886 maximum native constraint residual.
The code had not transferred the converged first primal to the second solve.

The complete-horizon interval-4 checkpoint confirmed interval-3 P and Q balance
L1 residuals of 0.069521598 and 0.110357298 p.u. respectively. Neither subsequent
intervals nor reserve-only allocation can fix an earlier interval's balance.
Only the positively identified owned Julia worker was stopped; its controller
remained alive to verify and serialize. All 111,024 source checks completed on
the retained checkpoint, but official physical feasibility was **0**, and the
pipeline was incomplete. The checkpoint objective -32,198,787,420.319386 is an
unfinished failure record, not an acceptable completed score. The archive at
`evidence/campaign/campaign_n04224_s002_r01` preserves hashes, certificates,
statistics and the exact stop reason; full solutions remain local. No files
were pruned and no evaluation or solve was repeated to create the archive.

## Registered second attempt: same-interval primal transfer

`campaign_n04224_s002_r02` changes the numerical workflow, not source data or
feasibility tolerances:

- Capture every finite primal variable from the first AC solve **before**
  modifying any shunt bound. After rounding/fixing shunts, supply all variable
  starts on the identical resident model. Project only starts onto existing
  bounds; never alter PMIN or any other source bound to fit a start.
- Read back every MOI primal-start attribute and record complete map coverage.
  The installed Ipopt.jl wrapper (`MOI_wrapper.jl`, optimize implementation)
  copies these attributes to native `x`; a tiny zero-iteration Ipopt test
  confirms their consumption. This is a primal start, not a simplex basis or
  primal-dual warm start. No `warm_start_init_point=yes` claim is made.
- Record each continuous/rounded phase separately, including termination,
  iterations, API time and explicit model primal residual. A local solver
  status alone cannot pass the point. A limited solve may remain usable if its
  finite complete primal meets the 1e-8 local residual screen; independent
  full-horizon physical and exhaustive verification is still mandatory.
- If the rounded point fails that screen, save statistics and its full-horizon
  checkpoint first, then exit the worker immediately. The controller preserves
  earlier verified evidence and performs its normal final verification.

The attempt remains cold from raw source data: no r01 solution, previous
interval's voltage/dispatch point, competitor solution, dual or basis is loaded
as an AC start. The within-interval first solution is generated by this same
attempt. Scheduling, source rows, reserve co-optimization, source topology,
90-second individual AC caps and the 7,200-second global deadline are unchanged.
Tiny-fixture tests, a clean frozen commit and push precede this one replacement
attempt. Its outcome must be measured; the correction does not guarantee a pass.

The replacement's complete gate passed **69 Python tests and 395 Julia
assertions**. All six synthetic end-to-end pipelines passed official hard and
physical feasibility plus independent 9/9 exhaustive checks. The new startup-
window/P-Q fixture also verified complete primal-transfer coverage and both
phase residuals in every interval. Evidence is under
`tmp/pilot002_component_gate_92od8msu`, hash-registered in
`manifests/component_tests.json`. No full competition case was used in testing.

## Second attempt: transfer accepted, local convergence still failed

`campaign_n04224_s002_r02`, frozen at
`94ddf0b3b2005495a7948377ce8f51341f95b331`, completed its failure record in
**690.452695 seconds**. The primal transfer was consumed and its full variable
map was logged. Intervals 1 and 2 passed the explicit local screen. Interval 3's
continuous-shunt solve converged in 56.814 API seconds with a 2.93418e-10 maximum
primal residual. The rounded-shunt solve reached its 90-second cap after 201
iterations, with a 9.16706e-5 primal residual and roughly 1.41e12 unscaled dual
infeasibility. More time alone is not known to cure this numerical trajectory.

The automatic failure path saved interval 3 before exiting. No interval 4 or
later was attempted. The controller independently checked all 111,024 source
contingency/interval pairs on that incomplete checkpoint and serialized it.
Official physical feasibility was 0 and the quality gate failed. The unfinished
objective -32,948,543,069.83811 is not a completed scenario score. Complete
compact evidence is in `evidence/campaign/campaign_n04224_s002_r02`; original
outputs remain local. No data was deleted or reevaluated for the archive.

## Registered third attempt: primal-dual initialization and bounded allowance

The next cold attempt uses `within_interval_primal_dual_v1`. After a converged,
residual-verified first AC solve it captures finite primal and dual values before
rounding. Every current row's dual start is mapped by constraint identity, not
by assumed array positions. Only the known removed shunt-bound rows may be
discarded; newly fixed shunts receive zero initial multipliers. The separate
legacy nonlinear block retains its verified exact order. Unexpected row changes
raise errors. Complete MOI readback counts are logged for both primals and duals.
No duals from another interval, attempt or competitor are loaded. If the first
point is not converged and residual-verified, dual transfer is explicitly skipped
and the complete same-interval primal remains the only start.

As documented in the official [Ipopt options](https://coin-or.github.io/Ipopt/OPTIONS.html),
primal-dual initialization is enabled with `warm_start_init_point=yes`.
`warm_start_same_structure` stays `no`: fixing shunts changes the reduced
structure. Interior primal/slack/multiplier pushes are 1e-8 and initial barrier
parameter is 1e-6 for this second solve. These are initialization settings, not
relaxed source bounds, scoring rules or acceptance tolerances. The first AC
solve still uses the original cold/default initialization. These NLP duals are
solver starts, **not** a global lower-bound or optimality certificate.

The full component gate initially caught a small reserve-economic precision
error: a nominally converged tiny point cost 0.001414186 versus the independent
fixed-dispatch LP's 0.001202771. No full-size attempt was launched. Tightening
Ipopt's **unscaled complementarity stopping tolerance** to 1e-8 for the rounded
phase made the unchanged reference-cost test pass. Primal feasibility and the
independent acceptance tolerances were not relaxed. This stopping correction is
included in the new warm-start options and logged with them.

The continuous-shunt cap remains 90 seconds. The rounded phase receives at most
240 seconds and 1,000 iterations, with its wall allowance recomputed immediately
before that solve against the remaining work deadline. The external controller
still enforces 7,200 seconds including the reserved 600-second final verification
and 30-second serialization allowance. Ipopt iteration logging is enabled for
both phases. Source physics, penalties, PMIN, temporal/reserve constraints and
independent verification remain unchanged. This is a combined robustness/budget
experiment, not an isolated speedup ablation or a guarantee of convergence.

Tiny native zero-iteration probes verify actual transfer of active duals with
the correct signs under both objective senses and both JuMP nonlinear interfaces.
Tests also reject unknown/deleted row mappings and enforce the remaining-budget
cap. A complete component gate and frozen push precede the single full run.

The completed corrected gate passed **69 Python tests and 472 Julia assertions**.
All six tiny pipelines passed official hard/physical feasibility and independent
9/9 exhaustive verification. The source-feature pipeline transferred complete
primal and dual mappings in every interval. Evidence is hash-registered from
`tmp/pilot002_component_gate_u6np0plw` in `manifests/component_tests.json`.

## Third attempt: interval 3 recovered; interval 4 still failed

`campaign_n04224_s002_r03` used frozen revision
`9483df263b773e94e76c66aa421a4056b7aee5c8`. Its failure record finalized in
**1,011.194437 seconds**. Scheduling again obtained the same objective/bound and
gap, in 100.709141 solver seconds. The first two rounded AC phases converged in
7.258 and 7.108 seconds, with complete primal/dual coverage. These observations
are from a combined workflow/settings change, not a controlled single-factor
speedup measurement.

Interval 3's first phase hit 90 seconds, so its nonconverged duals were correctly
skipped. The primal-only rounded phase recovered in 69.840 seconds, returning
a 5.04532e-11 maximum model residual. Thus the earlier failure was not an
infeasibility proof. Interval 4 then exhausted both the 90-second continuous
phase and 240-second rounded phase. Final model residual: 4.88675e-6, above the
unchanged 1e-8 local screen. The interval took 335.075 seconds including model
work, diagnostics and both phases. The worker saved the complete-horizon
interval-4 checkpoint and stopped; the independent final check covered all
111,024 pairs but official physical feasibility was 0. The incomplete objective
-32,198,475,393.99063 is not an accepted completed score. Evidence is archived
under `evidence/campaign/campaign_n04224_s002_r03`, with original outputs retained.

## Registered fourth attempt: continuation inside the cold attempt

The preceding implementation reinitialized every hour's AC model with flat
voltages. `campaign_n04224_s002_r04` instead leaves **hour 1 cold** and seeds each
subsequent hour from the immediately preceding hour's locally residual-screened
primal, generated in this same attempt. It cannot load another attempt or a
competitor solution. Only scalar named-variable values are retained, not old
models, column positions, bases or previous-hour duals.

The project-owned adapter maps current voltage, angle, flow, device, shunt and
reserve variables by their unique names. It projects only start values onto
the **current** bounds, leaving source PMIN and every constraint unchanged.
Anonymous PWL variables are not matched by column position across hours: their
device balance rows, source widths and source objective coefficients are
validated, then a feasible block allocation is rebuilt for current-hour P and
prices. Scheduling-deviation starts are likewise recomputed. New variables get
current defaults; every current variable receives a finite primal start. Counts,
adjustments and the full model residual of the resulting start are logged.
The start may be infeasible under the new hour's conditions; it still must be
resolved and independently verified, and is never accepted merely by inheritance.

For these subsequent-hour first phases, ordinary primal/slack interior pushes
are 1e-8 and `mu_init` is 1e-6. `warm_start_init_point=no`: no previous-hour duals
are asserted valid. The same-interval rounded-shunt primal-dual policy is retained.
All source constraints, score penalties, acceptance limits, 90/240-second local
caps and the global 7,200-second deadline remain unchanged. This is another
registered numerical workflow experiment, not a new initialization from saved
results. Tiny tests exercise shrinking/expanding hourly limits and changes in
PWL block counts/prices, as well as invalid-state rejection and raw-input
immutability. Full component verification and a frozen push precede its one run.

The completed gate passed **69 Python tests and 520 Julia assertions**. All six
tiny pipelines again passed official hard/physical feasibility and independent
9/9 exhaustive verification. The continuation integration confirms hour 1 uses
cold defaults, with complete current primal vectors and matching immediate-prior
interval identities thereafter. Evidence is hash-registered from
`tmp/pilot002_component_gate_tc7_e26f` in `manifests/component_tests.json`.

## Fourth attempt: verified target achieved

The single cold `campaign_n04224_s002_r04` attempt used frozen, pushed numerical
revision `da1d7ab4a715225c98555597e5a7e9ec00981e50`. It completed all 48 hours,
reserve finalization, independent and official evaluation, and serialization in
**2,477.003961 seconds (41 min 17.004 s)**, within the two-hour end-to-end cap.
No prior attempt or supplied POP was used as a start. No successful run is repeated.

| Measure | Result |
| --- | ---: |
| Verified objective and score | 493,989,736.571029 |
| Sixth-best eligible published score | 467,272,744.768504 |
| Required minimum, 90% of sixth-best | 420,545,470.291654 |
| Score above sixth-best | 5.717644% |
| Official hard / physical feasibility | 1 / 1 |
| Independent contingency-hour checks | 111,024 / 111,024 |
| Maximum hard residual | 1.59362e-10 |
| Maximum nodal P / Q imbalance, p.u. | 2.03071e-11 / 4.01849e-10 |
| Absolute objective discrepancy, independent vs official | 0.030719 |
| Peak sampled process-tree RSS | 10.2719 GiB |

Objective agreement passed. All 48 hourly final model residuals were below 1e-8;
their maximum was 4.01847e-10. Native hourly termination was `LOCALLY_SOLVED`
for 45 hours, `ALMOST_LOCALLY_SOLVED` for hours 3 and 29, and `OTHER_ERROR`
for hour 5. Hour 5's native log says `Restoration Failed!`; its returned complete
point nevertheless had a 5.10247e-11 model residual and passed the final independent
and official checks. This warning is not reclassified as solver convergence.
Acceptance establishes verified feasibility and the published-score threshold,
not local stationarity at every hour or global optimality of the nonconvex MILP/NLP.

| Timing component | Seconds |
| --- | ---: |
| Scheduling stage, including model work | 170.228 |
| HiGHS scheduling solve API, included above | 102.526 |
| Initial reserves | 21.286 |
| Initial schedule verification, process wall | 94.028 |
| 48 hourly AC refinements | 2,060.494 |
| Final reserves and postprocessing | 16.634 |
| Final independent evaluator | 61.286 |
| Final official evaluator | 35.394 |
| Final verification process wall, includes preceding two | 98.780 |
| Complete end-to-end run | 2,477.004 |

Subtimings are nested, not an additive partition. Loading, runtime/JIT startup,
handshakes, writes, verification, and serialization count end-to-end. The
scheduling MILP returned objective 498,357,170.280954, bound 498,409,474.782750,
and relative gap 0.000104953846. That scheduling bound is **not** a global bound
for the final AC/security-constrained solution.

The GO3 objective includes base-overload penalties of 713,273.068383,
worst-contingency penalties of 1,230,909.757401, and mean-contingency penalties
of 697,511.185678. Maximum contingency overload was 8.454354 p.u. under source
scoring semantics. Reserve-shortfall cost was approximately zero (2.99760e-9).
This must not be described as zero-overload N-1 operation. All original penalty
terms and contingency evaluations are retained. The score lies between the
fourth- and fifth-highest eligible published scores for the same scenario,
but this is not an official placing or hardware-normalized speed comparison.

Compact evidence is hash-archived at `evidence/campaign/campaign_n04224_s002_r04`.
Full solutions, logs, interval statistics and independent residuals remain in the
original local run folder; nothing was pruned. Candidate SHA256:
`2f8145f8190023d63ac272c9b4fab665093fd2f33a49d59859fd4c9801f5d5a5`.
Result SHA256:
`7335ef109e91f7a98f5c147c6040952c302ec172b4d78d60d6717bb005cfc157`.
This verified completion authorizes progression to the 6,049-bus network.
