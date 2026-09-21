# Cold 23,643-bus r11: scheduling completed, initial reserve extraction failed

**NO_VERIFIED_INCUMBENT**. Unlike r10, the constructor, economic LP, all 48
source reserve subproblems, and the complete original scheduling audit finished.
The downstream worker then failed in a separate initial reserve-allocation LP:
the pinned upstream wrapper tried to extract variable values when its solver
had zero available solutions. No AC interval or independent/official full-case
evaluation completed. This is not an infeasibility proof or a successful GO3 run.

## Frozen identity

- Implementation: `aed961088f99e2290fcf044a048132a973fcf3e0`.
- Case: C3E4N23643D2 scenario 003, input SHA256
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Config: `config/campaign_n23643_s003_r11.json`, SHA256
  `573850a3d4df25304d61d4a4db22711fe335940f8209ef1fd50c9025b6503ef6`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r11_20260921T043837Z`.
- Pre-run component gate: 78 stages, 160 Python tests, 16,535 Julia assertions;
  exact source/runtime/log-hash audit passed. Manifest SHA256
  `82d876e4bda9fe6e916ea69cb619be80f2434554a0316dd19a35d9f91f9557fa`.
- Native HiGHS library SHA256:
  `892447b910bab933e5fad23035f8f5c06cf25ac24f93be5b44633edb6e1bb349`.

This was one cold attempt. Only its identity and construction/master/scheduling
allowances changed from r10. FP64, source PMIN, all source data and constraints,
48 intervals, 26,870 contingencies per interval, tolerances, 7,200-second global
limit, 2,400-second final-verification reserve and memory/disk floors remained.
All nine numerical source-spool arrays matched r10's recorded hashes and sizes.
The exact-compaction and reserve-partition proofs passed.

## Timings and observed memory

| Stage | Wall seconds | Outcome |
|---|---:|---|
| Cold builder process | 894.115 | Complete unsolved source model exported |
| Exact compaction process | 194.558 | Original-model equivalence proof passed |
| Reserve partition process | 122.579 | Complete source partition |
| Construction native solve | 426.800 | Feasible integer master saved and audited |
| Fixed-integer economic LP | 142.817 | Original-master economic dispatch audited |
| Complete scheduling coordinator process | 718.429 | Includes both solves, recourse and original audit |
| End-to-end through serialization | **1,979.140** | **32 min 59.140 s; downstream failure** |

The coordinator row includes the construction and cost-LP rows; these must not
be added twice. Native reported solver times were 426.724778 and 142.743129
seconds respectively. The constructor processed one MIP node and 1,248,520
simplex iterations; the economic LP used 1,252,683 simplex iterations. The
constructor's first root LP began at 215.530258 seconds and reported about
209.49 seconds for the LP solve. Extending the former 300-second cap allowed it
to finish rather than cutting it off during that first LP.

Sampled end-to-end peak process-tree RSS was **15.616611 GiB**. The native-stage
minimum host-available RAM was **5.757309 GiB**. No memory-floor or global-deadline
stop occurred. Memory fitting these completed stages does not prove that later
AC and exhaustive evaluation stages will fit.

## Scheduling evidence, not a final competition score

- Construction point: original-master residual at most
  `1.6325429896824062e-10`; complete original-master audit passed.
- Economic point: original-master objective `456761491.3720234`, residual at
  most `6.000000010719653e-10`, and zero fixed-integer-pattern deviation.
- All 48 source reserve subproblems completed. The complete reconstructed
  scheduling model passed all 20,211,928 original rows, 19,323,456 columns,
  domains, and objective-agreement checks at the unchanged `1e-8` tolerance.
- Its **complete scheduling objective including reserve recourse** was
  `-20572608194.137283`. Therefore the positive master-only number above must
  not be presented as the complete scheduling objective or a GO3 score.
- The coordinator returned `source_feasible_constructed_schedule`, with no
  original economic MILP bound or gap. Native `OPTIMAL` phase labels concern
  the construction objective or restricted LP, not the original economic MILP
  or full nonconvex GO3 problem.

The large reserve-cost difference remains an optimization-quality concern.
AC refinement with joint source reserves had not run, so its eventual effect
and the final competition score remain unknown. No quality-target pass exists.

## Exact downstream failure and uncertainty

After restoring the scheduling result, `pilot_worker.jl:300` invoked the
separate initial `source_reserve_allocation` path. The local storage wrapper at
`reserve_storage.jl:19` called pinned upstream
`calculate_reserves_from_generation`. That function optimizes and immediately
calls `extract_data_from_reserve_model`, without checking for an available
primal first. The resulting error was:

```text
Result index of attribute MathOptInterface.VariablePrimal(1) is out of bounds.
There are currently 0 solution(s) in the model.
```

This extra initial LP had the registered two-second per-interval limit, but
native termination/primal status was not retained before the extraction
exception. The evidence does **not** establish whether it timed out, was
infeasible, or stopped for another solver reason. The full scheduling reserve
checks and this later allocation are different calls; the earlier 48 passing
subproblems do not prove this later call returned a solution. No infeasibility
conclusion should be drawn from a result-index exception.

The next implementation must guard and record status before reserve extraction
and address the initial reserve handoff without weakening source constraints.
The existing joint-schedule reserve reuse option is explicitly unverified until
the full-case checks; it must not be mistaken for a security certificate.
Final post-AC reserves, complete interval coverage, independent/official
exhaustive evaluation, score target and the two-hour limit remain mandatory.

## Retention

`evidence/campaign/campaign_n23643_s003_r11` contains 304 hash-checked compact
copies plus summary and retained-file inventory. All original 7,955,755,234
bytes, including primal vectors and source matrices, remain local. No files
were deleted. The r11 latch remains consumed; no restart or replacement was
launched while collecting this evidence.
