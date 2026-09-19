# C3E4N08316D2 scenario 103: original-route cold campaign

## Direction, source and selection

The user requested one 8,316-bus scenario followed by one 23,643-bus scenario,
using the original iterative algorithm and setting aside the recent DAYZER-style
speedup route. Six-thousand-seven-hundred-seventeen buses is explicitly deferred,
not marked successful. Speedup r08 is preserved at `4b90fde`, with passing
component tests but no full attempt. No earlier solution supplies initialization.

Choose scenario **103**, the smallest numeric public Division 2 scenario, before
inspecting our solve quality. A central-directory-only archive listing transferred
8,360 bytes and identified 24 raw scenarios. Only this raw JSON was extracted.
No supplied optimized POP, other raw scenario, or full archive was downloaded.

- Source: <https://data.openei.org/files/5997/C3E4N08316D2_20231002.zip>.
- Exact member: `D2/C3E4N08316D2/scenario_103.json`.
- ETag: `"13dc6fff-617cc5d314448"`; archive bytes: 333,213,695.
- Raw bytes: 89,615,924; compressed member bytes: 11,729,568; CRC32: `f2887789`.
- Extraction transferred 11,737,991 bytes and verified the ZIP member CRC.
- Raw SHA256: `43c169a1448da751be5e9fc04447f9088f1802866f5e591ed72777b2496a46a3`.
- The audited size requires a network-specific 128 MiB raw cap, tested before
  extraction. The 16 MiB HTTP transfer cap and refusal of full-download fallback
  remain unchanged. All paths are local and outside OneDrive.

| Source property | Value |
| --- | ---: |
| Buses | 8,316 |
| Producers / consumers | 1,128 / 4,457 |
| AC lines / transformers | 7,723 / 4,249 |
| Shunts / DC lines | 1,179 / 0 |
| Active / reactive reserve zones | 7 / 7 |
| Hours | 48 |
| Source contingencies per hour | 6,289 |
| Required contingency-hour checks | 301,872 |
| Devices with startup-count windows | 5,585 |
| Devices with affine P-Q bound capability | 979 |

The raw feature gate passes. Energy windows, startup-state lists, P-Q equality
capabilities and additional branch shunts do not require new support on this
selected case. This audit establishes supported input features, not feasibility.

## Frozen score reference

Read-only source workbook: <https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx>,
`data` sheet, exact network/scenario, Division 2 and SW=1. Workbook SHA256:
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
The extraction preserves source rows, submission UUIDs and eligibility fields
in `manifests/campaign/published_C3E4N08316D2_s103.json`; it never rewrites or
recalculates the official workbook. Inactive/infeasible/missing rows and the
ARPA-e benchmark are excluded, leaving nine eligible competitors.

| Rank | Team | Score | Published seconds | Source row |
| --- | --- | ---: | ---: | ---: |
| 1 | YongOptimization | 1,155,744,613.048660 | 3,355 | 9966 |
| 2 | GOT-BSI-OPF | 1,155,739,876.567820 | 2,243 | 3276 |
| 3 | GravityX | 1,154,454,653.980830 | 4,683 | 3945 |
| 4 | TIM-GO | 1,152,515,437.868380 | 2,860 | 9297 |
| 5 | quasiGrad | 1,127,723,112.494900 | 6,851 | 7290 |
| 6 | Occams razor | 1,025,576,419.277920 | 5,338 | 5283 |

Required score: **923,018,777.350128**, 90% of sixth-best. This is a source-matched
quality target, not global optimality, an official placement, or a matched-hardware
timing comparison. All source penalties remain in the score.

## r01: registered before any full solve

`config/campaign_n08316_s103_r01.json` selects the original successful 6,049-bus
`cfe7ea0` numerical policy: joint whole-horizon HiGHS scheduling with simplex
relaxations and a 1e-3 scheduling gap; guarded eligible-consumer dominance;
reserve-aware Ipopt/MUMPS AC refinement; same-hour shunt primal/dual repair;
previous-screened-hour primal continuation inside this attempt; bounded adaptive
recovery and the original audited feasible-point stopping guard. No linearized
correction stage or constructed-commitment scheduling seed is enabled.

