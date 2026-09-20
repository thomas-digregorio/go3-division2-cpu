# Low-memory 23,643-bus scheduling redesign (development)

This work continues the explicit user goal to make C3E4N23643D2 scenario 003
work on the same laptop. No new full attempt has been launched or claimed.

## Measured reason for a structural change

The immutable r05 unsolved matrix has 19,323,456 original columns and 20,211,928
rows. The exact zero/alias representation still has 15,253,134 columns and
17,635,208 rows. A streaming name/mapping audit (no optimization) confirmed all
17,635,208 retained row identities. Major retained column families are:

- 3,698,784 cost-block variables;
- 2,592,720 commitment/startup/shutdown variables;
- eight large online/active/reactive reserve families, plus offline products;
- 864,240 active dispatch and 857,294 reactive dispatch variables.

Source reserve capacities include small **nonzero** values. They cannot be
rounded to zero. Simply deferring reserves previously damaged the 2,000-bus
score. The proposed route therefore feeds reserve costs back to commitment and
dispatch rather than ignoring them.

## Proposed exact scheduling decomposition

Keep the complete 48-hour commitment/dispatch master, including the original
PMIN, startup/shutdown, ramp, duration, energy and startup-window constraints.
Separate source reserve variables by hour. With commitment and dispatch fixed,
each hour's reserve allocation is a continuous LP. Only one reserve LP needs
to be resident at a time. Per-hour cost epigraphs and valid lower cuts return
reserve costs to the master. The master remains a scheduling subproblem, not
a global AC/GO3 optimality certificate.

In minimization notation the reserve LP is

    min c'y, subject to L <= A y + P x <= U, 0 <= y <= Y.

For sign-correct row multipliers pi, let r = c - A'pi. A valid lower cut is

    theta >= pi'b + sum_j min(0, r_j Y_j) - (P'pi)'x,

where b selects the lower row bound for positive multipliers and the upper
bound for negative multipliers. An infinite Y requires r >= 0. This is a
Lagrangian box bound; it does not rely on approximate native dual feasibility.
The certificate implementation uses outward-rounded interval arithmetic,
repairs unsafe multipliers, and accounts for coefficient rounding over the
original parameter domains. If it cannot certify a useful cut, a valid zero
cut is recorded as weak, **not** as convergence.

The source reserve costs and recourse lower bounds must meet the checked
nonnegative-cost/zero-lower-bound contract. Unknown structures must stop rather
than be silently omitted. Complete raw-model primal auditing, AC refinement,
all 48 hours, all 1,289,760 source outage-hour checks, the existing physical and
score gates, and the 7,200-second limit remain mandatory.

## Development status

The lower-cut certificate and disk partitioner are implemented. The focused
gate passed **736 Julia assertions** (606 certificate and 130 partition tests),
and the existing **130 Python tests** also passed. Tiny source-feature and DC
fixtures reproduce the original joint scheduling objective after recomposition
and pass both compact and original-model primal checks. Deliberately invalid
recourse domains/costs, cross-period recourse coupling and tampered files fail
closed. A test-fixture naming error was corrected before the final focused
gate; no full solve was launched by the failed test.

Two bounded, unsolved-matrix diagnostics were performed. They do not optimize
the competition case and are not benchmark or warmup runs. The second adds
proved bound-redundancy removal for **additional master projections only**;
all original rows remain in the reserve LPs or master exactly once.

| Representation | Variables in largest model | Rows in largest model | Nonzeros in largest model |
|---|---:|---:|---:|
| Previous monolithic exact-compacted schedule | 15,253,134 | 17,635,208 | 68,232,594 |
| Initial decomposed master | 8,043,170 | 17,325,992 | 39,128,554 |
| Master after proved redundant-projection removal | 8,043,170 | 10,931,162 | 32,733,724 |

There are 48 separate reserve LPs. The largest has 150,274 variables, 210,547
rows and 553,267 recourse nonzeros (parameter coefficients are stored separately).
The full audit checks all **15,253,134 compact source columns and 17,635,208
compact source rows**, exact source coefficient/domain preservation, complete
partition coverage, and all 6,394,830 omitted bound-redundant master projections.
The earlier exact-compaction proof links these compact rows back to the complete
19,323,456-column / 20,211,928-row scheduling model.

