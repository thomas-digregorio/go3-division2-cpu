# Isolated native scheduling and startup diagnostics

The r03 transfer completed, but host RAM crossed the unchanged 2 GiB available
floor about six seconds into `Highs_run`. This did not establish infeasibility or
identify a specific internal allocation. The 19,323,456-variable original MILP
still requires substantial native MIP bookkeeping before presolve.

## Exact-model storage policy

`disk_isolated_native_v1` retains the r03 immutable numerical spool and all source
rows, columns, bounds, domains, coefficients and objective terms. With compaction
off it changes process lifetimes, not equations or acceptance tolerances:

1. The controller validates the raw case in a short-lived Python child. Only the
   compact input manifest remains in the controller after that child exits.
2. The original Julia builder constructs and exports the complete unsolved model,
   then exits. No previous schedule, basis, bound or optimized state is imported.
3. A lean Julia/HiGHS process validates the spool and solves it exactly once. It
   does not parse the raw network, deserialize extraction metadata, import
   GOC3Benchmark or Ipopt, or construct a JuMP optimization model. The empty
   HiGHS.jl interface sets options; the C API loads the numerical arrays.
4. Native primal/statistics are saved with source/configuration/matrix hashes.
   The native model is destroyed and its process must exit successfully.
5. Only then does the usual worker load the network and reconstruct a read-only
   result facade for the unchanged upstream schedule extractor. It does not
   optimize the scheduling model again. Reserve allocation, all 48 AC intervals,
   independent verification and exhaustive official evaluation are unchanged.

The native scheduling options request one thread, `parallel=off`, and analysis
level 384 (MIP and presolve timing). Every option is checked by readback. Ordinary
solver presolve remains enabled/automatic. Reserve and AC settings, source
PMIN, 1e-3 scheduling gap, numerical tolerances, two-hour overall deadline,
verification reserves and the 2 GiB/30 GiB memory/disk floors are unchanged.

Memory is sampled every 250 ms by owned PID, including RSS, private/virtual
memory and host availability, and paired with the latest native stage. This is
process/stage attribution, not a heap-allocation profiler; without further
instrumentation it cannot attribute a spike to an individual C++ allocation.

## Bounded diagnostics versus cold experiments

The user authorized a couple of attempts. This change allows at most two new
full attempts in this campaign and at most two bounded startup diagnostics.
The diagnostic command accepts an existing hash-bound, unsolved spool, never a
solution. It has a maximum 180-second work budget and no AC or verification
launch. The only diagnostic option overrides allowed are threads, parallelism
and timing logging. Diagnostic results are explicitly marked and cannot be
restored by the production reader. No diagnostic is reported as a cold run.

Each actual experiment retains its own immutable authorization latch, rebuilds
the model from raw data, uses a freshly tested/pushed revision, and includes all
process startup, parsing, export, hashing, solving and checking in its original
7,200-second limit. Passing the memory gate is not a successful GO3 result: the
unchanged full-pipeline, physical feasibility, exhaustive contingency and
published-score comparison gates must all pass.

## Initial component evidence (2026-09-19)

Before the large-matrix startup diagnostic, 127 Python tests and 28 isolated
Julia interface assertions passed. The three-process 2-bus integration at
`tmp/isolated_smoke_20260919_03` completed all three AC intervals. Independent
and official verification passed all 9/9 outage-hour checks, with objective
1732.1459647319407, physical feasibility 1 and hard feasibility 1. Its final
solution SHA256 is `1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`,
identical to the previous disk-backed tiny baseline. Native scheduling used
one solve call and its process exited before AC loading. This targeted evidence
does not replace the complete fresh component gate required before a full run.

## Isolation-only diagnostic and exact compaction

The first bounded startup diagnostic (`native_startup_diagnostic_im9woerc`)
reached native presolve, unlike r03, but still crossed the safety floor. It
stopped after 29.354 seconds at 1.903 GiB host availability and approximately
18.82 GiB owned process RSS. It supplied no optimized start and was not a cold
end-to-end experiment. The diagnostic did not return a feasible solution.

The proposed exact-compaction fallback is therefore enabled for r04 with
`scheduling_compaction_policy=exact_zero_alias_v1`. It changes the solver matrix
representation, but not the mathematical scheduling problem. The original
matrix remains immutable. The only operations are:

- Substitute exactly zero variables, proved by their existing fixed bounds,
  a homogeneous singleton equality, or a zero-limited sum of one-signed terms.
- Identify x=y only when an existing homogeneous two-term equality proves it.
  Intersect their original domains; retain integrality if either is integer.
  Merge only when at most one objective coefficient is nonzero.
- Remove a transformed row only when it is exactly the tautology
  `lower <= 0 <= upper`. Keep empty inconsistent rows. Reject any coefficient
  merge that would require floating-point rounding rather than exact addition.

