# Cold 23,643-bus attempt r08: root-memory controls

Status: **NO_VERIFIED_INCUMBENT**. The first native master call reached its
registered 600-second wall deadline while the ordinary root LP was unfinished.
The memory guard did not fire. This is neither a successful solve nor an
infeasibility certificate. No AC interval or final contingency verification ran.

## Identity and unchanged contract

- Frozen/pushed implementation: `3d1359ff79ef9d3936ac1990aeb715e79c7338ab`.
- Configuration: `config/campaign_n23643_s003_r08.json`, SHA256
  `299b19a9420e23cba98cc04dd340dfdcd6be5c14122f577ebb1ed703867882e2`.
- Input: C3E4N23643D2 scenario 003, SHA256
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r08_20260921T001529Z`.
- Native library SHA256:
  `06fa04b2f66ae80f3446e8e2a95ad1bea09faa0414b3151c1764bbb6bf7395c8`.
- Complete source-matched gate: 73 stages, 152 Python tests, 15,451 Julia
  assertions; independent and official tiny pipelines passed.

The run was cold, retained FP64 and exact source values/PMIN, all 48 periods,
all 26,870 source contingencies per period, original tolerances, the 7,200-second
global limit, the 2 GiB host-availability floor and the 30 GiB disk floor. No saved
optimized solution, lower-precision approximation or feasibility repair was added.

The registered native controls were the objective-clique cap of 4,096,
`mip_compute_analytic_center=false`, and the existing upstream
`mip_root_presolve_only=true`. Initial MIP presolve remained enabled. The worker
recorded the exact library identity and both requested Boolean settings; native
options are set and read back before `Highs_run`. The log explicitly records
that the optional analytic-center calculation was skipped.

## Outcome and timing

| Stage | Measured seconds | Outcome |
|---|---:|---|
| Controller raw-case validation/loading | 2.794 | Complete; separate process exited |
| Cold builder process, including import/JIT and export | 886.856 | Complete; zero solver calls |
| Exact compaction process | 195.000 | Complete; original-model proof passed |
| Source reserve partition process | 122.340 | Complete; partition proof passed |
| Native coordinator | 608.594 | Stopped at first master-call deadline |
| End-to-end through result serialization | **1816.156** | **30 min 16.156 s; no verified incumbent** |

The native call began at epoch 1789950944.203 and was stopped at epoch
1789951544.3870907: **600.184091 seconds**, consistent with the external guard's
0.25-second polling interval. It did not consume the two-hour global budget;
the smaller preregistered master allowance ended first. The source work-stage
deadline was still later. No limits were changed during the run.

The following timing markers are nested within the native stage, not additional
end-to-end costs:

| Native checkpoint | Seconds from native solver start |
|---|---:|
| Initial presolve finished / setup initialization | 212.688169 |
| Setup and heuristic-column preparation complete | 216.704078 |
| Root-node evaluation begins | 307.123652 |
| Ordinary LP model loading begins | 334.227085 |
| Ordinary LP model loading completes | 334.693848 |
| First ordinary LP begins | 334.694018 |
| First ordinary LP completes | Not observed |

The first LP was still running approximately 265 seconds after its start marker
when the call deadline fired. Its inner progress logging was suppressed by the
pinned native implementation. Therefore the retained outer table's pre-LP
`LpIters=0` is **not evidence that zero iterations were performed**. There is no
returned inner-LP status or iteration count. Sampled CPU usage for the native
process totaled 587.5 seconds, so the process was CPU-active; this alone does not
provide iteration-level attribution or rule out paging.

The summary's `solve_calls=0` counts returned calls from completed stages. One
master call actually started and was interrupted; `interruption.json` preserves
its identity, requested budget, deadline and cleanup result. No integer incumbent
was returned/audited, and no objective, finite incumbent gap, dispatch or GO3 score
is claimed. The preliminary native log bound is not a final independent GO3
certificate.

## Memory observation, not a solved-memory claim

- End-to-end sampled peak process-tree RSS: **19.192272 GiB**.
- Denser native-stage sampled peak RSS: **19.070782 GiB**.
- Minimum host-available memory across 2,351 native-stage samples:
  **2.574329 GiB**, above the unchanged 2 GiB floor.
- Last native sample's private/committed allocation: **28,767,354,880 bytes**;
  this is not resident memory.
- The root-LP portion contains 1,025 memory samples, extending 265.238320 seconds
  beyond its start marker to the last sample.

r07 stopped at the memory floor during its first LP; r08 instead reached the
native-call deadline without a memory stop. This changes the observed limiting
gate, but does not prove the full LP or subsequent search fits the laptop.
The LP never finished, host background memory can vary, and sampled RSS is not
an allocation trace. No pure causal memory-saving percentage is asserted.

## Model fingerprints and cleanup

The r07 and r08 spool manifests have identical dimensions, objective sense and
offset, input hash, and hashes/sizes for all nine numerical binary arrays and
both row/column name sidecars. The original model contains 19,323,456 variables,
20,211,928 rows and 78,597,478 nonzeros. This comparison uses export-time recorded
hashes; the ordinary spool/compaction path also verifies its inputs.

The serialized `extraction.bin` metadata is not byte-identical and is not included
in the numerical-array equality claim. No claim of whole-directory byte equality
or successful large-case extraction/verification is made.

All owned Python/Julia processes were checked after termination and had exited.
The immutable r08 latch remains consumed. The archive at
`evidence/campaign/campaign_n23643_s003_r08` retains 144 copied compact evidence
files plus the summary and full retained-file inventory. Copies were hash-checked;
the original 7,273,613,666 bytes of run data remain local. Nothing was deleted.

## Next investigation under the active goal

The next useful change is to expose the ordinary root LP's progress, without
turning on expensive solver debug checks or changing model/tolerances. A larger
first-master allowance can then be tested within the unchanged global deadline
and reserved verification budget. r08's roughly 265 seconds inside the first LP
does not establish how much additional time would be sufficient, or whether
more time alone will help. Any next attempt needs its own registration/freeze
and applicable completed tests; r08 must not be silently rerun or relabeled.

The objective remains a fully verified 23,643-bus result on the existing laptop.
That objective has **not** been achieved.
