# Disk-backed scheduling transfer (r03)

The 23,643-bus r01/r02 attempts exhausted physical memory before optimization.
Their complete 19,323,456-column JuMP construction model overlapped with a native
model, Julia metadata/index maps, copied affine functions, triplets and a CSC
matrix. Neither failure was an infeasibility result.

The opt-in `disk_backed_native_v1` policy changes storage and process lifetime,
not the scheduling formulation or numerical options:

1. A dedicated builder loads the same raw input and calls the unchanged pinned
   upstream formulation plus the same project source-penalty/startup/dominance
   adapters. It never calls an optimizer.
2. Existing construction-only metadata cleanup runs. Every mathematical row and
   column remains. The exporter writes FP64 binary CSR in the same constraint
   family order used by the pinned HiGHS.jl adapter. It holds one affine row at
   a time, not a second whole matrix. Column vectors are linear-size temporary
   storage; each output stream has a bounded 1 MiB buffer. This does not make
   initial construction itself out-of-core.
3. Objective sense/offset, costs, all variable bounds, integer domains, row
   bounds and coefficients are retained. Binary bounds are intersected with
   [0,1], exactly as HiGHS.jl does before solving; generator PMIN is not clipped.
   No rows or columns are eliminated. Unsupported domains, starts or nonlinear
   expressions fail closed. Original names/indices are retained in sidecars;
   numerical native loading uses positions rather than per-row Julia objects.
4. The builder exits. Only after an exit-0, source/config/hash-bound completion
   record can a new worker load the arrays. Read-only memory maps feed HiGHS's
   public `Highs_passMip` API. Dimensions/nonzeros and import return status are
   checked. Mapping arrays are released before the single native solve.
5. HiGHS receives the unchanged registered options. A read-only JuMP result
   facade exposes the native primal by original column index to the unchanged
   upstream schedule extractor. This is not a second model or solver. No start,
   old schedule, bound or basis is imported. The native model is destroyed
   before reserve allocation and AC refinement.

API reference: [HiGHS C interface](https://ergo-code.github.io/HiGHS/dev/interfaces/c_api/).
Installed HiGHS/Julia versions, raw/config identity, inventory, hashes and exact
file lengths are checked. Partial spools are not reusable successes. A new cold
attempt always rebuilds from source; no stale spool reuse is permitted.

The ordinary process-tree monitor covers builder and solver, preserving the
2 GiB available-memory and 30 GiB physical-disk floors. All loading, export,
hashing, process startup, JIT, solve, AC refinement and exhaustive verification
remain inside 7,200 seconds. The 2,400-second verification and 30-second
finalization reserves are unchanged. Scheduling's actual native time allowance
is recomputed after import against the absolute work deadline. A numeric model
or presolve may still exceed available memory; this design is not a promise
that the entire 23,643-bus pipeline will fit or finish.

Tiny tests compare every native coefficient, bound, domain, objective, row,
column and retained name against the original model, including both objective
senses, integer/binary/fixed variables, all scalar affine sets, constants,
source startup/PQ constraints and infeasible empty rows. Integration must pass
the original independent and official exhaustive validators after AC/DC and
reserve refinement. The previous successful 8,316-bus attempt is not repeated.
