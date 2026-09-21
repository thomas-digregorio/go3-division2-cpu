# Cold 23,643-bus attempt r09: observed root-LP progress

**NO_VERIFIED_INCUMBENT**. The original economic scheduling master reached its
registered 1,100-second native-call deadline. It did not hit the memory floor
and did not return an infeasibility verdict. No AC interval or final exhaustive
security evaluation started; no objective score or finite incumbent gap exists.

## Frozen identity

- Implementation: `9e397e678cdc8cbc17663d5f77add4c36c64a9f4`.
- Case: C3E4N23643D2 scenario 003; input SHA256
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Config: `config/campaign_n23643_s003_r09.json`; SHA256
  `e02372aea11ae0629dfb3b77d3d9a89f8ff8207494be94b531ab656bfbfd639b`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r09_20260921T014354Z`.
- HiGHS DLL: `892447b910bab933e5fad23035f8f5c06cf25ac24f93be5b44633edb6e1bb349`.
- Pre-run source-matched gate: 76 passing stages, 155 Python tests, 16,498
  Julia assertions, independent and official tiny pipelines passed.

FP64, all source values/PMIN, 48 periods, 26,870 contingencies per period,
tolerances, 7,200-second global budget, 2 GiB RAM floor and 30 GiB disk floor
were unchanged. No external optimized start or automatic restart was used.

## Outcome and timing

| Stage | Wall seconds | Result |
|---|---:|---|
| Cold builder process | 869.319 | Unsolved source model exported |
| Exact compaction process | 194.730 | Equivalence proof passed |
| Reserve partition process | 122.827 | Complete source partition |
| Native master call | 1,100.020 | External deadline; first root LP unfinished |
| End-to-end through serialization | **2,298.479** | **38 min 18.479 s** |

The first root LP began 342.042590 seconds into the native solve. Its separate
flushed log ends at **756,963 dual-simplex iterations**, with 791,269 primal
violations (reported sum 70,127.5). These are intermediate perturbed-LP solver
diagnostics, not source-model feasibility measurements, a final score, a
certified original bound, or an infeasibility certificate. No root-LP completion
marker or returned integer incumbent exists. The outer MIP table's earlier
`LpIters=0` was a pre-LP snapshot, not the actual iteration count.

End-to-end sampled peak process-tree RSS was **18.908077 GiB**; the native-stage
minimum host-available memory was approximately **2.70 GiB**. The guard did not
fire. This shows the observed limiting gate was root-LP time; it does not prove
every subsequent stage would fit RAM or the two-hour deadline.

All nine original numerical spool arrays have matching exported hashes and
sizes between r08 and r09 (19,323,456 variables, 20,211,928 rows, 78,597,478
nonzeros). This is a manifest comparison, not a claim of whole-folder equality.
The normal spool/compaction path also checks its inputs.

## Evidence and next direction

`evidence/campaign/campaign_n23643_s003_r09` contains 145 hash-checked compact
copies plus the summary and complete retained-file inventory. All original
7,276,186,225 bytes remain local; nothing was deleted. Owned run processes had
exited after termination; the r09 latch remains consumed.

A cold feasibility-first scheduling constructor followed by a fresh
fixed-commitment economic LP is the next proposed experiment. This is a primal
heuristic, not a global scheduling bound. It must preserve every source row,
recheck reserve recourse and the complete original scheduling model, and still
pass the unchanged AC, exhaustive verification, score and deadline gates. A
restricted LP's bound must never be substituted for the original MILP bound.
