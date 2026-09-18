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
