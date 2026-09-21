# Cold feasibility-first scheduling experiment

Policy: `cold_online_then_fixed_cost_v1`. This is an opt-in primal heuristic
inside the existing source-reserve decomposition, not a new physical model or
a global economic certificate. The ordinary economic MILP route remains the
default when the policy is absent. Initial full-case registration was r10; the
separately registered r11 changes only its time allocation as described below.

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

In r10 the constructor had a 300-second native-call cap and the economic LP a
700-second cap, within the existing 1,100-second per-master allowance and
1,500-second scheduling-stage budget. Each call retains the external wall-clock
watchdog and RAM floor. The global cap remains 7,200 seconds.

If the cost phase times out, the coordinator may recover only the previously
saved, hash-bound, current-request original-master point after its owned native
process tree has stopped. This point is **not** an already verified GO3 result:
reserve recourse, full original scheduling recomposition, AC and every final
check remain mandatory. The interrupted call and non-normal exit are recorded
explicitly, not hidden as a successful solver return.

### r11 budget-only follow-up

r10 ended at the constructor's 300-second sub-limit, not the two-hour global
limit or RAM floor. The first root LP started at 208.846 seconds, leaving only
about 91 seconds of the constructor allowance. No feasible point was saved;
see `CAMPAIGN_N23643_R10.md` for the observed timings and exact evidence.

r11 retains the same implementation and every source-model and acceptance
contract. Its only configuration differences are the new single-use identity,
700-second construction cap, 1,500-second master allowance and 2,000-second
scheduling-stage allowance. The economic LP retains 700 seconds. Reserve
recourse and scheduling finalization retain their 300/30-second reserves.
This fits inside the scheduling allowance with 170 seconds beyond the master
allowance for loading, auditing and other overhead. That arithmetic is an
allocation, not a runtime prediction.

The 7,200-second global deadline and 2,400-second final verification reserve
remain unchanged. Increasing scheduling time can leave less time for AC;
the original absolute work deadline clips every stage. No phase can borrow
the final verification reserve, weaken a check, or claim success without the
entire source case passing. More construction time is an evidence-led
experiment, not proof that the first LP or the whole case will finish.

## Validation requirements

Tiny tests cover binary transitions, nonzero conditional PMIN, unavailable
units, exact alias mapping, objective offsets, fresh presolved cost solving,
infeasible construction, explicitly suboptimal feasible schedules, budget and
hash guards, and the absence of a false original-MILP bound. The integration
pipeline covers recourse cost, certified Phase-I feasibility cuts, retained
incumbent status and independent/official AC/DC-link contingency verification.
The complete source-matched regression gate must pass before the registered
large-case run. Tiny successes do not establish large-case runtime or quality.

## Read-only aggregate sanity check before r10

The unchanged scenario 003 raw source was parsed without a solver call while
the regression gate ran. Its SHA256 still matched the registered input. Assuming
every source-available unit is online, aggregate producer minimum output is
815.3175997959008 p.u. in each of the 48 hours; aggregate producer maximum
output is 3216.7989999999986 p.u. Maximum consumer demand ranges from
4372.395000000026 to 7468.615 p.u. The largest minimum-generation / maximum-load
ratio is 0.18646933769613588; no hour has minimum generation above maximum load.

This rules out only that simple aggregate over-generation obstruction. It
ignores startup/shutdown power, intertemporal constraints, reactive capability
and network physics; it is not a feasible commitment or a security certificate.
No optimized start, timing experiment, raw-case edit or full-case solve was
performed by this diagnostic. Cold initialization means no prior optimized
solution is supplied, not that operating-system file caches are flushed.

## Completed r10 pre-run gate

The full gate at `tmp/pilot002_component_gate_106v5bfr` passed all 78 stages,
159 Python tests and 16,535 Julia assertions. Its manifest SHA256 is
`2d82c54b6eac72a16f28c85b9ac074e221b9fe88dd0e0f7242d0822020ef50aa`;
the full source inventory and dependency runtime matched at the post-run audit.
Summed stage wall time was 2,601.216059 seconds (setup, not a large-case run).

The new policy's tiny pipeline passed independent and official checking,
including all 9/9 contingencies, with both official feasibility flags equal to
one. Its final objective was 1732.1459647319407 and candidate SHA256
`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`,
byte-identical to the earlier tiny baseline. Ten native worker identities were
checked. Source-feasible but suboptimal scheduling fixtures correctly retained
null original-MILP bounds/gaps and `SOLUTION_LIMIT`, not economic optimality.

`evidence/components/cold_primal_20260920` preserves the full gate and all five
nested pipelines. Every copied file was SHA256-compared against its original;
the archive summary records inventories. All originals remain local and nothing
was deleted. A successful 23,643-bus run remains unproven by this evidence.
