# Optional analytic-center LP opt-out

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

Registered r08 differs from r07 only by pilot ID, backend policy and the explicit
analytic-center opt-out. It retains the 7,200-second end-to-end limit, 2 GiB host
memory floor, 30 GiB physical disk floor, original model/PMIN/tolerances, all 48
periods and all 26,870 source contingencies per period. The score target and
independent/official acceptance gates are unchanged. No r07 latch is reused.

The r07 logs did not identify allocations by routine. Removing the auxiliary LP
is therefore a controlled next attempt, not a claim that it was the sole memory
consumer. The ordinary root LP or later AC factorization may still exceed the
laptop's available memory. Full-case results will determine that.

## Completed focused integration

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
