# Conservative flexible-load commitment dominance

Status: registered for r04, **not used by completed attempt r03**. No new
full-case experiment has used this reduction yet. All generator PMIN, commitment
domains, source data and official checkers remain untouched.

## Sufficient conditions

Consider a consumer initially online, allowed online in every interval, with
exactly zero source minimum real power and online cost. Startup/shutdown costs
must be nonnegative and special startup states absent. Its reactive bounds must
contain zero, with no coupled P/Q capability constraint. Online ramp limits must
cover every possible transition between successive real-power bounds, including
the source initial power. Startup/shutdown power curves must be identically zero;
with zero PMIN this additionally requires that the source initial power can shut
down within the first interval. Interval durations remain the original values.

Its online downward-ramping reserve capacity must be at least its offline
downward-ramping reserve capacity, and its corresponding online reserve price
must be no greater than the offline price in every interval. Missing conditions
reject the reduction; a failed test never changes a source parameter to qualify.

## Mapping and proof

Take any feasible integer solution of the original model. For a qualifying load,
set its on-status to one for the entire horizon, with zero startup/shutdown
indicators. Keep its actual P, Q, network variables and all other devices fixed.
Set its online downward-ramping reserve to the sum of its old online and offline
downward-ramping reserves, and set its offline component to zero. Keep its other
reserve awards unchanged.

When the old load was online, its offline award was zero, so nothing changes in
dispatch or reserves. When it was offline, its P and Q and other online reserves
were zero: the assumed empty power curves guarantee this. Zero remains allowed
online. Its former offline downward reserve fits both the online capacity and
the unchanged P headroom. Consumer nonspinning and offline upward-ramping awards
are already prohibited by the source model. The zonal downward-ramping total is
unchanged. Other reserve requirements depend on unchanged dispatch, not on the
number of online consumers. Reactive reserve headroom can only increase.

The assumed ramp envelopes cover the unchanged P trajectory. Staying online
from an online initial condition satisfies minimum-up/down restrictions and
introduces no startups. Energy-window sums, if present, are unchanged. P/Q
network injections, voltages, branch flows and contingency evaluations are
identical. Online cost stays zero; nonnegative transition costs disappear; the
reserve conversion cannot increase cost. The mapped solution therefore has an
objective at least as good as the original.

This is a dominance restriction preserving the best attainable objective, **not
an assertion that the original and reduced binary feasible sets are identical**.
It is not a prior solution, arbitrary must-run assumption, or heuristic PMIN
relaxation. The raw model is still used for independent and official validation.

The same sufficient conditions also preserve the best continuous relaxation
objective. For a fractional status `u`, summing the consumer's online and offline
downward-headroom inequalities gives `P + r_down + r_ramp_down <= PMAX` after
conversion. Summing its capability bounds gives at most
`cap_online*u + cap_offline*(1-u) <= cap_online`. With empty power curves, all
other implication bounds only expand when `u` becomes one. The ramp-envelope
guard and zero/nonnegative status costs apply as above. Fractional witness and
LP-optimum comparison tests are included and passed on the tiny fixture.

## Development evidence and required tests

The implemented guard was evaluated read-only on the raw C3E4N02000D2 scenario
005 input (no model construction or solve): all 1,350 consumers qualify and none
are rejected. The same full guard must be applied at runtime before fixing anything.
There are 64,800 consumer on-status decisions over 48 intervals; startup/shutdown
indicators become implied by the original evolution constraints. No runtime
improvement has been measured yet.

Syntax-tree checks passed for the dormant implementation and test script. All
25 pure guard tests passed using `scripts/test_consumer_dominance.jl
--guards-only`; that path does not import or invoke an optimizer. They include
exact-nonzero PMIN/cost rejection, unequal interval durations, initial shutdown
power, required offline intervals and the reserve conversion's capacity/price
conditions. After r03 finished, 46 exhaustive binary-witness tests and 15
fractional-relaxation tests passed too (86 assertions total). They enumerate all
eight three-period commitment patterns, map actual LP/MILP points to the original
unreduced constraints, and compare optimal objectives in both formulations.

Before launch, the complete matched-runtime gate must also pass the independent
and official tiny pipeline with the reduction enabled. The current registration
does not permit a full-case diagnostic or warmup. A complete tested-source
inventory guards against launching new or modified code after the test gate.
