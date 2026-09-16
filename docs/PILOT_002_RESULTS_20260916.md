# Replacement GO3 Division 2 pilot: verified completion

**The single authorized cold replacement completed in 554.844 seconds (9 min
14.844 s), with final objective 163,770,857.22572678.** Independent verification
and the unmodified official evaluator both passed. All **26,976** required
outage-interval combinations were evaluated, and the official `feas` and
`phys_feas` flags are both 1. This is a successful scoped prototype run, **not**
a global-optimality certificate or a zero-overload N-1 operating plan.

The frozen implementation was
[`b8bbc66f1d5bf7a28f8228c443624f614b915046`](https://github.com/thomas-digregorio/go3-division2-cpu/commit/b8bbc66f1d5bf7a28f8228c443624f614b915046),
pushed before launch. Later evidence/report commits do not change that algorithm.
No extra full solves, warmups, repetitions, commercial solvers, pricing or GPU
work were performed. All task-owned solver/evaluator processes have exited.

## Scope, reuse and fixes

Registered case **C3E4N00617D2 / scenario 002**; input SHA256
`d143b112b9d6959cc59a2c074b041f1b6dcfed4598539d8ae761ea48bba8d1c9`.
There are 48 one-hour intervals, 617 buses, 94 producers, 405 consumers,
853 AC branches, 22 shunts and 562 source branch outages per interval.
No old optimized solution, supplied POP, competitor solution or GO2 solution
was used as a start. Source initial conditions were allowed.

The [reuse audit](REUSE_AUDIT.md) examined GO2 revision `b5433e9` and its retained
evidence. It adapted validation, provenance, incumbent-retention and absolute-
deadline policies conceptually; it copied no GO2 numerical source or run tree.
The GO2 repository and paper remained untouched. The pinned BSD-3 LANL GO3
library supplies scheduling/AC/reserve model functions; this project supplies
the controller, source contracts, independent checker and scheduling adapter.
The upstream evaluator, schema and model package remain unmodified.

Three reported issues were corrected before the replacement:

1. Independent PWL accounting now orders producer blocks by increasing marginal
   cost and consumer blocks by decreasing marginal benefit, matching GO3 without
   changing raw arrays. Final objective disagreement is only **0.00013524**,
   below the registered arithmetic agreement threshold of **0.16377086**.
2. Active progress, statistics and checkpoints are write-once snapshots, avoiding
   the Windows read/replace sharing conflict. Every AC interval was checkpointed.
   The first verified solution remains in its own immutable hash directory.
3. Approximate scheduling now uses the source P/Q imbalance penalties with actual
   interval durations, instead of the helper's underpriced `e_vio_cost` setting.
   The corrected schedule has **zero aggregate P and Q imbalance**. This is not
   confused with nodal AC balance; the AC-refinement stage still has to establish it.

The raw case, exact PMIN, operating constraints, official penalties and acceptance
tolerances were not relaxed. The [model contract](FORMULATION_AND_LIMITATIONS.md)
describes actual multi-period GO3: conditional bounds, source commitment/time
coupling and reserves, normal-operation AC physics, and the prescribed simplified
branch-contingency physics. This is not repeated single-period GO2, and not GO2
corrective AC redispatch under each outage.

## Component tests and results

Before the replacement: **36/36 Python tests**, **25/25 Julia assertions**, and a
complete tiny worker passed. Its final independent and official checks covered
9/9 outage-interval combinations. Added regression tests exercise multiblock cost
ordering, unequal-duration source penalties, undercommitment incentives, concurrent
Windows readers, immutable retention and separate one-run latches. See
[test evidence](TESTS.md) and `manifests/component_tests.json`.

| Final metric | Result |
|---|---:|
| Project acceptance | VERIFIED_HARD_FEASIBLE |
| Official hard feasibility / physical feasibility flags | 1 / 1 |
| Independent hard feasibility / objective agreement | PASS / PASS |
| Raw objective | 163,770,857.22572678 |
| Computed score under the published rule | 163,770,857.22572678 |
| Global GO3 bound / certified optimality gap | Not available |
| Horizon completed | 48 / 48 intervals |
| Exhaustive security coverage | 26,976 / 26,976 outage-intervals |
| Maximum hard residual | 9.95093e-13 |
| Exact conditional PMIN/PMAX residual | 0 |
| Inter-interval ramp residual | 0 |
| Maximum P bus imbalance | 1.53624e-10 pu = 1.53624e-8 MW |
| Maximum Q bus imbalance | 1.85621e-9 pu = 1.85621e-7 MVAr |
| Maximum base overload | 0.855063 pu = 85.5063 MVA |
| Maximum contingency overload | 5.630092 pu = 563.0092 MVA |
| Maximum reserve shortfall | 0 pu |
| Producers committed per interval | 74 to 94 |
| Producer startups / shutdowns over horizon | 7 / 23 |
| Commitment changes during AC refinement | 0; fixed to the within-run schedule |
| Total generation range | 4,650.628 to 7,425.683 MW |
| Total consumption range | 4,580.667 to 7,291.300 MW |
| AC final-solve statuses | 48 / 48 LOCALLY_SOLVED |
| AC final-solve iterations | 2,644; excludes first continuous-shunt solves |
| Peak sampled process-tree RSS | 10.564 GiB |
| End-to-end time, including final verification/serialization | 554.844 s |

The first, pre-AC candidate was also fully evaluated and preserved. It was
officially hard-feasible but not bus-balance-feasible, with objective
**-9,288,417,648.816418**. Its source voltage state was not consistent with the new
dispatch. AC refinement produced the final positive objective; it is the final
candidate above, not the preliminary schedule, used for comparison.

### Permitted violations and objective components

**Passing GO3 does not require zero penalized overloads.** The official
`phys_feas=1` additionally checks P/Q bus balance, not the absence of every thermal
or reserve penalty. The nonzero overloads above remain a material limitation
if the goal later becomes strict zero-overload SCOPF.

Independent cost decomposition (agrees with the official total to 0.00013524):

| Component | Contribution magnitude |
|---|---:|
| Demand benefit, positive | 170,638,146.781880 |
| Production cost | 6,678,373.107355 |
| Online cost | 2,320.600000 |
| Startup cost | 725.000000 |
| Shutdown cost | 250.000000 |
| Reserve procurement cost | 0 |
| Switching cost | 0 |
| Real-imbalance penalty | 0.014520 |
| Reactive-imbalance penalty | 0.058132 |
| Base-overload penalty | 10,974.061867 |
| Reserve-shortfall penalty | 0 |
| Worst-contingency penalty | 171,979.758612 |
| Average-contingency penalty | 2,666.955803 |

Benefits enter positively; all costs are subtracted. GO3 aggregates the worst
and average contingency terms by addition. The total thermal penalty is
**185,620.776282**. Complete per-interval components and device values are retained.

### Scheduling certificate is not a GO3 certificate

HiGHS reports **TIME_LIMIT**, a feasible solution, scheduling objective
**164,084,486.30361447**, maximization bound **164,084,496.12184638**, and relative
gap **5.983644e-8**. It recorded 78,916 simplex iterations and zero completed
branch-and-bound nodes. The final reported gap is below the configured 1e-3,
but the recorded termination status is not rewritten as `OPTIMAL`.

These values apply only to the approximate copperplate scheduling model; they
do not certify the complete nonconvex, security-constrained GO3 optimum.
Its requested internal solver limit was 300 s; the returned solver-time statistic
was 305.993 s. This small solver-return overshoot did not approach the separately
enforced 1,800-second end-to-end boundary. No deadline was extended.

## Timing and laptop hardware

| Stage | Wall seconds |
|---|---:|
| Controller raw load / feature gate | 0.083 |
| Worker raw load / preprocessing | 0.866 |
| Scheduling, including model construction | 330.304 |
| Initial candidate / reserve processing | 9.909 |
| Initial independent + official verification subprocess | 6.179 |
| AC refinement, including projections/checkpoints | 187.984 |
| Final reserve processing / postprocessing | 5.134 |
| Final independent + official verification subprocess | 6.686 |
| Remaining imports, orchestration and finalization | 7.699 |
| **End-to-end** | **554.844** |

Nested timings, **not additional stages**: scheduling solver statistic 305.993 s;
AC interval model/solve wall times sum 170.202 s; recorded final AC solves sum
75.617 s; initial independent/official checks 2.114/3.459 s; final independent/
official checks 2.164/3.955 s. The final independent contingency-physics portion
is 1.319 s. Final result JSON serialization is 0.003860 s. The completion marker
includes the final result hash and is the reported timing endpoint.

Hardware: Lenovo 83F5 laptop, **Intel Core Ultra 9 275HX**, Windows 11, 24 reported
physical/logical cores, approximately 32 GiB installed RAM. HiGHS thread cap 4;
native log reports one MIP search worker and parallel search off. Julia/BLAS/
OpenMP caps 1. Julia 1.10.11, HiGHS 1.15.1, Ipopt 3.14.19 with MUMPS_seq 5.9.1.
Peak RSS sums sampled process-tree memory and may double-count shared pages;
it is not an allocator peak. Physical C: had about 210 GiB free at preflight
and remained above the 30 GiB floor. All new files are outside OneDrive.

## Matched Final Event comparison

[Published workbook](https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx),
sheet `data`; exact network **C3E4N00617D2**, scenario **2**, Division **2**, **SW=1**.
Source rows, submission identifiers and evaluator hashes are retained in
`manifests/published_scenario_002.json`. These are the top five feasible competitor
objectives for that matched case, plus the official benchmark.

| Entry | Raw objective | Score | Reported time (s) | Source row |
|---|---:|---:|---:|---:|
| TIM-GO | 163,780,452.93 | 163,780,452.93 | 189 | 8860 |
| GravityX | 163,780,161.87 | 163,780,161.87 | 242 | 3508 |
| GOT-BSI-OPF | 163,779,883.86 | 163,779,883.86 | 141 | 2839 |
| **Our replacement, local computed score** | **163,770,857.23** | **163,770,857.23** | **554.844 end-to-end** | N/A |
| YongOptimization | 163,769,973.12 | 163,769,973.12 | 161 | 9529 |
| Occams razor | 163,768,479.92 | 163,768,479.92 | 317 | 4846 |
| ARPA-e Benchmark | 163,637,410.32 | 163,637,410.32 | 592 | 163 |

Our objective is **9,595.701000**, or **0.00585888%**, below the best published
objective and **133,446.902129** above the published benchmark. Numerically it
lies between the third- and fourth-best published objectives. This is **not an
official placement, an optimality gap, or a timing speedup claim**.

The [technical overview, section 8.1](https://arxiv.org/html/2411.12033v1#S8.SS1)
describes a feasible-solution score of `max(objective, 0)` and competition runs on
dedicated PNNL Deception nodes. Our score is computed locally by that rule, not an
official submission. Exact competition per-node CPU/RAM was not established in
this audit; it remains unknown here. Published solver times and laptop end-to-end
times have different hardware/boundaries; the competition Division 2 budget was
7,200 s versus our 1,800 s. Historical evaluator compatibility and the unknown
historical schema hash are documented in the model contract, not silently assumed.

## Retained results and stopping point

Full local run:

`C:/Users/thoma/Documents/go3-division2-cpu/runs/C3E4N00617D2_s002_pilot_002_20260916T222357Z`

- Final complete official solution:
  `verified_incumbent/629134d5d1bf562af922a2eb8a5f6ce2e67127320c8ad235ec0484e347f55857/solution.json`.
- First accepted complete solution remains separately under
  `verified_incumbent/7f5c507eb40caf3e37010c0f3f60419c472293e085b8da81dfc5c18a8ff611db/`.
- `verification/final/independent.json`: every interval's commitment, startup/
  shutdown, actual dispatch including trajectories, MW/MVAr/pu and 100-MVA base,
  all reserve products, both-end branch flows, objective components and complete
  contingency identities. Bus voltages/angles and controls are in the full solution.
- `verification/final/contingency_violations.jsonl.gz`: detailed positive overload
  records; all official summaries/logs and the final certificate are alongside it.
- `result.json`, `completion.json`, `worker/console.log`, all interval statistics,
  48 full-horizon AC checkpoints, and immutable progress snapshots are preserved.

All **254** run files were hashed; **222,117,543 bytes** (about 222 MB) remain
local and ignored by Git. Compact results, certificates, summary and hashes are
tracked under `evidence/pilot_002/`. The archive operation performs no solve or
reevaluation. No source data, earlier pilot artifacts or GO2 files were deleted.
The first pilot's 23 registered file hashes were checked unchanged before launch.

The most useful next quality improvement is **contingency-aware refinement**:
feed the dominant outage penalties back into dispatch/AC improvement while
preserving time coupling, reserves, and the already verified incumbent. The
185,620.78 thermal penalty and large worst overload motivate that work; eliminating
penalties may require more costly dispatch, so no equal-sized objective gain is
promised. For speed, scheduling is the dominant stage at **59.5%** of end-to-end
time; the small exhaustive-screening time is not the bottleneck for this case.

Neither improvement, another full experiment, larger cases, GPU work nor pricing
has been launched. **Stop for user review.**