This is not a claim that the executable revision is `cfe7ea0`: the current
revision retains newer, disabled paths and additional provenance/logging. A
registration regression compares every numerical configuration field with the
saved successful 6,049-bus configuration, allowing only case identity, explicit
off defaults, the authorized ordering policy and the stated verification reserve
to differ. Read-only source review confirms that the original reserve-aware
model construction, ordinary scheduling solve and same-attempt interval start
remain the selected branches. All applicable fixture regressions still run.

Use the same maximum scheduling/continuous-AC/rounded-AC/recovery allowances:
3,600/90/240/360 seconds, each subordinate to the remaining global clock. Keep
the original 240-second initial verification allowance and 90-second final
reserve allowance. Increase only the final exhaustive-verification reserve from
600 to 900 seconds because this case has 301,872 checks versus 187,296 on 6,049.
That reduces optimization time; it does not extend the 7,200-second hard total.
Serialization retains 30 seconds. Raw loading, process/JIT, construction, solves,
checks and serialization count end to end. Setup/tests/downloads are separate.

Source PMIN/PMAX, all temporal/reactive/reserve constraints, exact costs and
penalties, topology/transformer candidate policy, official evaluator, and final
tolerances are unchanged. Passing requires all 48 refined hours, independent
hard feasibility and objective agreement, official feas=1 and phys_feas=1, all
301,872 checks, the quality target, and completion before the two-hour deadline.
Feasible points are not called globally optimal; GO3's penalized overloads and
reserve shortages remain reported. The original verified runs remain untouched.

Run tiny component tests and push the tested frozen revision before claiming
this attempt's one-use latch. No full-case diagnostic solve, warmup or duplicate
timing sample is permitted. Iterate only with a separately registered, tested
correction if necessary. About 191 GiB was free during source registration, so
no pruning was needed or performed.

### Completed pre-run component gate

The exact r01 source/configuration inventory passed all 39 stages: **87 Python
tests and 1,202 Julia checks**. All 14 synthetic pipeline certificates completed
their nine required contingency-hour checks, independent hard feasibility and
objective agreement, and official `feas=1` / `phys_feas=1`. The gate used only
tiny fixtures, not a competition-case solve; stage times totaled 923.800 seconds.

- Evidence directory: `tmp/pilot002_component_gate_8ztv372e`.
- Component manifest SHA256:
  `d5822cc137a8c7c1ba5368bba5e9690a00089b3c650c20108e972b2fbbf11c26`.
- r01 configuration SHA256:
  `de3de0b794c1525cddf1ca79f0a00f7eb088f6a017c46f8fc4d890dca068bb57`.
- All 114 covered source/configuration files were rehashed and matched the gate.
- Saved 2,000-, 4,224- and 6,049-bus completion evidence was revalidated; no
  previous solution is a start. The r01 one-use latch was still absent.

These are pre-run checks, not evidence that the full 8,316-bus case has passed.

### r01 measured result: stopped for host memory pressure

Frozen implementation `cc27679d34c46a24953acf1cdb2c561c8b44bc03` was pushed,
passed preflight and ran once cold. It stopped at **517.085 seconds (8m 37s)**,
well before the two-hour limit, with **NO_VERIFIED_INCUMBENT**. No AC hour or
full-case verification completed. This is neither a successful solution nor
a proof of infeasibility.

The unreduced scheduling model had 6,194,016 variables and 6,327,922 non-bound
constraints. Construction took 86.099 seconds; additional native model transfer
preceded HiGHS presolve. Native presolve took about 123 seconds and reduced it
to 1,701,087 columns, 806,476 rows and 4,577,161 nonzeros, including 132,540
binaries. The last logged scheduling bound was 1,226,874,664.853 with no incumbent;
that is not a bound certificate for the full GO3 AC/security problem.

