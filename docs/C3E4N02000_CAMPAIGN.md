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
