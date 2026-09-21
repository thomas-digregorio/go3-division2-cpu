# Cold 23,643-bus attempt r10: constructor reached its sub-budget

**NO_VERIFIED_INCUMBENT**. The new online-status construction heuristic reached
its registered 300-second native-call deadline before returning a feasible
master point. This was neither a RAM-floor stop nor an infeasibility verdict.
The fixed-integer economic LP, hourly reserve recourse, AC refinement and final
independent/official verification did not start. There is no GO3 objective,
original economic MILP bound or certified gap to report.

## Frozen identity and retained contract

- Implementation: `58c849d9869e7aa56ae7d393efed6536c1ef4021`.
- Case: C3E4N23643D2 scenario 003; input SHA256
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Config: `config/campaign_n23643_s003_r10.json`; SHA256
  `a6c4c0d226ee59a9f3d419306f0f04182757c463c6a27a78b950b48ac0a5923a`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r10_20260921T032225Z`.
- HiGHS DLL: `892447b910bab933e5fad23035f8f5c06cf25ac24f93be5b44633edb6e1bb349`.
- Pre-run component gate: 78 passing stages, 159 Python tests and 16,535 Julia
  assertions. Independent and official tiny pipelines passed. These component
  results do not establish large-case feasibility.

FP64, source PMIN and all other source values, all 48 periods, all 26,870 source
contingencies per period, tolerances, the 7,200-second global limit, the 2 GiB
available-RAM floor and the 30 GiB physical-disk floor were unchanged. No
external optimized start or automatic restart was used. The single-use r10
latch remains consumed.

The original source model's nine numerical matrix, cost, bound and integrality
arrays have identical recorded hashes and sizes to r09: 19,323,456 variables,
20,211,928 rows and 78,597,478 nonzeros. The exact-compaction proof passed across
all original columns and rows. The new construction objective encourages
online intervals; it is explicitly not the original economic objective or its
lower-bound proof. Source economic costs remain in the exported model and were
to be restored by the subsequent fixed-integer LP.

## Outcome and timing

| Stage | Wall seconds | Result |
|---|---:|---|
| Cold builder process | 870.579 | Complete unsolved source model exported |
| Exact compaction process | 195.474 | Equivalence proof passed |
| Reserve partition process | 122.608 | Complete source partition |
| Constructor native call | 300.102 | External sub-deadline; root LP unfinished |
| End-to-end through serialization | **1,504.937** | **25 min 4.937 s** |

The two-hour global limit was **not** reached. The smaller, pre-registered
construction budget ended this attempt. Native-worker process wall time was
312.131 seconds including loading and orchestration. The guard's polling
interval was 0.25 seconds; the observed native-call overrun was 0.102 seconds.

The constructor completed presolve at roughly 117 seconds, completed setup at
roughly 121 seconds and attempted Feasibility Jump. It began evaluating the
root at 179.275 seconds; the first root LP started at 208.846 seconds. Only
about 91 seconds remained for that LP. No incumbent was returned before the
external deadline.

The flushed root-LP log ends at **554,701 simplex iterations**, with 691,612
primal violations and a reported violation sum of 7,064.17. These are
intermediate perturbed-LP diagnostics, not original-model residuals, a final
score, a valid primal, or an infeasibility certificate. The outer MIP table's
earlier zero iteration count is a pre-LP snapshot. Its construction-objective
bound is not an original economic MILP bound.

Sampled end-to-end peak process-tree RSS was **15.587978 GiB**. The finest native
worker memory record had a minimum host-available value of **5.821045 GiB**;
no memory guard fired. This establishes only that the observed stages fitted
the memory budget, not that unexecuted cost-LP, AC or verification stages will.

## Evidence and next decision

`evidence/campaign/campaign_n23643_s003_r10` retains 145 hash-checked compact
copies plus a summary and complete retained-file inventory. The construction
and inner root-LP logs, interrupted request identity, native-call deadline and
memory records are included. All original 7,272,149,253 bytes remain local;
nothing was deleted. All identified owned run processes were confirmed exited.

The next experiment must address the feasibility constructor's time allocation
or construction method rather than lower precision. This result provides no
basis for claiming the case infeasible or promising that simply extending the
constructor will succeed. Any later attempt needs its own registered identity
and must still pass the unchanged full scheduling, AC, exhaustive verification,
quality and global-deadline gates. No replacement attempt was launched while
archiving r10.