No nonzero fixed-value substitution, approximate dependence test, tolerance
relaxation, PMIN change, source row omission, reserve weakening, or heuristic
fixing is allowed. A bounded reduction-pass count changes compactness only.
Every operation has a source-row proof record. A separate replay checks those
proofs, every transformed coefficient/domain/objective coefficient, every
original row, and the complete original-column reconstruction mapping. That
process exits before HiGHS starts. The native solve then uses the smaller
equivalent matrix; its result is reconstructed into all original columns and
checked against every original scheduling row, bound and integer domain at
the existing 1e-8 scheduling-point audit tolerance. All native solver tolerances
remain unchanged. An original scheduling audit is not full GO3 certification;
the unchanged AC, independent and official checks are still mandatory.

Compaction and proof checking are included in a cold run's total time. Fifteen
seconds of the remaining work budget are withheld from the native solve for
reconstruction/auditing. Startup diagnostics remain separately labelled and
cannot be used as production solver results.

The second bounded diagnostic (`native_startup_diagnostic_xof2cbvs`) produced
15,253,134 columns, 17,635,208 rows and 68,232,594 nonzeros. It identified
3,221,028 zero columns and 849,294 aliases, with 2,562,828 recorded inference
steps. It hit its 180-second diagnostic limit DURING proof replay, before a
proof-completion record or native solve. Its peak sampled process RSS was
approximately 4.57 GiB. These counts are transformation output, not yet a
completed large-model equivalence certificate or a solved case. Both diagnostic
records are preserved under `evidence/diagnostics/native_memory_20260919`.

The checker subsequently received concrete array/dimension type assertions and
substage progress counters to avoid unnecessary dynamic-dispatch overhead and
make long verification work visible. The 196 mathematical-equivalence/source
fixture tests and 28 isolated-interface tests passed after that adjustment.
The compacted 2-bus full pipeline independently passed 9/9 source checks and
produced the exact same final-solution hash listed above. A fresh complete
regression gate is still required before the first new full cold attempt.

## Complete pre-run gate

The fresh gate `tmp/pilot002_component_gate_tl85vedi` completed successfully:
**63/63 stages, 129 Python tests and 13,923 Julia assertions**, with 1,586.006
seconds summed stage time. Its source inventory matches the current code and
registered configuration. Both isolated and exact-compacted integration paths
passed independent and official verification for all 3/3 intervals and 9/9
source outage-hour checks. The compacted path's reconstructed scheduling point
has zero original-model residual. Its final solution is byte-identical to the
previous disk-backed tiny baseline listed above.

The complete manifest, all stage logs and the new compact certificates are
hash-verified copies in `evidence/components/isolated_compaction_20260919/`.
This gate permits r04 to start; it does not establish that the large native
solver will fit in memory or that the full GO3 case will pass.

## r04 outcome and final authorized native-presolve experiment

r04 used frozen commit `c8f00179614af3526a2c5cbd50e0b76847af7b41` and stopped
after **1,297.815 seconds** without an incumbent. The full compaction proof did
pass: 2,562,828 inference steps, 19,323,456 original columns and 20,211,928 original
rows. Transformation plus proof took 194.721 seconds. Native HiGHS accepted the
15,253,134-column / 17,635,208-row / 68,232,594-nonzero compact model, entered
presolve, and reported 13,791,058 rows / 15,041,285 columns / 61,767,371 nonzeros
after 75 seconds. It later crossed the unchanged RAM floor at 1.807 GiB available.
Peak sampled process-tree RSS was 19.205 GiB. No AC interval or independent
full-case verification ran. This is a resource failure, not infeasibility.

The last native log message was `Sparsify removed 0.0% of nonzeros`. The pinned
[HiGHS v1.15.1 presolver source](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/highs/presolve/HPresolve.cpp)
calls parallel-row/column detection after that section, and that routine creates
full row/column hash and maximum-coefficient arrays. This makes that optional
pass a plausible allocation source; the process-level trace does not prove the
exact C++ allocation that crossed the floor.

r05 is the **second and final** full attempt under the current authorization.
It changes only the attempt ID and `scheduling_native_presolve_policy` to
`skip_parallel_rows_cols_v1`. The adapter sets and reads back
`presolve_rule_off=8192` (rule 13 in pinned HiGHS). Other presolve rules, the
matrix, exact-compaction proof, objective, integrality, tolerances, AC pipeline,
verification and safety limits are unchanged. This skips an optional solver
reduction, not any source constraint. It may leave a larger root problem and is
not a guarantee of lower peak memory or faster completion. Tiny feasible and
infeasible MIP fixtures compare this setting with default presolve; the complete
compacted integration must also pass exhaustive verification before launch.
