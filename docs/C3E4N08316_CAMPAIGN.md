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
