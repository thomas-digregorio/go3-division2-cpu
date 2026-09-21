# r14: complete current-schedule initialization and preserved primal restarts

Status: focused tests and the complete source-matched regression gate passed.
One cold r14 full-case attempt is registered, subject to frozen-commit preflight.
The component pass is not a full-case feasibility or optimality claim.

## Evidence motivating the change

The frozen r13 attempt (implementation `630fd7fdcb89ab37703751f8cb76d90ef6e0d6f1`)
completed scheduling, its 48 source reserve subproblems and the original full
scheduling audit within the laptop memory guard. The requested symbolic
derivative evaluator was confirmed inside all three native AC calls. Its first
hour still failed the unchanged `1e-8` model-residual screen. See
[the terminal r13 evidence report](CAMPAIGN_N23643_R13.md).

The rounded-shunt point had an independently recomputed model residual of
`0.0005658237700654212`, but the subsequent same-model recovery started with
printed original infeasibility `1.80`. Recovery explicitly selected `0.01`
interior pushes, which can perturb many active-bound values simultaneously.
This is evidence of restart damage, not proof that pushes explain all of r13's
convergence problems. The continuous-to-rounded transition also changes shunt
fixings, so that transition is not an identical-model comparison.

The first AC model previously used current scheduled P mainly as a deviation
target. Auxiliary source-cost blocks and reserve variables could keep default
starts. Completing this vector does not make the network equations feasible;
it removes an avoidable mismatch in the supplied algebraic start.

## Opt-in implementation

`ac_initialization_policy = current_schedule_preserving_restarts_v1`:

1. Initialize the first hour's complete primal from this attempt's audited joint
   schedule: P, Q, all ten reserve products, source cost blocks, reserve peaks,
   shortfall auxiliaries and dispatch-deviation auxiliaries. Keep the upstream
   voltage, angle and network-device starts. Populate any remaining defaults.
2. Project **initial values only** onto the exact model bounds and cost-block
   capacity intersection. No source bound, PMIN, cost coefficient, constraint or
   objective is edited. Never read an optimized point from an earlier run.
3. Use regular primal-only `bound_push`, `bound_frac`, `slack_bound_push` and
   `slack_bound_frac` of `1e-8`; `warm_start_init_point=no`. These push values were
   already used in adjacent-hour continuation. Do not invent dual starts.
4. Preserve the existing complete primal-dual transfer when the continuous
   point is converged, locally residual-verified and has valid mapped duals.
   Otherwise preserve the complete primal using small pushes. A fresh recovery
   optimizer clears old dual starts and uses these same small primal pushes.
5. Read the actual native iteration-zero vector for continuous, rounded and
   recovery phases. Log its complete identity mapping, maximum absolute and
   relative movement from the requested start, and original unscaled residual.
   The continuous callback is **audit-only**, never an early-stop rule.
6. The rounded/recovery guard probes original unscaled NLP violations. The
   callback's scaled internal slack residual is not an equivalent test. Any
   guarded stop still requires the existing objective-stability window and a
   full independent JuMP residual audit at the unchanged tolerance. Callback or
   mapping failures are errors, not accepted incumbents.

The previous `legacy_v1` path remains selectable for exact historical replay.
`r14` differs from `r13` only in attempt ID and this initialization option.
Budgets, memory/disk floors, FP64, all 48 hours, source constraints and costs,
contingency coverage and the score target remain unchanged.

## Tests and run gates

- Bound-active tiny nonlinear fixture: native initialization with default
  pushes moves by `0.01`; small pushes move by approximately `1e-8`, while the
  exact model, bounds and tolerances are unchanged. This is not a full-case
  runtime forecast.
- Complete source-schedule/PWL/reserve mapping, explicit rejection of missing,
  nonfinite and improperly filtered device data, and source-model equality.
- Forced iteration-limited tiny continuous and rounded calls, then a fresh
  recovery: actual symbolic evaluator, small pushes and original start audits
  remain active; the returned point must pass the same residual screen.
- Full three-hour tiny pipeline with independent and official verification of
  all nine source contingency/hour pairs; valid dual transfer must still occur.
- Fresh complete regression suite, source-hash equality at beginning/end,
  immutable archived logs and certificates, frozen pushed commit and read-only
  preflight, before exactly one registered cold full-case attempt.

Final full-case success still requires all 48 refined AC intervals, final reserve
optimization, independent and official exhaustive verification, the existing
physical-feasibility and score gates, and the 7,200-second end-to-end deadline.
No scheduling construction objective or fixed-integer LP bound is represented
as an original economic MILP certificate.

## Focused evidence

`tmp/focused_ac_initialization_ij_vaopw` completed the 83 new Julia assertions,
168 Python tests, the three-hour tiny DC-device pipeline, and independent plus
official verification of all nine contingency/hour pairs. All three intervals
retained eligible valid dual transfers. Tiny objective: `1732.1459693041643`;
maximum P/Q imbalance: `8.0491e-16` / `1.2688e-14` p.u.; official feasibility and
physical-feasibility flags both 1. This focused check is not authorization to
skip the full source-matched regression gate.

## Complete regression evidence

The new gate `tmp/pilot002_component_gate_wbxlbv_w` finished with exit code 0:
86 top-level stages, 168 Python tests and 16,723 Julia assertions. An additional
read-only audit checked all 211 source-file hashes, all 126 parent/nested stage
log hashes, the five nested eight-stage decomposition integrations and their
certificates. No competition-case solve ran during the gate.

The new complete-initialization pipeline refined all three tiny hours, retained
three eligible complete dual transfers, and passed independent and official
verification of all 9/9 contingency/hour pairs. Its objective and candidate hash
match the focused check above. The older symbolic-policy pipeline also passed;
these are separate tiny tests, not repeated full-case benchmarks.

- Component manifest SHA256:
  `261a6cc1400832655f053c14fdd980fbc62051488fe99e1804ce393bfe5b65f1`.
- New tiny candidate SHA256:
  `8bae61f23793651190154f6e9acfbdada062cdc01243293bf5e9079b3717563d`.
- Sum of recorded regression-stage times: `2828.7090863` seconds, setup only.
- Immutable archive:
  [component evidence](../evidence/components/ac_initialization_20260921/archive_summary.json).

All original temporary evidence remains retained. Archive copying and Git byte
auditing perform no solve and no reevaluation. The r14 full-case outcome will
be reported separately; a component pass never substitutes for its required
48-hour physical, exhaustive-contingency and quality checks.

## Solver reference

Ipopt documents the regular and warm-start interior-push options in its
[official options reference](https://coin-or.github.io/Ipopt/OPTIONS.html).
These initialize solver iterates; they do not require relaxing the model's
original bounds. The experiment does not change floating-point precision.