The final partition-and-proof diagnostic completed in **119.150 seconds**, with
peak sampled process-tree RSS **4,209,602,560 bytes (3.920 GiB)** and zero solve
calls. The initial partition audit completed in 130.001 seconds. These are
preprocessing diagnostics only: **neither is evidence of solver RAM usage,
optimization time, scheduling convergence, AC feasibility, or a successful
23,643-bus run**.

Evidence is retained in `evidence/components/reserve_decomposition_20260920/`
and `evidence/diagnostics/reserve_partition_20260920/`. The final local diagnostic
directory is `tmp/reserve_partition_diagnostic_621032b1`; its partition manifest
SHA256 is `ccb10af722c6980c7e11d40c6be75f7c91ca232e15e5fdcc27f98291d14e642f`.

The bounded master/recourse coordinator and production-pipeline integration are
now implemented and undergoing the tiny-fixture integration gate. Native
master and recourse stages run in separate, sequential processes. Each round
checks every source reserve period, constructs certified lower cuts, and
reconstructs/audits all original scheduling rows before saving an incumbent.
Subsequent masters receive a complete, within-attempt, audited primal start;
API acceptance is logged separately from native-log evidence of consumption.
Small cut coefficients are weakened conservatively before native insertion,
never silently discarded in a way that invalidates a lower bound.

An infeasible hourly reserve LP invokes a separate elastic Phase I. Its
certified positive lower bound yields a necessary feasibility cut on the
continuous master domain. Phase-I slack is never accepted as a reserve
schedule or an original-model feasibility repair. A tiny test exposed overly
conservative FP64 interval cancellation in zero-cost columns. Ambiguous
zero-cost/unbounded-column proof sums are now refined with directed MPFR
arithmetic; source/solver values remain FP64 and source tolerances are unchanged.

The orchestration uses a single absolute scheduling budget, reserves time for
recourse and serialization, retains previously audited incumbents, and reports
the joint scheduling gap against the master upper bound. A restricted-master
gap alone cannot terminate successfully. A budget-limited scheduling incumbent
can proceed to the unchanged AC/official pipeline without being described as
gap-certified; full campaign acceptance still requires every physical, score,
coverage and end-to-end time gate below. Each full attempt must start from raw
inputs rather than any unsolved diagnostic partition or old solution.

The complete regression gate and a newly registered frozen cold experiment
are still required. The existing historical full-gate manifest is not current
proof for these changes. Previous production configurations and run records
are unchanged, and the score/time/full-verification goal is still unachieved.

### Focused coordinator integration gate

`tmp/reserve_loop_components_q0v1747z` passed 9 stages: 133 Python tests,
606 lower-cut certificate assertions, 46 native-runtime assertions, two
analytically solvable multiround fixtures, and the original three-period DC/AC
tiny pipeline with independent and official evaluation. The cost-feedback
fixture converged in two rounds; the infeasible-recourse fixture required a
certified Phase-I cut and three rounds. Both attained the independently known
joint objective -0.75 with maximum original-model residual zero.

The source DC fixture required two scheduling rounds and reached objective
1732.1479 with zero scheduling gap and residual. Its native HiGHS log explicitly
reported that the complete prior-round MIP start was feasible. The simpler
fixtures recorded successful API acceptance and explicit start residual checks,
but presolve solved their masters without a log entry confirming incumbent
consumption; these two facts are not conflated.

The final three-period AC candidate has objective **1732.1459647319407**, the
same serialized candidate SHA256 as the earlier pipeline
(`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`).
Independent hard-constraint checks passed, official `feas=1` and `phys_feas=1`,
and all **9/9** source outage-hour checks completed. This is small-fixture
integration evidence, not a solved or timed 23,643-bus case.

The first integration gate stopped before AC because Windows' synchronous
Python venv launcher and its interpreter have different PIDs. The exit record
now binds the actual coordinator PID and its direct launcher parent, while
retaining exact PID matching for Julia workers. A regression test covers this
distinction. The old incomplete gate is not counted as a pass. Compact evidence
is archived in `evidence/components/reserve_benders_loop_20260920/`.
