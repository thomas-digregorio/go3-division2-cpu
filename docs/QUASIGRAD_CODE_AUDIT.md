# Read-only alternative-solver audit

This is source review, not adoption or an experiment. No alternative solver has
been installed, initialized, precompiled or executed. Active r03 is unchanged.

Repository: <https://github.com/SamChevalier/QuasiGrad.jl>, inspected revision
`eb2328512555f406d3cf3d008d611e6e5aa6a7a5`. Its code is MIT-licensed, copyright
2023 Sam Chevalier. The ignored audit checkout is
`.cache/upstream/QuasiGrad.jl`; it is not a registered runtime dependency.

## Relevant findings

- `src/QuasiGrad.jl` imports Gurobi and creates a Gurobi environment in `__init__`.
  `Project.toml` and the README also require Gurobi. An open code license does not
  make the default solver stack open-source-only. Do not load this package as-is.
- `compute_quasiGrad_solution_d23` in `src/scripts/solver.jl` initializes economic
  dispatch, alternates power-flow/Adam stages with progressively stronger binary
  projection, then performs constrained power-flow and reserve cleanup.
- `src/core/economic_dispatch.jl` relaxes commitment binaries for initialization.
  At 125,000 device-intervals it switches from a whole-horizon LP to parallel
  interval LPs followed by device-wise projection. This is a candidate-generation
  strategy, not a certificate that isolated interval solutions satisfy temporal
  constraints.
- `src/core/projection.jl` performs independent per-device temporal MILPs with
  linear absolute-deviation objectives. Its optimizer options are Gurobi-specific.
- `src/core/power_flow.jl` and the final cleanup use quadratic regularization
  objectives and linearized network constraints. A backend replacement therefore
  requires LP, MILP and convex-QP coverage, not just renaming one optimizer.
- Final cleanup has a reserve-penalized variant. This is relevant to protecting
  reserve headroom after scheduling; our current AC stage uses a generic dispatch
  deviation penalty instead of directly co-optimizing reserves.
- The precompile competition-case workload in `src/QuasiGrad.jl` is inside a
  commented block. Nevertheless no package load or examples were executed.

The clone included bundled raw examples, supplied POP solutions and a precompile
case. Only filenames/sizes were inventoried; their contents were not read or used.
The audit working tree was narrowed with Git sparse-checkout to code, README,
Project.toml and LICENSE, excluding JSON. Omitted files are recoverable from the
clone's Git objects. No user's source cases, solutions or evidence were deleted.

## Decision

Do not replace the current runtime with this package. Useful architectural ideas
are smaller commitment-repair subproblems, parallel interval work with explicit
temporal repair, and reserve-aware AC cleanup. Each would need an attributable,
open-source-only implementation and tiny-fixture checks against the unchanged
independent and official evaluators. No performance or quality gain is claimed
from this review.
