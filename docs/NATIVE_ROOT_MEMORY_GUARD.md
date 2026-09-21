# Optional analytic-center LP opt-out and root-only presolve

The active user goal is to obtain a fully verified 23,643-bus solution on the
existing low-RAM laptop. Attempt r07 reached the first root LP, but the host
memory guard interrupted it at 1.962 GiB available RAM. The native-stage sampler
observed approximately 18.99 GiB resident memory. This is not an infeasibility
proof, and the case has not yet been solved successfully.

## Source-backed change

Pinned HiGHS 1.15.1 commit `04024d701f79feb8e2f18bc3df0dffc04ef05088`
unconditionally sets `compute_analytic_centre = true` in `evaluateRootNode`.
It schedules a separate task that creates another `Highs` object, copies the
presolved LP, zeroes that auxiliary objective, clears integrality, and calls an
interior-point solver. This happens even when the ordinary MIP LP solver is
registered as simplex. The auxiliary point supports optional domain reduction
and central-rounding heuristics; it is not the objective-bearing root relaxation.

The cumulative patch `patches/highs-1.15.1-root-memory-guard.patch` adds a Boolean
`mip_compute_analytic_center` option. Its default is **true**, preserving upstream
behavior. The registered `root_memory_guard_v1` policy explicitly requests **false**.
All existing start/finish branches in `evaluateRootNode` already test the same
flag, including root restarts. `centralRounding` already returns if the analytic
center vector is absent. No fictitious center or zero vector is supplied.

The ordinary root LP, objective, integer domains, branch-and-cut proof machinery,
source feasibility checks and tolerances are retained. Skipping this auxiliary
calculation can reduce optional bound tightening or primal-heuristic performance;
there is no guarantee of faster solution or a smaller overall search tree. It
does not permit an infeasible point or an uncertified bound to pass any gate.

### Serial-task caveat and the additional upstream option

Further read-only source inspection before any r08 full-case launch found an
important attribution caveat. `HighsTaskExecutor(1)` creates no background workers;
`TaskGroup::spawn` queues the auxiliary task. The first ordinary LP is called
before `finishAnalyticCenterComputation`. The r07 message "starting analytic
centre calculation" therefore does not prove that the auxiliary LP had executed
when memory ran out. Disabling it alone may not affect the r07 failure point.

`HighsLpRelaxation` constructs a separate `Highs` instance without inheriting the
outer `presolve_rule_off=8192` option. At the first root LP, `evaluateRootNode`
normally sets its presolve on. `Highs::calledOptimizeModel` then invokes a second
LP presolve, with fresh workspace, on the already MIP-presolved model. This is a
source-backed allocation opportunity, not a measured per-routine memory profile.

Before claiming r08, the registration was extended to set the **existing upstream**
`mip_root_presolve_only=true` option. It preserves initial MIP presolve but disables
the ordinary first-LP presolve and several later repair/sub-MIP presolves. This
may use more simplex iterations or make heuristics slower. The native DLL and
patch are unchanged. The option is applied/read back through the API, recorded in
each master result, and tested in combination with both auxiliary-LP settings.

The prior complete-gate attempt `tmp/pilot002_component_gate_c6qt51h2` was
intentionally stopped before these source/configuration changes: 21 stages had
reported success; `ac_interval_start_tests` was active. The owned process tree
exited, logs were retained, and no passing new manifest or full-case run was
produced. It is not a complete gate for the revised configuration.

Root timing markers now bracket root entry, LP loading, and the first LP solve.
A skipped center is logged explicitly. The prior objective-clique cap remains
unchanged. No coefficients, data types, network constraints or physical limits
are changed. FP64 and 32-bit sparse indices remain in use.

## Isolation and preservation

- Separate source checkout: `environments/highs-root-memory-source-04024d701f`.
- Separate native artifact: `environments/highs-root-memory-build`.
- Separate child-only depot: `environments/highs-root-memory-depot`.
- Build manifest: `manifests/native_highs_root_memory_guard_v1.json`.
- Both the installed JLL and r07's `highs-setup-guard-build` are unmodified.
- Compiler and build flags match the r07 local build; no GPU, commercial solver,
  FP32/FP16 conversion, external optimized start, or global environment change.
- Native options are set and read back through the solver API before each stage.
  File hashes, option scope, and exact DLL identity are checked before solving.

The patch can be applied to a fresh checkout of the pinned upstream revision.
Build it with the same CMake flags in `NATIVE_HIGHS_SETUP_GUARD.md`, replacing the
source and build directories with the root-memory paths above. Do not overwrite
either retained prior build. Rebuilding requires new explicit artifact hashes
and a fresh source-matched component gate before a full-case run.

## Tests and experiment contract

The first direct test passed eight tiny mixed-integer solves, with the analytic
center both enabled and disabled, against exhaustively enumerated optima and
matching objective bounds. All reached and completed the ordinary root LP;
the disabled cases logged the skip. Two infeasible fixtures remained infeasible.
The test produced 196 passing assertions; nine Python policy tests also passed.

