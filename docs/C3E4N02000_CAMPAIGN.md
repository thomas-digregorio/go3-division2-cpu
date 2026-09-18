# C3E4N02000D2 scenario 005: cold campaign

The comparison threshold is 679,248,313.9440606, 90% of the sixth-best eligible
published score 754,720,348.826734. Every attempt is cold from the same raw input;
the overall limit is 7,200 seconds including exhaustive verification.

## Attempt r01: scheduling timeout, not proven infeasibility

- Frozen implementation: `7bfdab0097ade105bb2e3b0175aeed5b9d111776`.
- End-to-end: 978.300 seconds; no candidate solution or score.
- HiGHS scheduling termination: `TIME_LIMIT`, primal status `NO_SOLUTION`.
- Scheduling solver API time: 904.194 seconds (native timer: 900.40 seconds).
- Native presolve: 35.81 seconds; solve: 864.45 seconds.
- 344,574 simplex iterations; zero processed branch-and-bound nodes.
- Original scheduling MILP: 2,121,472 rows, 2,137,344 columns; 272,736 integer columns.
- Presolved MILP: 1,104,195 rows, 1,384,183 columns; 243,524 binary columns.
- Scheduling bound: 779,676,827.2032791, for the approximate copperplate problem
  only. It is not a certificate for the complete GO3 problem. No meaningful MIP
  gap exists without an incumbent, despite the native summary displaying 0%.
- Sampled process-tree peak RSS: 11.994 GiB; no storage failure.

Compact evidence is in `evidence/campaign/campaign_n02000_s005_r01/`.
The archive rehashes the completed result and retains all original logs/artifacts;
it neither resolves nor reevaluates the case and deletes nothing. No AC interval
or contingency evaluation ran because scheduling did not return a feasible point.

## Registered correction: r02

Use the pinned upstream scheduling model's supported `include_reserves=false`
mode only for **candidate generation**. Keep whole-horizon integer commitment,
startup/shutdown, minimum up/down times, ramping, exact source conditional P/Q
bounds, costs and source-weighted aggregate imbalance penalties. Optimize all ten
reserve products with the existing complete reserve-allocation LPs before initial
verification and after AC optimization. All reserve capacities, coupling, source
requirements, costs and shortage penalties remain in independent/official
evaluation. This is a heuristic decomposition, not a new exact formulation or
a certified full-GO3 relaxation.

This can select less reserve-capable commitments, so improved runtime or score is
not assumed. The unchanged full verification and quality gates decide acceptance.
No initial-commitment fixation, imported solved point, evaluator change, or source
constraint/tolerance change is permitted. Old configurations still default to
joint reserve scheduling. The scheduling budget is 1,800 seconds; the total
remains 7,200 seconds, with the same verification/finalization reservations.

Record formulation size and construction time explicitly. Release the completed
scheduling model after extracting the within-run schedule and statistics, before
AC/evaluation work, to avoid retaining its large memory allocation unnecessarily.
Test both historical and separated reserve paths on original tiny fixtures before
freezing and launching the new attempt. A new permanent latch prevents repetition.

## Attempt r02 result: physically feasible, score target failed

Frozen implementation `496d6a0` completed in **1368.964 seconds** (22 m 49 s).
The candidate-generation reduction accelerated scheduling, but removing reserves
from commitment selection was economically unsuccessful for this source case.

| Measured item | r02 result |
|---|---:|
| Scheduling HiGHS API solve time | 124.164 s |
| Scheduling wall time, including model construction/JIT | 164.215 s |
| Scheduling relative gap (subproblem only) | 5.051e-8 |
| AC refinement, all 48 intervals | 1030.517 s |
| Initial candidate verification process wall time | 63.724 s |
| Final verification process wall time | 62.401 s |
| End-to-end, through result serialization | 1368.964 s |
| Sampled peak process-tree RSS | 7.718 GiB |
| Independent and official objective | -7,968,428,047.719683 |
| Competition scoring rule, max(objective, 0) | 0 |
| Official hard / physical feasibility | 1 / 1 |
| Final exhaustive outage-interval checks | 132,288 / 132,288 |
| Maximum hard residual | 5.907e-12 |
| Maximum P / Q imbalance, pu | 1.952e-10 / 1.766e-9 |
| Reserve shortfall penalty | 8,724,568,748.696962 |
| Base thermal penalty | 481,271.780779 |
| Worst plus average contingency thermal penalty | 1,342,987.007553 |

The frozen official sixth-place target was **not met**: the relative score
shortfall is 100%, not <=10%. `VERIFIED_HARD_FEASIBLE` is a factual constraint
status, not a claim of campaign success or zero overloads. All 48 Ipopt interval
solves reported `LOCALLY_SOLVED`; none is a global optimality certificate.
Independent/official objective disagreement was 0.000200272 (well inside the
registered relative agreement tolerance at this objective magnitude).

