# Isolated native scheduling and startup diagnostics

The r03 transfer completed, but host RAM crossed the unchanged 2 GiB available
floor about six seconds into `Highs_run`. This did not establish infeasibility or
identify a specific internal allocation. The 19,323,456-variable original MILP
still requires substantial native MIP bookkeeping before presolve.

## Exact-model storage policy

`disk_isolated_native_v1` retains the r03 immutable numerical spool and all source
rows, columns, bounds, domains, coefficients and objective terms. It changes
process lifetimes, not equations or acceptance tolerances:

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
