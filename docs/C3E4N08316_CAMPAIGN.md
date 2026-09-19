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