The initial check's dominant reserve penalties were synchronous-reserve shortages.
The source REG_UP coefficients in zones prz_0 and prz_2 are 0.6507880128 and
0.8350812864; SYN multipliers on the largest producer are 8.496399056 and
10.90245013. These are preserved source parameters, not adjusted or normalized.
The energy-only schedule committed all 544 producers at interval 1, but only 347
at interval 13, 360 at interval 25, and 346 at interval 48. Subsequent reserve
allocation cannot change those commitments. AC refinement repaired physical
balance but did not resolve the resulting economic reserve shortage.

Complete first/best verified solutions and compact evidence are retained in
`evidence/campaign/campaign_n02000_s005_r02/` and its hashed original run. No data
was pruned; the next network is not authorized to advance by the quality gate.

## Registered correction: r03, joint reserves with a CPU HiPO root relaxation

Restore the full joint commitment-and-reserve scheduling formulation used by r01,
including all source reserve requirements and costs. Change its root LP method
through HiGHS `mip_lp_solver=hipo`. HiPO is the open-source CPU interior-point
backend; this is still the HiGHS branch-and-cut MILP solver, not an interior-point
algorithm for integer variables. LPs with a useful basis can still use simplex.
See the [primary HiGHS solver documentation](https://ergo-code.github.io/HiGHS/dev/solvers/).

Keep presolve enabled, four HiGHS threads, the original 1e-3 scheduling gap,
source data, cold-start policy, AC pipeline, evaluator and acceptance tolerances.
No prior schedule, solution or basis is imported. Allow up to 3,600 seconds for
scheduling under the same 7,200-second overall limit; measured r02 AC/final checks
required about 20 minutes, leaving a practical reserve for those later stages.
This is a registered hypothesis about root-LP performance, not a promised speedup.
Tiny forced-HiPO LP and MIP probes must pass before a full attempt is permitted.

Campaign process exit status now also requires the quality gate, so a physically
feasible zero-score result cannot be mistaken for target success by automation.
The quality boundary is compared as `score >= 0.9*S6`, avoiding a roundoff-only
rejection of the exact threshold; the threshold itself is not relaxed.

### Root-solver observability limitation

A read-only audit of the installed HiGHS source revision `04024d701f` shows that
the internal LP relaxation suppresses iteration output. With no valid basis,
`mip_lp_solver=hipo` selects HiPO, but an IPM error can trigger an internal simplex
fallback. The fallback message uses development logging, disabled by default.
Therefore r03 is a **HiPO-requested strategy**, not evidence that every second of
its root solve was spent in HiPO. A quiet native log does not prove a stalled
process, nor does the MIP's exposed barrier counter establish internal attribution.
See [the matching source implementation](https://github.com/ERGO-Code/HiGHS/blob/04024d701f/highs/mip/HighsLpRelaxation.cpp#L1048).

Future registered attempts should enable the supported `log_dev_level=1` option
to expose fallback diagnostics; this alone does not enable the internally disabled
IPM iteration log. No active r03 code, solver option, input or tolerance was changed
as part of this audit, and no additional full-case diagnostic solve was launched.

## Completed r03: physical pass, quality target not met

Frozen numerical implementation `55d5c1f1ab74933d0d0642e40d6dd297b5e318dd` ran
once cold. No previous schedule or solution was supplied. The process completed
normally within the two-hour cap; the campaign exit was unsuccessful because
its score missed the explicitly registered quality target, not because of
infeasibility or a deadline kill.

| Measured item | r03 result |
|---|---:|
| Scheduling HiGHS API solve time | 3,046.205 s |
| Scheduling wall time, including construction/JIT | 3,102.584 s |
| Scheduling objective / upper bound | 755,996,627.351 / 756,047,801.575 |
| Scheduling relative gap, subproblem only | 6.7691e-5 (0.00677%) |
| Native reported LP iterations / processed nodes | 1,142,345 / 1 |
| AC refinement, all 48 intervals locally solved | 760.640 s |
| Initial / final verification process wall time | 58.457 / 57.696 s |
| End-to-end through result serialization | 4,030.028 s (67 min 10 s) |
| Final objective and competition score | 508,365,479.216719 |
| Sixth-best eligible published score | 754,720,348.826734 |
| Relative shortfall from sixth best | 32.6419% |
| Required minimum score | 679,248,313.944061 |
| Official hard / physical feasibility | 1 / 1 |
| Final exhaustive outage-interval checks | 132,288 / 132,288 |
| Maximum hard residual | 1.9515e-11 |
| Maximum P / Q imbalance, pu | 1.5515e-10 / 1.4676e-9 |
| Final reserve-shortfall penalty | 248,153,682.334027 |
| Base thermal penalty | 30,389.365352 |
| Worst plus average contingency thermal penalty | 133,344.513067 |

The initial joint schedule's reserve penalty was only 1,064,801.400757.
The AC stage repaired nodal P/Q balance but increased reserve penalties to
248,153,682.334027. Its objective only used a generic scheduled-P deviation
penalty, not the actual reserve allocation costs and endogenous requirements.
This is the measured next quality bottleneck: reserve headroom and requirements
must be considered while AC dispatch moves, not only recomputed afterward.

`mip_lp_solver=hipo` was accepted, but the native log reported substantial LP
iteration work and the MIP barrier counter was zero. The observability caveat
above still applies; these data do not establish a pure HiPO execution time.
The scheduling gap is not a global GO3 optimality certificate. Final thermal
penalties remain, so this is not a zero-overload claim.

Complete solutions and compact hashed evidence are retained under the original
run and `evidence/campaign/campaign_n02000_s005_r03/`. The archive operation only
checked/captured hashes: it did not repeat a solve or evaluation. No case data
was pruned. The next network remains unstarted because the quality gate failed.

## Registered r04 correction: reserve-aware AC and consumer dominance

Keep the raw case, 48-hour temporal/commitment constraints, joint scheduling
reserves, source costs/PMIN, 1e-3 scheduling gap, fixed source topology/taps and
all acceptance/score tolerances. Keep the HiPO-requested root option rather than
claiming a new pure-IPM benchmark. Enable supported development logging to expose
fallback messages where the native solver supplies them.

Two algorithm changes are registered, not separate full-case ablations:

1. Apply the conservative, proved flexible-consumer commitment dominance rule in
   `docs/CONSUMER_DOMINANCE.md`. It tests each consumer at runtime; it never changes
   a generator's commitment domain or any source bound. The read-only source
   audit found 1,350 eligible consumers, or 64,800 implied on-status decisions.
   Runtime benefit remains unmeasured until this attempt.
2. Include all ten source reserve allocations and eight zonal shortage costs
   inside each fixed-commitment AC interval model. Use original source headroom
   bounds, never the ramp-tightened working limits. Endogenous regulation demand
   follows the current consumer dispatch, and SYN/NSYN requirements follow the
   current maximum producer dispatch. Recompute and independently check all
   reserves again after whole-horizon projection as before.

The reserve-aware candidate search requires zero P/Q imbalance slacks. This is a
disclosed restriction to physically balanced candidates, not a modification of
the original official model, which allows penalized imbalances. It is important
here: source SYN penalties can have marginal effects above the 1,000,000-per-pu
bus-imbalance penalty (SYN coefficient 10.90245013 times 500,000 in prz_2).
Simply adding reserve costs to a soft-balance AC objective could therefore trade
physical balance for score. The independent raw-input checker and official
`phys_feas=1` gate remain authoritative. Thermal/reserve shortage penalties are
still allowed and fully reported; zero overloads are not promised.

The project-owned AC wrapper follows the pinned upstream model and two-solve
shunt-rounding workflow. It omits the upstream early-acceptance callback and uses
the registered Ipopt tolerance, wall-time and iteration limits. It does not read
previous run solutions or initialize from competitors/POPs. Per-interval logs
record the reserve policy, source duration and reserve cost at the solved point.

The total remains 7,200 seconds, including verification/serialization; scheduling
receives at most 3,600 seconds and each AC solve 45 seconds. The permanent r04
latch permits exactly one full cold attempt. Tiny reserve LP equivalence,
cross-feasible witness mappings, unequal-duration costs, endogenous requirement,
source-bound and complete independent/official integration tests must all pass
before freeze/push/launch. A complete source inventory rejects added, deleted or
modified tested code/configuration; no-incumbent gaps/objectives are reported as
null rather than a misleading native zero.

### r04 live diagnostic: misleading native fallback message

The single r04 attempt launched at 2026-09-18 04:24:57 UTC with frozen numerical
commit `2e16d83d906f43bc5aa6f94ab80ee18cb78ed8b4`. During scheduling, the native
console reported a HiPO solve error followed by the text `Try IPX`. This proves
that HiPO failed in this attempt; it does not prove grid infeasibility or failure
of the whole run. The cause inside HiPO is not exposed by this log and remains
undetermined. No restart, altered setting or additional diagnostic solve was made.

The exact matching native source, git `04024d701f`, contains a misleading string:
[HighsLpRelaxation.cpp lines 1108-1128](https://github.com/ERGO-Code/HiGHS/blob/04024d701f/highs/mip/HighsLpRelaxation.cpp#L1108)
prints that message, but sets the solver to simplex and calls it. Consequently,
this particular observed path is **HiPO error -> simplex**, not HiPO -> IPX.
Another path later in the same function can invoke IPX after an iteration-limit
recovery; that has not been observed here and must not be inferred from this
message. An initial live explanation based on the string alone was corrected
after checking this exact source.

Native presolve produced 728,558 rows, 1,144,255 columns, 3,717,854 nonzeros and
56,245 binary columns, compared with 243,524 presolved binaries in r03. A smaller
model is established; a speedup or score improvement is not established before
the complete run and exhaustive verification finish. The final result will be
reported separately. This documentation update does not change the active
numerical implementation or its frozen input/configuration.