The complete component gate additionally checks the new library's recourse LP
dual/feasibility certificates and a full three-period source-DC/AC decomposition
pipeline. All source checks, audited within-run starts and independent/official
exhaustive verification must pass. Earlier stock and setup-guard pipelines remain
in the gate. Tiny test success alone is not large-case acceptance.

Registered r08 differs from r07 only by pilot ID, backend policy, the explicit
analytic-center opt-out and the root-only presolve option. It retains the
7,200-second end-to-end limit, 2 GiB host
memory floor, 30 GiB physical disk floor, original model/PMIN/tolerances, all 48
periods and all 26,870 source contingencies per period. The score target and
independent/official acceptance gates are unchanged. No r07 latch is reused.

The r07 logs did not identify allocations by routine. Removing the auxiliary LP
and avoiding repeated presolve are a controlled next attempt, not a claim that
either was the sole memory consumer. The ordinary root LP or later AC
factorization may still exceed the laptop's available memory. Full-case results
will determine that.

## Earlier completed focused integration (auxiliary-LP opt-out only)

The new backend's tiny end-to-end gate in `tmp/reserve_loop_components_djuryurv`
passed all 11 stages, including 151 Python tests. All original scheduling audits
passed. Sixteen designated solver workers loaded the exact new DLL and recorded
the auxiliary LP disabled. The three-period candidate passed independent and
official verification: 9/9 contingency checks, both official feasibility flags 1,
hard residual 0, and maximum P/Q imbalance below 2.31e-9 p.u. Its candidate SHA256
matches the earlier stock and setup-guard candidates exactly.

The byte-verified focused archive has 421 files / 710,447 bytes under
`evidence/components/native_root_memory_20260920`. A fresh complete regression
gate is still required before the registered cold r08 attempt. No full-case run
was started by this focused test.

## Revised focused checks (including root-only presolve)

The revised direct native test passed **431 assertions** across 16 feasible solves,
four infeasible solves, and API/scope checks. All four combinations of auxiliary
LP enabled/disabled and root-only presolve enabled/disabled matched enumerated
optima and bounds. All 152 Python tests passed, including 10 native-policy tests.

The focused pipeline `tmp/reserve_loop_components_zsqmg03s` passed all eight
integration stages. All 16 solver workers had the exact registered DLL identity;
all eight master results recorded accepted/read-back `mip_root_presolve_only=true`
and `mip_compute_analytic_center=false`. The multiround cut/start and intentionally
uncertified bounded-incumbent tests passed. The final three-period AC solution
again passed both independent and official verification, with 9/9 source
contingency checks, objective 1732.1459647319407, hard residual 0, P imbalance
1.526e-10 p.u. or less and Q imbalance 2.307e-9 p.u. or less. The candidate hash
is identical to the earlier tiny baseline. No large-case result is inferred.

The hash-verified archive is
`evidence/components/native_root_only_presolve_20260920/focused_integration`:
741 files / 1,030,170 bytes, with original logs and outputs retained. Its sibling
stop record preserves the intentional cancellation of the superseded incomplete
suite. No full-case run or authorization latch has been consumed for r08. The
next required gate is a fresh complete source-matched regression suite.

## Complete regression gate

The fresh suite `tmp/pilot002_component_gate_r_75l1ov` finished successfully on
2026-09-20: **73 stages, 152 Python tests and 15,451 Julia assertions**. Summed
stage wall time was 2201.675 seconds (setup, not a competition-case timing).
Every stage returned zero; the final manifest is complete, names this exact
evidence directory, and its complete source inventory matches the frozen code.
All test processes exited. No full-case run was started by this gate.

The stock, setup-guard and root-memory decomposition pipelines all passed. The
root-memory pipeline independently checked all 16 worker identities and all
eight master option records. Its final solution again has SHA256
`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`,
objective 1732.1459647319407, hard residual 0, both official feasibility flags 1,
and complete independent/official coverage of all nine tiny contingency checks.

The full suite, all three nested decomposition integrations, and the completed
manifest are retained under
`evidence/components/native_root_memory_full_gate_20260920`. Original evidence
directories are also retained. This qualifies the unchanged registered r08
configuration for preflight; it does not establish large-case memory sufficiency
or successful solution of the 23,643-bus case.

## Full-case r08 outcome

The registered r08 attempt is now complete, with `NO_VERIFIED_INCUMBENT` after
1816.156 seconds. Its memory guard did not fire (minimum sampled native-stage
host availability 2.574 GiB), but the first native master exceeded its 600-second
allowance while the ordinary root LP remained unfinished. No AC refinement or
final large-case verification ran. See `CAMPAIGN_N23643_R08.md` and the retained
interruption record. The numerical matrix/bounds/cost/domain/name fingerprints
match r07. This is progress in identifying the limiting gate, not proof that the
full solve fits memory or that the 23,643-bus goal has been achieved.
