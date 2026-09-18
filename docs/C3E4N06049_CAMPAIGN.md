# 6,049-bus cold quality campaign

The 2,000- and 4,224-bus networks have passed their independently verified
sixth-best-score targets. Their immutable result/completion hashes authorize
this next network. No preceding successful attempt is repeated.

## Input and source-feature audit

Scenario **003** is the smallest-numbered public Division 2 scenario, chosen
before inspecting our solve quality. The archive lists 18 scenarios: 003, 007,
009, 013, 015, 019, 025, 031, 037, 043, 049, 055, 057, 061, 063, 067, 069, 073.
Only `D2/C3E4N06049D2/scenario_003.json` was retrieved by bounded HTTP ranges from
<https://data.openei.org/files/5997/C3E4N06049_20231002.zip>.
Source archive ETag: `"23764100-617cc5c77c400"`. The transfer was 8,715,944 bytes;
the raw JSON is 64,038,939 bytes. No supplied POP or other optimized solution
was downloaded or used. Raw SHA256:
`312b066e51e4e058d0f2e1a96ea32c8f30a3f1dbfc9c4266b6d5d73af4206e41`.

The case contains 48 one-hour intervals, 6,049 buses, 406 producers, 3,368
consumers, 4,920 AC lines, 3,086 transformers, 236 shunts, no DC lines and
six each of active/reactive reserve zones. Its 3,902 source contingencies per
hour require **187,296** independent contingency-hour evaluations. All 7,548
source startup-count windows and 402 devices with affine P-Q capability bounds
remain covered. The complete required-feature gate passes without any feature
omission or new model relaxation.

## Published-score target

The unchanged official workbook SHA256 is
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
A read-only spreadsheet audit preserves the original values, source rows,
eligibility, switching permission and evaluator identities in the comparison
manifest. The sixth-best eligible score is **597,463,992.571312** by
Electric-Stampede (source row 1748). The required 90% minimum is
**537,717,593.314181**. Only the same scenario, Division 2 and switching permission
are compared, with one active feasible result per team, excluding ARPA-e's
benchmark. Missing/inactive/infeasible records are not assigned artificial scores.

| Eligible rank | Team | Published score | Source row |
| --- | --- | ---: | ---: |
| 1 | TIM-GO | 609,159,208.762250 | 9107 |
| 2 | YongOptimization | 609,001,575.108100 | 9776 |
| 3 | GOT-BSI-OPF | 608,909,921.153217 | 3086 |
| 4 | GravityX | 608,584,286.387930 | 3755 |
| 5 | LLGoMax | 608,563,770.630885 | 4424 |
| 6 | Electric-Stampede | 597,463,992.571312 | 1748 |

These are retrospective score references, not global optimality bounds or
hardware-normalized timings. Eligibility follows official active/feasibility
fields; our own hard end-to-end cap remains 7,200 seconds.

## Registered first attempt

`campaign_n06049_s003_r01` retains the numerical algorithm and settings of the
successful 4,224-bus r04: HiGHS/simplex source-reserve scheduling with guarded
consumer dominance, joint reserve-aware AC refinement, complete same-interval
rounded-shunt primal-dual starts and preceding locally screened hour's primal
continuation. The process begins cold, hour 1 uses raw/default initialization,
and no external solution or previous-attempt primal/basis/dual is read.

The end-to-end cap is 7,200 seconds, reserving 600 seconds for final exhaustive
verification and 30 for serialization. Scheduling has a 3,600-second maximum
and 1e-3 relative gap; AC phases retain their 90/240-second maxima under the
remaining global budget. Source PMIN, costs, all temporal/reserve/AC constraints,
official penalty semantics and independent acceptance tolerances are unchanged.
Only scenario identity/provenance changes from the preceding configuration.
No GPU or commercial solver is used. Full component tests and a clean pushed
commit precede the single cold full-size attempt.

The prelaunch component gate passed **69 Python tests and 520 Julia assertions**.
All six tiny end-to-end pipelines passed official hard/physical feasibility and
independent 9/9 contingency-interval verification. Evidence resides in
`tmp/pilot002_component_gate_7waw6df_` and is hash-registered in
`manifests/component_tests.json`. No full-size scenario was used by this gate.

## First attempt: incomplete refinement, not a case-infeasibility proof

`campaign_n06049_s003_r01` used frozen revision
`cfb94c732c313acc9b0925d2c1335f259c513d45`. Its failure record finalized in
**3,181.563656 seconds (53 min 1.564 s)**, below the two-hour limit. The scheduling
MILP reached objective 621,291,337.175008, bound 621,357,577.274144 and relative
gap 0.000106616808, with 422,173 LP iterations and one search-tree node.

The initial scheduling-candidate verification exhausted its separate 240-second
allowance (238.657 process seconds), so no initial verified incumbent was accepted.
The worker then proceeded as registered. Hours 1-19 passed the local 1e-8 residual
screen. Hour 17 used both local solver allowances but returned a 2.71310e-9
residual and continued. Hours 18 and 19 recovered in the rounded phase, taking
177.524 and 150.125 seconds overall. Hour 20 exhausted its 90/240-second phase
allowances and returned a **3.80205e-5** residual. Its checkpoint was saved before
refinement stopped. Hours 21-48 were not attempted.

