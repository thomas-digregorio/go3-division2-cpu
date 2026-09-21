# Cold feasibility-first scheduling experiment

Policy: `cold_online_then_fixed_cost_v1`. This is an opt-in primal heuristic
inside the existing source-reserve decomposition, not a new physical model or
a global economic certificate. The ordinary economic MILP route remains the
default when the policy is absent. The proposed full-case registration is r10.

## Motivation

r09 spent its 1,100-second native-call allowance in presolve and the first
economic root LP, ending after 756,963 observed simplex iterations without an
integer incumbent. It stayed above the RAM floor. More root-LP time would leave
less time for AC refinement and exhaustive evaluation. This experiment seeks a
source-feasible schedule first, without waiting for the economic root bound.

## Steps and mathematical scope

1. Rebuild the same unsolved source scheduling model from the raw case. Apply
   only the already proof-checked exact zero/alias compaction and reserve-row
   partition. Do not reuse a prior run's model or optimized solution.
2. On the same integer master feasible region, temporarily maximize the sum of
   source online-status variables over all devices and intervals. This includes
   consumers as well as producers. Original availability, PMIN/PMAX, transitions,
   ramps, energy windows, minimum times, source startup windows and all other
   rows remain present. It is **not** an instruction to force every unit on.
3. Audit a returned integer point against the unchanged master rows, domains,
   cuts and original objective. Save its complete primal immediately.
4. Release the constructor's native solver. Load a separate fresh master with
   the original economic objective, fix each integer variable to the constructed
   integer value, and solve this restricted LP with simplex and presolve on.
   No basis or primal start is supplied to this fresh LP. Audit the result in
   the original integer model; retain the better audited economic point.
5. Check every hourly source reserve subproblem and recompose all original
   scheduling columns. Only a passing complete original-row, bound, integrality
   and objective-agreement audit can establish a scheduling incumbent. If an
   hour is infeasible, the existing certified feasibility-cut loop remains in
   effect; it does not silently remove that hour or weaken its constraints.
6. Hand the first completely audited schedule to unchanged AC refinement and
   independent/official exhaustive evaluation. Final score, feasibility,
   coverage, deadline and memory/disk gates are unchanged.

For a maximization problem, a fixed-integer LP's optimum is **not an upper bound
on the original MILP**. Its reported original-MILP bound and gap are therefore
null. The online-construction objective and bound also cannot certify original
economic optimality. The coordinator terminates a successful constructed
scheduling phase with `SOLUTION_LIMIT`, never an invented economic `OPTIMAL`.
This means feasible scheduling progress, not full GO3 success.

The source balance and reserve penalties remain exactly as supplied. Temporary
construction objective changes are discarded before economic dispatch; no
penalty, constraint or PMIN number in the source model is rewritten.

## Deadline recovery

The constructor has a 300-second native-call cap and the economic LP a
700-second cap, within the existing 1,100-second per-master allowance and
1,500-second scheduling-stage budget. Each call retains the external wall-clock
watchdog and RAM floor. The global cap remains 7,200 seconds.

If the cost phase times out, the coordinator may recover only the previously
saved, hash-bound, current-request original-master point after its owned native
process tree has stopped. This point is **not** an already verified GO3 result:
reserve recourse, full original scheduling recomposition, AC and every final
check remain mandatory. The interrupted call and non-normal exit are recorded
explicitly, not hidden as a successful solver return.

## Validation requirements

Tiny tests cover binary transitions, nonzero conditional PMIN, unavailable
units, exact alias mapping, objective offsets, fresh presolved cost solving,
infeasible construction, explicitly suboptimal feasible schedules, budget and
hash guards, and the absence of a false original-MILP bound. The integration
pipeline covers recourse cost, certified Phase-I feasibility cuts, retained
incumbent status and independent/official AC/DC-link contingency verification.
The complete source-matched regression gate must pass before the registered
large-case run. Tiny successes do not establish large-case runtime or quality.
