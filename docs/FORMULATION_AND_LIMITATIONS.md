# Frozen first-pilot model contract

## Identity and revision compatibility

The registered input is **C3E4N00617D2, scenario 002**, the smallest numeric
public Final Event 617-bus Division 2 scenario with matching published results.
All 24 scenario groups found for this network/division have switching allowed;
there was no matching no-switch alternative. Switching permission is **not**
inferred merely from Division 2. See `manifests/case.json` for the input SHA256,
exact archive entry and counts. Only that entry was extracted using HTTP range
requests; no solved POP, other case, or competitor solution was downloaded.

The input has 48 one-hour intervals (48 hours, not 24), 617 buses, 94 producers,
405 dispatchable consumers, 723 lines, 130 transformers, 22 shunts, and 562
single-branch source contingencies. There are **26,976 contingency-interval
checks** per complete evaluation. The input general section does not contain a
UUID. Published UUIDs in our comparison manifest are submission identifiers,
not invented input UUIDs.

Authoritative references:

- [Final Event data/formulation/results](https://catalog.data.gov/dataset/arpa-e-grid-optimization-go-competition-challenge-3).
- [Formulation, January 22, 2024](https://data.openei.org/files/5997/Challenge3_Problem_Formulation_20240122.pdf).
- [Data format, January 24, 2023](https://data.openei.org/files/5997/Challenge3_Data_Format_20230124.pdf).
- [Official evaluator at bb5df337](https://github.com/GOCompetition/C3DataUtilities/tree/bb5df337553b21ab8be89ae5f9106958541730d4).
- [Official schema at 5472a237](https://github.com/Smart-DS/GO-3-data-model/tree/5472a2373f456cc7e9923cdd31be1d4345d9830f).
- [Published result workbook](https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx).

The formulation's revision history says the January 2024 revision expanded
the introduction/problem description; the last preceding mathematical revision
was May 26, 2023. The public evaluator `bb5df337` is itself the recorded evaluator
for the published official benchmark and several compared teams. Some other
rows record `fabdeb545cd2f471396579e720f355de1e36595f`. The inspected diff adds
switching-count diagnostics, optional **input-scrubber** cost replacement, and
configuration defaults. It changes no scoring/feasibility equations for an
unscrubbed solution evaluation. We explicitly set `use_cost_defaults=false`,
never scrub the source input, and do not modify the evaluator. Published data
model revision cells say `nan`; historical schema hash equality is therefore
**unknown**, not claimed. All current tracked upstream files and documents are
hashed in `manifests/sources.json`.

## Equations and acceptance

For device g and interval t, the online output obeys the exact source bounds
`u[g,t] * p_lb[g,t] <= p_on[g,t] <= u[g,t] * p_ub[g,t]`. Actual real injection
also includes the prescribed startup/shutdown trajectories. Costs use the raw
piecewise blocks and actual interval durations, with demand benefits positive
and production, commitment, reserves and violation costs negative in the
maximized surplus. Source initial states/durations, minimum up/down times and
inter-interval ramps are checked across the complete horizon.

Normal network flows are AC, using complex voltage, series admittance, charging,
transformer magnitude/phase and shunt conductance/susceptance. Both branch ends
and losses are retained. Conditional reactive capabilities and all ten reserve
products, headroom/eligibility, zonal requirements and shortfall costs are checked.

GO3 contingency physics are **not corrective AC OPF**. For each source branch
outage, the checker constructs the prescribed linear network using the source
series susceptance `-imag(1/(r+j*x))`, phase shifts and pre-contingency injections.
It distributes the injection/loss mismatch uniformly across all buses. The
base-state end reactive flows enter the prescribed apparent-flow overload test;
no freely chosen redispatch or reactive repair is introduced. Connectivity is
required. The independent implementation explicitly refactors each outage
network and solves all intervals sharing that topology; the official evaluator
uses its own SMW-based calculations. Objective contingency cost is the **worst
plus the mean** contingency penalty, not their half-weighted average.

Official hard and integer feasibility tolerances are `1e-8`; time-boundary
tolerance is `1e-6`. Our independent check uses those values. Solver tolerances
are stricter candidate-generation settings, not replacements for official rules.
Independent/official objective agreement is an arithmetic cross-check with
absolute threshold `max(1e-5, 1e-9 * abs(objective))`; it never relaxes a hard
constraint. A retained result requires complete independent checks, official
`feas=1`, hash agreement and objective agreement.

GO3 permits penalized real/reactive bus imbalances, base/contingency overloads
and reserve shortages. These are reported with magnitudes and costs. Official
`feas=1` means **hard-feasible**, not zero soft violations. The evaluator's
`phys_feas` additionally checks bus P/Q imbalance; even that is not a statement
that every overload/shortage penalty is zero. Neither flag proves global
optimality of this nonconvex mixed-integer problem.

## Initial algorithm and explicit limitations

1. A cold **whole-horizon HiGHS MILP** searches commitment and dispatch using
   LANL's source-based copperplate scheduling formulation, including reserves,
   durations, transition trajectories and minimum-time/ramp coupling. Its balance
   and reserve approximations use candidate-generation penalties. No source
   generator is fixed on simply because it starts on.
2. Construct a complete official-format candidate, allocate reserves, then
   independently and officially evaluate it. Preserve it only if every gate passes.
3. Improve each interval using **Ipopt/MUMPS AC OPF** with the scheduled
   commitment. Inter-interval-compatible bound tightening and subsequent
   whole-horizon projection/checking prevent independent-hour concatenation.
   Shunts are optimized continuously, rounded and re-solved.
4. Reallocate reserves against the final energy/reactive dispatch. Validate the
   full horizon and **every** contingency again. Keep the better fully verified
   surplus, never an unchecked solver incumbent.

This is a deliberately simple first implementation of the user's proposed
decomposition. It does **not yet** feed contingency sensitivities into a new
scheduling round, optimize topology/taps, or prove a full GO3 optimality gap.
All contingency penalties are still evaluated and included in retained-candidate
selection. A poor objective or substantial penalized violations remain possible.
These limitations are reported rather than hidden behind subproblem solver gaps.

Candidate-only restrictions (not GO3 model changes): source branch statuses and
transformer magnitude/phase are fixed; the LANL AC subproblem includes a 30-degree
branch angle-difference bound and +/-10 nominal-rating component-flow bounds;
AC dispatch deviations from the internal schedule are penalized. No valid source
domain is rewritten in the raw case or official check. LANL's extraction/projection
uses its own numerical policy; the resulting output still must pass the official
`1e-8` gates. Its Ipopt callback may stop after 200 iterations at a looser internal
candidate point: that is **not** our acceptance policy.

Warm-start policy: no optimized external starts. Scheduling is cold. AC models
use flat voltage/source shunt initial values and the current run's commitment/
dispatch targets, without inherited primal/dual/basis starts. The second shunt
solve uses the resident model; acceptance of an inherited warm start is not
claimed. Solver return status and final-solve iterations are logged; native logs
retain both shunt solves. Reserve LP iteration totals are not separately exposed
by the upstream aggregate helper.

Required-feature gate: nonempty energy-window constraints, startup-count windows,
special startup states, coupled P-Q capability curves, DC devices, additional
branch shunts and multi-component/non-branch contingencies are explicitly rejected.
**None is present in the selected case.** This implementation is not a universal
GO3 solver, and cannot silently skip them on another case. Output/schema validation
remains authoritative for the selected case.

## Deadline, provenance and evidence

The 1,800-second clock begins before runtime raw loading. Solver imports/JIT,
case-specific parsing, preprocessing, factors, internal checking and all result
serialization are counted. Installation/download/precompilation/source audit
are setup only. Work stops by 1,530 seconds, leaving 240 seconds for exhaustive
verification and 30 seconds for finalization. The initial candidate check is also
inside this same clock. A permanent exclusive latch prevents any automatic retry.
Only task-owned descendants are cancelled. First and final candidate solutions,
the verified official solution, independent companion fields, raw logs and
contingency violation records are retained locally. Compact hashes/certificates
may be committed; no large run or raw input is committed. Physical Windows free
space must stay >=30 GiB, with an extra 1 GiB preflight write allowance.

The approximate scheduling MIP bound/gap is explicitly scoped to that subproblem.
No solver duals are presented as ISO prices. GO3 is a research benchmark, not an
exact PJM or CAISO market model. Laptop and competition runtimes differ in
hardware, implementation and budgets and do not establish an apples-to-apples
speed comparison.