Final independent evaluation completed all **187,296 / 187,296** contingency-hour
checks. Independent time was 320.003 seconds; official evaluation took 88.260
seconds; process wall was 410.005 seconds. Official hard feasibility was 1,
physical feasibility was 0, and independent hard checks/objective agreement
passed. The incomplete objective **-22,240,695,382.414497** is not an accepted
completed solution score: the quality gate correctly failed. Large physical
imbalances include the unrefined future hours. Peak sampled process-tree RSS
was 16.72855 GiB.

The native log shows repeated large dual residuals, very small steps and
occasional excursions away from feasible iterates. This supports investigating
numerical recovery, but neither proves a unique cause nor proves the source case
infeasible. No tolerance, source constraint, PMIN or penalty was relaxed.
Evidence is hash-archived at `evidence/campaign/campaign_n06049_s003_r01`; all
original files remain. Result SHA256:
`4725bd0bbbb0e385c460e3d3881fab1762b4e68ee708949e7209505700b510b6`.
The campaign remains on this network.

## Registered second attempt: bounded numerical recovery

`campaign_n06049_s003_r02` retains the raw input, complete mathematical model,
source limits/costs, scheduling algorithm, normal AC phases, residual thresholds
and two-hour end-to-end budget. It adds one fallback only when the rounded-shunt
phase returns a finite point that fails the explicit 1e-8 residual screen:

1. Keep that same within-attempt complete primal point and fixed shunt choices.
2. Instantiate fresh Ipopt numerical state on the identical JuMP model, clear
   all row/bound/nonlinear dual starts and disable primal-dual warm-start mode.
3. Try Ipopt's adaptive barrier with its quality-function oracle and default-size
   interior pushes. These affect initialization only; bound relaxation remains
   zero and source limits stay exact. Recovery is capped at 360 seconds / 1,000
   iterations and the remaining global work deadline, whichever is earlier.
4. Apply the unchanged residual screen. If it fails, checkpoint and stop; there
   is no unbounded recovery loop. Final independent/official checks and the
   sixth-best score requirement remain mandatory.

A successful ordinary interval, including a time-limited point whose explicit
residual passes, does not trigger this fallback. No previous attempt, external
primal, basis, dual or supplied optimized solution is read. The first hour still
starts cold; later continuation remains confined to this attempt.

Component tests cover new and legacy nonlinear constraints, both objective
senses, fixed variables, stale dual clearing, native zero-iteration consumption
of the supplied primal, mathematical-model identity, invalid inputs and three
deliberately interrupted tiny hourly AC solves. A separate complete tiny pipeline
checks that already-successful intervals do not invoke recovery. The full tiny
gate independently and officially evaluates the recovered three-hour solution.

