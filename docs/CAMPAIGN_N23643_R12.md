# Cold 23,643-bus r12: reserve handoff fixed, first AC interval not converged

**NO_VERIFIED_INCUMBENT.** The scheduling constructor, fixed-integer economic
LP, all 48 source reserve subproblems, and original scheduling audit completed.
The previous initial-reserve extraction exception did not recur. The first AC
interval then exhausted its three registered solve allowances without meeting
the unchanged `1e-8` explicit primal-residual screen. Its checkpoint was saved;
the worker deliberately did not attempt intervals 2--48.

This was not an out-of-memory failure, a two-hour global timeout, an
infeasibility proof, or a successful GO3 result. No verified score is available.

## Frozen run and pre-run gate

- Implementation: `07124bb599a317c4d5497d0671ae720b09bcf97d`.
- Case: C3E4N23643D2 scenario 003, input SHA256
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Config: `config/campaign_n23643_s003_r12.json`, SHA256
  `0a2cdb742205f4a106de8ba9b95f1ad467c8c15777b4f975bdef2f5140b80c53`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r12_20260921T061534Z`.
- Full pre-run gate: 80 stages, 162 Python tests, 16,591 Julia assertions.
  Source/runtime and every stage-log hash matched. Manifest SHA256
  `c4f01204e245d80cbacd5e975efb08479ec072e8d2ab07d162cd426eca332c40`.
- All five tiny integration pipelines passed independent and official checking
  with 9/9 contingency checks, both feasibility flags equal to one, and
  objective agreement. These tests did not certify this large case.
- Native scheduling HiGHS DLL SHA256:
  `892447b910bab933e5fad23035f8f5c06cf25ac24f93be5b44633edb6e1bb349`.

The run was cold, CPU-only, and FP64. All source PMIN values, constraints, 48
periods and 26,870 source contingencies per period remained unchanged. The
global cap remained 7,200 seconds, with a 2,400-second evaluation reserve,
30-second serialization reserve, 2 GiB available-RAM floor and 30 GiB disk floor.
No frozen code/configuration was changed while the run was active. Its latch
remains consumed. No restart or duplicate solve was launched.

## What the r12 fixes accomplished

The initial reserve handoff reused only the complete 48-period, 10-product
reserve values produced by this attempt's scheduling solve. The recorded audit
covered all 18,005 devices, reported no external solution reads, no changed
source values and no additional initial optimization call. It explicitly
marked those values as **unverified** until AC/final reserve optimization and
full-case checks. Handoff time was 3.414 seconds.

The new bounded reserve-extraction guard was covered by component tests, but
the large run did not reach final reserve optimization. Therefore this attempt
does not establish large-case final-reserve runtime or convergence.

All nine numerical scheduling-spool arrays matched r11's recorded hashes and
byte counts. Row/column name files also matched. The metadata extraction file
had the same size but a different hash; it is not a numerical matrix array.
Exact compaction and reserve-partition proofs passed.

## Scheduling and overall time

| Stage | Wall seconds | Result |
|---|---:|---|
| Cold builder process | 881.850 | Complete unsolved source model exported |
| Exact compaction process | 197.611 | Equivalence proof passed |
| Source reserve partition process | 122.843 | Complete partition |
| Construction native solve | 424.849 | Integer master point saved and audited |
| Fixed-integer economic native LP | 142.435 | Master economic dispatch audited |
| Scheduling coordinator process | 715.760 | Includes both solves, reserve recourse and audit |
| Scheduling total reported by controller | 1,928.021 | Completed |
| First AC interval, all phases and overhead | 1,083.811 | Failed residual screen |
| Post-failure partial-candidate evaluation | 292.609 | Cancelled; no certificate |
| End-to-end through result serialization | **3,419.851** | **56 min 59.851 s; failed attempt** |

These rows overlap: the coordinator contains the two native solves and the
scheduling total includes construction/compaction/partition/coordinator. Do not
sum every row. Native HiGHS reported solve times were 424.772598 and 142.365577
seconds; their simplex iteration counts were 1,248,520 and 1,252,683.

The complete scheduling model had 19,323,456 variables, 20,211,928 rows and
78,597,478 nonzeros. Its reconstructed point passed the original rows, bounds,
integer domains and objective audit with maximum residual
`6.000000010719653e-10` at the `1e-8` tolerance. All 48 reserve subproblems passed.

The complete scheduling objective including reserve recourse was
`-20572608194.137283`, not the positive master-only objective
`456761491.3720234`. Neither is a verified GO3 score. Original economic MILP
bound/gap remained null: construction optimality and a fixed-integer LP do not
prove optimality of the original economic MILP or the nonconvex GO3 problem.

## Exact first-interval AC result

| Phase | Registered native limit (s) | Native Ipopt time (s) | Phase wall time (s) | Iterations | Audited maximum residual |
|---|---:|---:|---:|---:|---:|
| Continuous shunts | 90 | 92.302 | 182.912 | 40 | 8.296227444e-2 |
| Rounded shunts | 240 | 240.644 | 305.229 | 70 | 2.290763156e-3 |
| Adaptive-barrier recovery | 360 | 360.389 | 450.639 | 135 | 5.197593443e-5 |

All three phases returned `TIME_LIMIT` and `INFEASIBLE_POINT`, meaning their
returned iterates failed the point-feasibility test. That is **not** an
infeasibility proof for the mathematical model. Ipopt checks its phase limits
at iteration boundaries; these small native overruns did not approach the
separate global deadline.

The final residual was about 5,198 times the `1e-8` acceptance threshold. The
worker correctly rejected it rather than accepting a near-feasible point.
No AC interval passed. There is one attempted-interval statistics record, not
one successfully solved interval.

Both internal primal transfers covered all 643,822 original model variables.
The rounded phase did not receive duals from the infeasible first point. The
recovery instantiated a fresh optimizer, cleared stale dual starts and retained
the same objective, rows, bounds and rounded controls. It improved the residual
but did not converge within its allowance.

The first interval took 1,083.811 seconds overall versus about 693.335 seconds
inside native Ipopt. The roughly 390.476-second difference includes model and
derivative preparation, mapping, audits and other overhead. Existing logs do
not separately attribute all of that difference; it must not be reported as
factorization time or garbage-collection time without further instrumentation.

## Memory and terminal disposition

Peak sampled end-to-end process-tree RSS was **15.769821 GiB**. The minimum
available host RAM observed by the native-stage sampler was **5.818630 GiB**;
the coarser controller snapshots had a minimum of 5.949181 GiB. No RAM-floor or
disk-floor stop occurred. These are sampled measures, not allocator peaks; RSS
can include shared pages. Completing scheduling and this first AC attempt does
not yet prove memory safety across every later stage.

After the worker exited, the unchanged campaign controller started exhaustive
evaluation of the saved incomplete checkpoint. The agent stopped **only those
owned evaluation processes**, after checking process identity and the failed
first-interval record. This avoided further evaluation of an attempt that
could not pass the mandatory complete-horizon gate. No solver was interrupted
and the controller was left running to serialize its terminal result.

This action is explicitly recorded in `agent_stop_reason.json` as
`POST_FAILURE_VERIFICATION_CANCELLED`. Evaluation ran for 292.608548 seconds;
its record has `pass=false`, `complete=false`, `retained=false`, and no
objective. Neither independent nor official exhaustive verification completed.
No contingency-coverage count or official score is inferred from a partial log.

The final result SHA256 is
`ff5a64f37a4558b4af82951cb0b44b2d519ee9c9c70130e86e0b15dad503570c`.
The saved checkpoint SHA256 is
`6370f08f2a95dfeb65c953894c9163812c5777e12962cec1b4e94f1f29379c5c`.
The elapsed time is a failed attempt with an explicitly cancelled post-failure
evaluation, not a completed benchmark verification time.

## Retention and remaining work

`evidence/campaign/campaign_n23643_s003_r12` contains 524 hash-checked compact
copies plus its summary and retained-file inventory. The original 1,523 files
(8,331,414,075 bytes), including matrices and partial solution, remain local.
Nothing was deleted or relabeled successful.

The post-run archival-only change also retains AC console/phase audits, export
audits and verification disposition records. All 163 Python component tests
passed afterward. This does not replace the fresh source-matched full gate
required before any later changed-code experiment.

The next bottleneck to address is AC numerical convergence and first-interval
time allocation, with attribution of setup versus native solve time. Starting
with an appropriate barrier policy may avoid spending the first two phases on
the observed slow path, but that is a hypothesis requiring component tests and
a separately registered cold attempt. Incomplete-horizon evaluation should
also stop early with an explicit failed gate, not a certificate. FP64, source
physics, source contingencies, tolerances, final complete verification and the
quality target remain mandatory. This report does not register or launch a
replacement run.