The controller sampled a peak process-tree RSS of **21.013 GiB**. At the manual
safety-stop decision, Windows reported 48 MiB available physical memory, 98%
memory commitment, 3,820 pages input/s and 1,000 page reads/s. The owned Julia
worker had most recently reported about 22.67 GiB private memory. After checking
its PID and controller parent, only that worker was terminated. The controller
remained alive to serialize result and completion records. No unrelated process
was stopped, no file was deleted, and no automatic retry occurred. Afterwards,
Windows reported 22,213 MiB available and 45% commitment.

HiGHS also emitted large-cost/small-bound scaling warnings, retained verbatim in
the native log. They were not treated as an infeasibility diagnosis or permission
to change source values. The next correction must address storage pressure
before another cold attempt, with fixture tests and a separately frozen config.

Compact evidence: `evidence/campaign/campaign_n08316_s103_r01/`. The collector
checked the completion/result hashes, copied the explicit stop reason, hashed
all retained run files and preserved the originals. Result SHA256:
`2aa78780308ca99948bfc8b1a4e2b0f121e833bbbc211ab945c6c82034eba1df`.
The 23,643-bus solve remains unstarted behind this case's success gate.

## r02: storage-only native scheduling handoff and host-memory safety

The next registered attempt keeps the same scenario, source hash, comparison,
numerical model, algorithm options, gap/tolerances and deadlines. Its only config
changes are a new attempt ID, `scheduling_storage_policy=native_handoff_v1`, and
a 2 GiB available-host-memory safety floor. A regression checks this exact diff.
It remains a fresh cold attempt and uses no point from r01 or another network.

The normal JuMP scheduling model is still built by the unchanged pinned upstream
functions plus the existing source-faithful project adapters. Before solving,
the complete unsolved model is copied through public `MOI.copy_to` into a fresh
HiGHS-backed JuMP `direct_model`. Every constraint type must be natively supported;
variable counts, complete constraint inventories and objective sense must match.
Extraction references for commitment, real/reactive power, balance slacks and all
ten reserve products are remapped through the returned index map. Other columns
are still present in the native model even if no high-level extraction handle is
retained. Metadata is restricted to plain values so it cannot retain old models.

After successful copying, the disposable cached model is emptied and garbage
collected before `optimize!`. No source rows/columns are eliminated, no algebraic
presolve is introduced, and there are no coefficient, bound, integrality or
objective changes. Native solver presolve stays on as before. Storage-only
handoff does not promise that the full case will fit or solve; r02 must measure
that. JuMP documents the extra cached representation and direct-mode tradeoffs:
<https://jump.dev/JuMP.jl/stable/manual/models/#Direct-mode>.

Synthetic tests compare every mapped row coefficient, constraint set (including
bounds/integrality), objective coefficient and sense exactly before releasing
the old cache. Joint/separated-reserve fixtures retain their objectives; startup
window infeasibility remains infeasible; the production handoff path, extraction,
metadata ownership and unsupported-policy rejection are tested. The focused
Julia suite passed 2,214 assertions. All 92 Python tests passed, including new
memory-threshold, stop-record and unchanged-historical-configuration checks.
These tests did not construct or solve any competition model.

The controller checks global available physical memory every two seconds when
the new floor is configured. Falling below 2 GiB records a resource stop and
unwinds through the existing owned-process cleanup/finalization. It never kills
unrelated applications, deletes source data, changes machine settings, or calls
resource exhaustion infeasibility. This safety condition is additional to—not
a replacement for—the unchanged two-hour deadline and exhaustive verification.

The full component gate now contains 42 stages and 15 tiny-pipeline certificates,
including a new native-scheduling-to-AC-to-official-verification integration.
Its complete new manifest, source-hash check, frozen push and clean preflight
are required before r02's one-use latch may be claimed.

### r02 completed component gate