This is a tested numerical fallback, not a guarantee of large-case convergence
or a claim that the r01 case was mathematically infeasible. The relevant option
semantics are documented in [Ipopt's options reference](https://coin-or.github.io/Ipopt/OPTIONS.html#OPT_mu_strategy).
Final verification receives all remaining global time minus serialization,
with 600 seconds reserved as a minimum, not as a fixed verification cap.

The second-attempt component gate passed **69 Python tests and 663 Julia
assertions**, plus seven independently and officially verified tiny pipelines
(9/9 contingency-hour checks each). The forced-recovery output passed hard and
physical feasibility; its objective matched the independent calculation within
1.46e-11. Evidence: `tmp/pilot002_component_gate_0u4qvj0w` and the hash-registered
`manifests/component_tests.json`. No full competition case was solved by the gate.

## Second attempt: recovery works, but the full horizon exceeds the work budget

`campaign_n06049_s003_r02` used frozen revision
`f46aec890bcd4743cd2b6592fdc5a8035bd16a1d`. It finalized in **6,883.103710 seconds
(1 h 54 min 43.104 s)**, inside the 7,200-second end-to-end cap. The campaign
quality gate **failed**: only 41 of 48 AC intervals were refined, and the owned
worker was stopped at its work deadline during final reserve allocation
(return code 15). The saved pre-final-reserve candidate was independently checked;
neither it nor its diagnostic objective is a completed physical solution.

All 41 completed hourly points passed the unchanged 1e-8 explicit model screen.
The maximum final hourly residual was **2.7043161e-9**. Hour 20, the previous
stopping point, passed in its ordinary rounded phase; that improvement must not
be attributed to a fallback that did not run there. Time-limited iterates can
vary with execution timing and influence later within-attempt starts.

The new recovery was exercised twice:

| Hour | Rounded-phase residual before recovery | Recovery time (s) | Final residual | Recovery termination |
| --- | ---: | ---: | ---: | --- |
| 31 | 3.14087e-7 | 58.871 | 4.97140e-11 | Locally solved |
| 34 | 6.44179e-8 | 363.164 | 2.43397e-9 | Time limit; explicit residual passed |

Native phase limits are checked between solver operations and can overrun by a
few seconds; all such time was charged to the strict global controller. Hour 34
used 650.146 seconds overall. The local recovery prevented two premature stops,
but did not eliminate the long convergence tails.

| Recorded work | Time (s) |
| --- | ---: |
| Scheduling stage | 496.819 |
| Initial reserve allocation | 39.054 |
| Initial verification (incomplete at its separate cap) | 238.509 |
| Continuous-shunt phases, 41 calls | 2,231.110 |
| Rounded-shunt phases, 41 calls | 2,717.644 |
| Recovery phases, 2 calls | 422.035 |
| All completed hourly work, including model/audit overhead | 5,690.882 |
| Final independent check | 222.095 |
| Final official evaluation | 88.450 |
| Final verification process wall | 312.515 |

The independent and official checks completed all **187,296 / 187,296**
contingency-hour evaluations. Source hard feasibility was 1, physical feasibility
was 0, independent hard checks passed (maximum hard residual 3.15702e-9), and
objective agreement passed (absolute discrepancy 0.053101). The incomplete
diagnostic objective was **-6,055,396,393.806871** (official score clipped to zero),
including large imbalance penalties from still-unrefined hours and zero final
reserve awards. It is not an accepted score. Peak sampled process-tree RSS was
16.76550 GiB. No source data or outputs were pruned; about 197.85 GiB remained free.

The result was correctly recorded as
`VERIFIED_HARD_FEASIBLE_INCOMPLETE_REFINEMENT`, with `pipeline_completed=false`.
A separate code audit identified a latent completion-reporting edge case if a
budget-limited worker finishes finalization normally: full-hour coverage must be
checked, not inferred from a final `complete` stage alone. That edge case did not
change r02's failed status. Reserve-finalization time also needs protection from
the combined AC phases, not merely an entry check before an interval.

Evidence is hash-archived in `evidence/campaign/campaign_n06049_s003_r02`.
Result SHA256:
`c98bddf90e7b1aa5f155ec17c70cc5d68161b2122bdab648aafc3da95e4f40f6`.
Candidate SHA256:
`640a58cda727d8c225c00adbbdd65d0cb3c3f47924479275fbe13ab29bd20576`.
The 6,049-bus network remains unfinished; no larger network is authorized by a
successful registration yet.

## Registered third attempt: audited feasible-point stopping and finalization protection

`campaign_n06049_s003_r03` keeps the identical raw input, mathematical model,
source bounds/costs, scheduling settings, recovery policy and acceptance tests.
It adds `verified_stable_rounded_primal_v1` to the rounded-shunt and recovery
phases only. The continuous-shunt phase is unchanged. After at least 20 native
iterations, a window of eight ordinary (non-restoration) objective values must
have relative range at most 1e-7. A small native primal residual is only a cheap
trigger; it is never sufficient for acceptance.

At a trigger the adapter reads Ipopt's current **unscaled** iterate through
`GetIpoptCurrentIterate`, validates an exact complete native-to-JuMP variable
mapping, and independently evaluates every model constraint and variable bound.
Only a complete finite point whose maximum violation is at most the unchanged
1e-8 local screen may request a stop. The objective is independently evaluated
on that same point. The actually returned point is audited again; changed or
infeasible output still invokes the existing recovery/fail-fast policy.
Callback errors fail closed. Neither a cached trial point nor a solver status
alone is used as evidence of feasibility.

This is an explicitly **heuristic feasible-point stopping rule**, not a KKT,
local-optimality or global-optimality certificate. Its native `INTERRUPTED`
termination is preserved in the logs. The final physical-feasibility,
independent exhaustive checks, objective agreement and minimum score of
537,717,593.3141807 remain mandatory. A stable local objective does not prove
that target will be met. Full attempts remain cold; all starts originate inside
the current attempt.

Two control corrections accompany the numerical change:

- All AC phase budgets now exclude the 90-second final reserve allowance, rather
  than merely checking that allowance before entering an hour. Native operation
  overruns still count against the unchanged strict global watchdog.
- Both worker and controller require exactly the 48 distinct expected interval
  records, successful finalization and a normal worker exit before declaring the
  pipeline complete. A normally finalized partial horizon is explicitly partial.

The end-to-end limit remains 7,200 seconds, including raw loading, process/JIT,
optimization, verification and serialization. Final exhaustive verification
retains its 600-second reserved allowance and serialization its 30 seconds.
No source tolerance is relaxed, no contingency is omitted, and no full-case
warmup or duplicate run is authorized by this registration.

The r03 component gate passed **70 Python tests and 776 Julia assertions**.
All seven tiny pipelines passed official hard/physical feasibility and complete
independent 9/9 contingency-hour verification. All six normal worker pipelines
also passed the new exact-interval-coverage check. The forced-recovery fixture
exercised the production stopping policy and independently agreed on objective
within 6.37e-12. The source-feature pipeline exercised both guarded interruption
and normal convergence. Evidence: `tmp/pilot002_component_gate_xf0tiesn`, with
runtime and source hashes registered in `manifests/component_tests.json`.
