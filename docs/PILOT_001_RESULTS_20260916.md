# First GO3 Division 2 pilot: stopped with software failures, no final verified result

**Outcome: NO_VERIFIED_INCUMBENT.** One cold experiment was launched and stopped
at **197.398 seconds** including final result serialization, well below the
1,800-second deadline. It was **not** a timeout, disk-full event, or a solver
infeasibility declaration. No replacement experiment was started. All task-owned
solver/evaluator processes have exited. The frozen implementation is
[`3ad6ef25c64b08028b24596c38ca90a5696dbb71`](https://github.com/thomas-digregorio/go3-division2-cpu/commit/3ad6ef25c64b08028b24596c38ca90a5696dbb71).
Subsequent diagnosis/report commits do not change that implementation or its
recorded certificates.

## Scope, provenance and reuse

Case **C3E4N00617D2 / 002**, selected before any full solve. Input SHA256
`d143b112b9d6959cc59a2c074b041f1b6dcfed4598539d8ae761ea48bba8d1c9`.
48 one-hour intervals, 617 buses, 94 producers, 405 consumers, 853 AC branches,
22 shunts and 562 branch outages per interval. Switching is officially allowed;
this pilot's candidate search fixed source topology/taps. No POP, competitor,
previous-run or GO2 optimized solution was used.

The [GO2 audit](REUSE_AUDIT.md) inspected current code/evidence at `b5433e9`, not
an assumed old frozen revision. GO2 numerical techniques, absolute deadlines,
source identity and verified-incumbent policies were adapted conceptually; no GO2
source, environments, run trees or paper were copied or modified. Candidate model
functions came from the pinned, unmodified BSD-3 LANL GO3 library. The controller,
source contract, independent complex-AC/explicit-outage checker, manifests and
guards are new project code. HiGHS and Ipopt/MUMPS were explicitly selected.
The official evaluator was neither modified nor configured to invoke commercial
feasibility optimizations. Exact sources are in `manifests/sources.json`.

The [formulation contract](FORMULATION_AND_LIMITATIONS.md) describes applicable
GO3 constraints, conditional PMIN, time coupling, reserves, AC base physics and
prescribed linear security physics. This is not repeated GO2 and not an exact
PJM/CAISO market implementation. No full GO3 optimality certificate is available.

## What failed

### 1. Independent demand-benefit accounting

The initial candidate passed the official hard-feasibility check and the
independent hard constraints, including all **26,976** contingency-interval
checks. However, its objective-agreement gate failed by **64,919,806.2141**.
Our checker consumed raw consumer blocks in listed order. The official evaluator
negates consumer marginal benefits, then sorts marginal costs ascending,
equivalent to descending benefit order. This changed demand-benefit accounting;
the optimizer's disaggregated block formulation and official evaluator used the
appropriate economic ordering.

A post-run **tiny-only** counterexample reproduced the problem: at demand 1 pu,
blocks `(100, 0.5)` and `(1000, 1)` give official benefit 1000 per hour, while the
frozen checker computes 550. Over durations 0.5, 1.0 and 0.25 hours, the objective
discrepancy is 787.5. The preflight tests had single-block consumers and did not
cover this ordering case. The frozen checker was not changed and no certificate
was relabelled after the run.

### 2. Fatal live-status publication

At the start of interval 48, `os.replace(live_status.json.pending,
live_status.json)` raised **PermissionError / WinError 5**. The controller treated
this telemetry error as fatal, cancelled its Julia worker, and wrote the failed
run summary. Final reserve allocation and final exhaustive verification were
never reached. Forty-seven AC interval subproblems had completed; this does not
certify a completed horizon. The last serialized AC checkpoint corresponds to
40 refined intervals, with the remaining intervals carried from the schedule.

A throwaway Windows fixture reproduced the same error class by keeping the
target file open for reading during replacement. This supports a transient
read/replace sharing conflict; the exact external holder at failure was not
recorded. No ACL bypass or elevation was attempted. Live reads of status files
must not be able to abort optimization. Original exception/partial files remain
preserved.

### 3. Candidate scheduling configuration underprices imbalance

This is a separate quality problem exposed by the saved initial candidate, not
the final software exception. We enabled the LANL copperplate helper's relaxed
balance option. The pinned helper prices those slacks with `e_vio_cost=500`,
whereas this raw case has **P and Q bus-imbalance penalties of 1,000,000**. The
helper also aggregates this approximate penalty differently from the official
nodal objective. It is an inappropriate weak approximation for this case.

The saved schedule generates 1,834.719 MW against 6,610.264 MW of consumption in
hour 5. Commitment falls from 94 producers in the first four hours to mostly
16-17 afterward (one startup and 79 shutdowns across the horizon). This is
genuine commitment search, but poor scheduling quality. The large scheduling
objective and small MIP gap must **not** be mistaken for a good/full GO3 result.
The raw input and official penalty definitions were not altered.

## Tests and pilot results

Before launch: **26/26 Python tests**, **8/8 Julia checks**, and the tiny
end-to-end candidate passed both checkers (9/9 contingency-intervals).
These gates missed the two real-run failure modes above. Post-run diagnosis used
only tiny fixtures and saved records, not another full solve or case evaluation.
The diagnostics are in `evidence/pilot_001/diagnosis.json`.

| Metric | Recorded result |
|---|---:|
| Final project acceptance | **FAIL / no verified incumbent** |
| Final objective / score | **Unavailable: final candidate not completed/verified** |
| Initial candidate official raw objective | -9,146,513,684.699429 |
| Initial candidate score under published clipping rule | 0 |
| Initial official hard feasibility / physical feasibility | 1 / 0 |
| Initial independent hard feasibility | Pass |
| Initial objective-agreement gate | Fail |
| Initial exhaustive contingency coverage | 26,976 / 26,976 |
| Final exhaustive contingency coverage | Not performed |
| Maximum initial hard residual | 1.0045e-12 |
| Maximum initial P imbalance | 4.998800 pu = 499.880 MW |
| Maximum initial Q imbalance | 6.317229 pu = 631.723 MVAr |
| Maximum initial base overload | 0.906518 pu = 90.652 MVA |
| Maximum initial contingency overload | 6.240941 pu = 624.094 MVA |
| Maximum initial reserve shortage | 0 pu |
| AC interval subproblems completed | 47 / 48; all final solves LOCALLY_SOLVED |
| Sum of recorded AC final-solve iterations | 2,387; excludes preceding continuous-shunt solves |
| Peak sampled process-tree RSS | 3.944 GiB |
| End-to-end time through result serialization | 197.398 s |

Initial-candidate penalty contributions (not a completed AC-refined result):

| Penalty | Cost |
|---|---:|
| Real bus imbalance | 5,206,052,207.48 |
| Reactive bus imbalance | 4,110,788,638.20 |
| Base branch overload | 21,757.00 |
| Reserve shortfall | 0.00 |
| Worst contingency | 208,184.25 |
| Mean contingency | 1,177.66 |

Official hard-feasible does **not** mean physical/engineering feasible: these
penalties explain why an officially hard-feasible initial candidate is unusable
as a high-quality operating plan.

The approximate scheduling subproblem returned objective **169,450,826.572154**,
maximization bound **169,454,663.572154**, relative gap **2.2644e-5** (0.002264%),
one node and 43,679 simplex iterations. HiGHS labelled it optimal within the
configured 1e-3 gap. Those numbers concern the approximate copperplate problem,
**not a certified bound or gap for complete GO3**.

## Timing and hardware

| Stage | Seconds | Boundary |
|---|---:|---|
| Controller raw loading/feature gate | 0.089 | Included |
| Worker raw loading/preprocessing | 0.801 | Included; separate reread |
| Scheduling/model construction | 49.910 | Includes HiGHS native 29.533 s |
| Initial construction/reserve allocation | 9.271 | Included |
| Initial complete verification subprocess | 5.845 | Includes launch, independent 2.150 s, official 3.194 s |
| Independent contingency physics | 1.325 | Subset of independent verification, not additive |
| Completed AC interval wall times | 120.864 | 47 intervals; both shunt solves/model work |
| Final reserve processing | Not reached | |
| Final exhaustive verification | Not reached | |
| Final result JSON serialization, first write | 0.002 | Completion marker accounts for final writes/hash |
| **Total end-to-end** | **197.398** | Includes imports/JIT, orchestration, checkpoints and clean cancellation |

No phase times should be added twice. Native solver/verification subtimings are
shown as subsets. The total is from the completion marker; `result.json` also
records 197.3875 s before its final small rewrite/completion marker.

Laptop: Lenovo 83F5, Intel Core Ultra 9 275HX, 24 reported cores/logical CPUs,
33,752,997,888 bytes RAM (about 32 GiB installed). Native Windows 11; HiGHS
thread cap 4, Julia/BLAS/OpenMP cap 1. HiGHS 1.15.1, Ipopt 3.14.19/MUMPS,
Julia 1.10.11. Sampling-based RSS is not allocator peak and may count shared
pages more than once. Physical C: free space remained about 210 GiB; the 30 GiB
floor was not breached. No GPU or commercial solver was used.

## Same-case published comparison

Source: [Final Event workbook](https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx),
sheet `data`, exact C3E4N00617D2/scenario 2/SW=1 records, retained with source rows
and submission UUIDs in `manifests/published_scenario_002.json`.

| Entry | Objective | Published score | Reported runtime (s) | Source row |
|---|---:|---:|---:|---:|
| TIM-GO | 163,780,452.93 | 163,780,452.93 | 189 | 8860 |
| GravityX | 163,780,161.87 | 163,780,161.87 | 242 | 3508 |
| GOT-BSI-OPF | 163,779,883.86 | 163,779,883.86 | 141 | 2839 |
| YongOptimization | 163,769,973.12 | 163,769,973.12 | 161 | 9529 |
| Occams razor | 163,768,479.92 | 163,768,479.92 | 317 | 4846 |
| ARPA-e Benchmark | 163,637,410.32 | 163,637,410.32 | 592 | 163 |
| Our pilot, final | **Unavailable** | **No official submission** | **197.398 to failed termination** | N/A |

The published rule assigns `max(objective,0)` to a feasible solution and zero
otherwise. Thus the initial candidate's **computed rule score** would be 0;
this is not an official competition entry or a successfully accepted final run.
See [GO3 technical overview, section 8.1](https://arxiv.org/html/2411.12033v1#S8.SS1).
The same section describes dedicated PNNL Deception nodes for competition runs.
Exact per-node hardware was not established in this audit and is not fabricated.
Competition solver times and this laptop's end-to-end time have different
boundaries/hardware/budgets. **No speedup or successful score comparison can be
claimed from this failed pilot.** Division 2 allowed 7,200 s; this pilot allowed
1,800 s but ended early on an error. No percentage optimality gap is inferred.

## Retained artifacts and proposed next step

Local run directory:

`C:/Users/thoma/Documents/go3-division2-cpu/runs/C3E4N00617D2_s002_20260916T190451Z`

- `worker/candidate_schedule.json`: complete initial official-format output.
- `worker/candidate_ac_partial.json`: unverified last 40-interval AC checkpoint
  embedded in a full-horizon output; **not a final solution**.
- `verification/schedule/independent.json`: complete initial companion values,
  commitment/SU/SD, dispatch MW/MVAr/pu, reserves, both-end branch flows, objective
  components (subject to the known demand-benefit bug), and all outage identities.
- `verification/schedule/contingency_violations.jsonl.gz`: all positive initial
  contingency overload records; official summary/logs and failed certificate
  retained alongside it.
- `result.json`, `completion.json`, solver statistics, console log and pending
  status file: original timing/failure evidence.

About 32.4 MB of original run evidence is retained; nothing was pruned. The raw
input is separate and unchanged. `evidence/pilot_001/retained_manifest.json`
hashes every retained run file; compact results/diagnosis are committed. Keeping
these full original solutions makes later re-evaluation possible; certificates
alone would not suffice.

Next corrections should be made **before any approved replacement pilot**:

1. Correct consumer/producer block ordering in independent accounting, with
   permutation and multiblock negative/positive regression tests.
2. Make live telemetry publication safe under Windows readers; test concurrent
   reads, bounded deadline-safe handling and preservation/final checking after
   recoverable telemetry failures. Do not change permissions or bypass controls.
3. Correct the scheduling approximation's imbalance economics (or require
   balanced aggregate candidate schedules), preserving source P/Q penalties and
   interval weights in the actual evaluation. Add a tiny shortage/commitment
   regression so the cheap-slack undercommitment is caught before another pilot.

The first two remove demonstrated software blockers; the third is the most
important observed objective-quality issue. No further full run, larger case,
pricing experiment or GPU work is authorized by this report. Stop for review.