The complete new gate passed **42/42 stages**, **92 Python tests**, **3,416 Julia
checks**, and all **15** tiny-pipeline certificates. Each certificate completed
all nine contingency-hour checks and passed independent hard feasibility,
objective agreement, and official `feas=1` / `phys_feas=1`. In particular, the new
native-scheduling integration preserved all 153 fixture variables and the complete
constraint inventory, emptied its old cache, returned an optimal schedule, and
produced an independently verified final AC solution. Full-case memory savings
and quality remain to be measured, not inferred from this fixture.

- Exact gate evidence: `tmp/pilot002_component_gate_m5l2vzpn`.
- Stage time total: 994.723 seconds; no competition-case solve in the gate.
- Component manifest SHA256:
  `2a2ab70b1a4ca3af7d88d64db9fa104a063b5f02eb4fc33a2e374bb8d07decd8`.
- r02 config SHA256:
  `ae6106b0d627e398a273b6daabe83d8545922f0834dd3d7f973480179f860cb6`.
- Rehashed source/configuration inventory: 119 files, all matching the gate.

The tested correction was already pushed as `b657dce`; the final pre-run freeze
also includes this complete gate record. No settings or source constraints are
changed between the freeze and the r02 run.

### r02 measured result: complete and within time, physical gate failed

The single cold attempt at `63dc169b561c1ffb66850740c2330903c0dd1fd3` finished
in **6,562.206 seconds (109.37 minutes)**. All 48 AC intervals and all 301,872
contingency-hour checks completed. Native handoff addressed the preceding
memory failure: sampled peak process-tree RSS was 13.282 GiB. No run was repeated.

| Gate or measurement | r02 result |
| --- | ---: |
| Official objective | 1,153,496,520.291184 |
| Target (90% of sixth-best eligible score) | 923,018,777.350128 |
| Scheduling gap (not a full AC global gap) | 0.00028949511116229 |
| Independent hard-feasibility check | PASS |
| Maximum independent hard residual | 9.2146e-11 |
| Independent / official objective difference | 0.010201 |
| Official `feas` / `phys_feas` | 1 / **0** |
| Maximum absolute real-power imbalance | 1.39572e-8 p.u. |
| Maximum absolute reactive-power imbalance | 4.62205e-10 p.u. |
| Campaign acceptance | **FAIL: physical-feasibility gate** |

The archived `VERIFIED_HARD_FEASIBLE` status refers to the separate hard-constraint
check. It is not a campaign pass: `quality_gate.pass=false`, and the completed
network registration is null. The 23,643-bus attempt remains unstarted.

| Measured stage | Seconds |
| --- | ---: |
| Loading/preprocessing | 1.956 |
| Scheduling | 803.285 |
| Initial reserves | 96.312 |
| AC refinement | 4,705.193 |
| Final reserves/postprocessing | 183.014 |
| Independent final verification | 292.668 |
| Official final verification | 210.930 |
| Total end to end, including other controller/JIT/wait/serialization work | 6,562.206 |

The preliminary schedule check exhausted its approximately 240-second allowance
without a complete certificate; that was not an infeasibility proof. Final
independent and official verification both completed. Penalized source thermal
overloads and reserve shortages remain in the objective; no zero-overload claim
is made.

Compact evidence is retained in `evidence/campaign/campaign_n08316_s103_r02/`;
all original solutions and logs remain local, and nothing was pruned. The
completed result SHA256 is
`bfafc1ee3a980cd2aaed589f035350e36d09a00fff01a83552131becc6fccd5a`.
Candidate SHA256 is
`ed633818eda73ff71228b4991a49702459839edb6955a09920ae8f1949f5cfc0`.

### Failure mechanism and r03 correction

The official physical check uses the pinned evaluator's `hard_constr_tol=1e-8`
for the maximum absolute bus P/Q imbalance. Its worst r02 P value was
`-1.395718562946513e-8` at `bus_7606`, zero-based time index 2 (hour 3).
On this case's 100 MVA base, the magnitude is about 1.396 W, versus the 1 W
acceptance limit. The limit is not changed or waived.

That bus has producers `sd_0445` and `sd_0446`. Their first-hour dispatches
were each approximately 6.98e-9 p.u. above the forward-propagated ramp-down
lower bound. The pinned upstream bound-tightening functions skip changes
smaller than 1e-8, but its final exporter applies the exact ramp intersections.
Two such adjustments at the same bus can therefore accumulate past the physical
threshold. Local pre-export AC residuals do not detect that later injection
change. The old unprojected full hourly vector was not retained, so the precise
per-device pre/post comparison is inferred from source/log evidence and tested
with a synthetic reproduction, not presented as a saved original-vector audit.

The separately registered r03 opts into `exact_source_intersections_v1`:

- Apply every source/ramp-bound intersection during horizon preparation and
  sequential AC preparation. The bound-bookkeeping threshold is zero, not a
  relaxation of any solver/evaluator feasibility tolerance. Empty intersections
  fail explicitly; they are never averaged or repaired by relaxing PMIN/PMAX.
- Retain the unchanged source exporter and log its signed dispatch adjustments
  by bus/hour. Save each candidate before rejecting export drift greater than
  1e-9 p.u. on already-refined hours. Unfinished future placeholders are logged
  separately and cannot be mislabeled complete. This diagnostic is not a
  replacement for exhaustive independent/official verification.
- Skip only the known-unverified preliminary schedule evaluation, using the
  existing `skip_unverified_schedule_v1` controller policy. Every final hour
  and contingency must still pass both complete checks inside the same 7,200
  seconds. The initial schedule remains saved and is never called verified.

All other r02 configuration fields, raw input, gap, solver/evaluator tolerances,
source costs/penalties and cold-start policy are unchanged. The original CPU
HiGHS plus Ipopt/MUMPS route remains selected; correction/SLP is off. A config
regression enforces this exact difference. The full new tiny component gate,
hash-matched source inventory, pushed frozen revision and clean preflight must
pass before r03 can claim its one-use full-run authorization.

### r03 completed component gate

All **45/45 stages**, **93 Python tests**, and **3,450 Julia assertions** passed.
All **16** tiny pipelines passed independent hard feasibility, objective
agreement, official `feas=1` / `phys_feas=1`, and their full nine contingency-hour
checks. The exact-ramp integration completed all three hours with **zero export
dispatch adjustments** and maximum P/Q imbalances of approximately 9.99e-16 /
6.46e-15 p.u. The targeted two-producer regression reproduced the legacy drift
above 1e-8 and removed it with exact intersections; positive PMIN and empty-domain
failure checks also passed. These are fixture results, not a full-case pass.

- Exact evidence directory: `tmp/pilot002_component_gate_2g1mfb0l`.
- Summed stage time: 1,057.205 seconds; no competition-case solve was performed.
- Manifest SHA256:
  `589e0713026b3b5d01b0387fd32054d137cf81eef7d864da92c780ba388b3500`.
- r03 configuration SHA256:
  `7d14b4ca6c09b35b567aa6ab71a67de84744340bc6a84b346f034f96934ceef4`.
- All 123 covered source/configuration files and all 45 saved stage logs were
  rehashed and matched the completed gate.

The correction was pushed as `eea9c86`; the final pre-run freeze adds this
complete test record. No source/solver settings change between that freeze and
the registered cold r03 attempt. The failed r02 solution is evidence only and
must not supply initialization.

## r03 full cold result: verified success

The single registered r03 attempt ran on the laptop CPU from frozen, pushed
implementation `2713e5df972f8cae7b77d8963419eba4e1f28424`. It completed on
2026-09-19. No source/configuration edits, duplicate solve, warmup, or supplied
optimized initialization occurred during the run. The original HiGHS scheduling
plus Ipopt/MUMPS AC refinement route remained selected; SLP/correction was off.

| Acceptance item | Recorded result |
|---|---:|
| End-to-end, through result serialization | 6,508.759884 s (108.480 min) |
| Hard end-to-end limit | 7,200 s; passed |
| Official objective / feasible score | 1,153,496,520.441392 |
| Sixth-best eligible published score | 1,025,576,419.277920 |
| Required score (90% of sixth-best) | 923,018,777.350128 |
| Quality gate | PASS |
| Hourly coverage | 48/48; exact interval coverage, worker exit 0 |
| Source contingency-hour checks | 301,872 / 301,872 |
| Independent hard constraints | PASS |
| Official feasibility / physical feasibility | `feas=1`, `phys_feas=1` |
| Objective agreement | PASS; absolute discrepancy 0.0101099014 |
| Maximum independent hard residual | 9.214612406e-11 |
| Maximum active-power imbalance | 1.184334748e-10 p.u. |
| Maximum reactive-power imbalance | 7.408667534e-10 p.u. |
| Maximum refined export bus-injection change | 4.606759418e-12 p.u. |
| Numerical recovery attempts | 0 |
| Peak sampled process-tree RSS | 13.275925 GiB |

All checkpoint export audits and the final 48-hour export audit passed their
1e-9 p.u. guard. The final audit contained no unfinished future intervals. The
previous r02 failure of the official physical-balance gate did not recur; the
source bounds, costs, penalties, and solver/evaluator tolerances were not
relaxed. The final result is better than the sixth-best reference score, not
merely within the requested 10% shortfall. This comparison is neither an
official competition placing nor a full-GO3 global-optimality certificate.

| Measured stage | Seconds |
|---|---:|
| Worker loading / preprocessing | 1.705 |
| Scheduling stage | 814.526 |
| Initial reserve allocation | 98.166 |
| AC refinement, all 48 intervals | 4,873.702 |
| Final reserves and postprocessing | 186.022 |
| Complete worker (includes other worker overhead) | 5,987.042 |
| Independent final verification | 292.160 |
| Official final evaluation | 211.645 |
| End-to-end including controller and serialization | 6,508.760 |

The scheduling economic MILP's native solve time was 677.956 s; it returned
objective 1,158,895,578.889697, bound 1,159,231,073.494133, and relative gap
0.0002894951112 (0.028950%, below the requested 0.1%). That bound/gap applies
only to the approximate scheduling subproblem, not the complete AC GO3 result.

### Important meaning of feasibility

This is feasibility under the unchanged GO3 source rules, including their
permitted soft penalties. It is **not** an overload-free N-1 certificate.
The maximum evaluated contingency overload was 4.808560231 p.u. Recorded
penalties include base overload 140,391.615485, reserve shortfall 3,411.795033,
worst-contingency 160,913.266275, and average-contingency 61,399.632911. These
costs are included in the verified objective; no source penalty was removed.

### Retention and post-run audit

Compact evidence is in `evidence/campaign/campaign_n08316_s103_r03/`.
The collector verified hashes before archiving and retained every original
solution/log file. No files were deleted and no reevaluation was launched.
After completion, all 123 covered source/configuration hashes and all 113
pinned upstream tracked-file hashes still matched. Both upstream checkouts
were at their recorded revisions with no tracked modifications, and the
worktree remained clean through the full run.

- Result SHA256:
  `00577736716de75b777c3dafccc48dcfb19e97350633b1b9feba45772ee80f74`.
- Completion SHA256:
  `d5c0fb546863d4638718309bb73f9dbf299d372b7ab20ec93066c9c88cd41a2f`.
- Verified retained candidate SHA256:
  `68bbeedd2a6195d565a1aac3cffd3d9ebeae8f3aa8fb3143d98ec5f13d25c550`.

The completed-network registration now admits preparation of the already
authorized 23,643-bus scenario 003. The overall two-network objective remains
unfinished until that network independently passes its own full acceptance
gate. The deferred 6,717-bus network is not represented as passed.
