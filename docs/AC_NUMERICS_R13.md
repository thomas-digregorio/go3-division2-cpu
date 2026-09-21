# Explicit modern AC derivative backend and adaptive barrier: r13 design

This is a solver-side numerical change, not a change to GO3 source physics,
source PMIN, reserve semantics, FP64, residual tolerances or acceptance gates.
It follows the first-interval convergence failure documented in
`CAMPAIGN_N23643_R12.md`. No successful large-case result is implied by this
design or by tiny-fixture tests.

## Verified configuration issue

The pinned source's `opf_model.jl` constructs modern JuMP `NonlinearExpr`
constraints with `@constraint`. The old call
`optimize!(_differentiation_backend=GO3.MathOptSymbolicAD.DefaultBackend())`
only selects an evaluator for the legacy `@NL` interface. In installed JuMP
1.31.2, `optimizer_interface.jl` constructs that legacy evaluator only when
`nonlinear_model(model)` is non-null. Otherwise Ipopt.jl 1.15.0 builds its modern
evaluator using `model.ad_backend`, whose default is `SparseReverseMode`.

`scripts/test_ac_numerics.jl` reproduces this behavior on a tiny modern nonlinear
model. The legacy keyword leaves the effective native backend as reverse mode;
the explicit supported attribute makes it `MOI.Nonlinear.SymbolicMode`.
This establishes a backend-selection issue, not that reverse-mode derivatives
were wrong or that symbolic derivatives will necessarily be faster here.

The supported selection mechanism is documented in
[JuMP's SymbolicAD documentation](https://jump.dev/JuMP.jl/stable/moi/submodules/Nonlinear/SymbolicAD/).
SymbolicAD can exploit repeated expression structures, making it a plausible
fit for repeated branch-flow equations. Its large-case runtime and memory
benefits remain an experimental hypothesis.

## Implementation and scope

The opt-in `symbolic_adaptive_v1` policy:

1. Sets `MOI.AutomaticDifferentiationBackend()` to `SymbolicMode()` on each
   fresh optimizer, using the supported modern interface. It does not set the
   attribute again before every solve: the installed wrapper invalidates an
   existing evaluator on every such setter call, even for an unchanged type.
2. Applies adaptive barrier, quality-function barrier selection and
   objective/constraint-filter globalization before the first AC phase, not
   only after two timed-out phases. These are documented
   [Ipopt options](https://coin-or.github.io/Ipopt/OPTIONS.html).
3. Confirms both the configured backend and the instantiated derivative
   evaluator on the actual native optimizer after every solve,
   including a fresh numerical-recovery optimizer. A mismatch throws an error;
   no silent fallback is accepted.
4. Logs model-building time, optimization API time, optimizer-reported time,
   original-model residual-audit time and native Ipopt timing statistics.
   API time includes setup; it must not be relabeled native factorization time.
5. Retains original source expressions, every variable/constraint, bounds,
   objective, precision, shunt-rounding workflow, conditional dual-start guard,
   post-AC reserve optimization and final independent/official verification.

The previous policy remains the default for existing registered configurations,
so historical smaller-network settings are replayable. The new policy is
restricted to the audited reserve-aware AC path, with correction disabled.
It is not silently applied to other algorithms or legacy `@NL` models.

## Registered cold r13 configuration

Only four configuration fields differ from r12:

- Fresh attempt identity `campaign_n23643_s003_r13`.
- `ac_numerics_policy=symbolic_adaptive_v1`.
- A 600-second first-period continuous-shunt allowance. Subsequent periods
  retain their existing limits. All phases remain clipped to the existing
  work deadline, leaving the original final-reserve/verification reserves.
- `final_verification_policy=complete_pipeline_only_v1`: a worker failure or
  incomplete/duplicate interval coverage is an explicit failed gate. Its
  checkpoint remains unverified; the controller does not spend the reserved
  evaluation budget scoring it. A complete pipeline still requires exhaustive
  independent and official checks. No verification requirement for a pass is
  removed.

Cold scheduling is unchanged. This attempt cannot reuse r12's checkpoint,
binary spools, commitment, dispatch or consumed latch. The 7,200-second global
cap, 2 GiB available-memory floor, 30 GiB disk floor, all 48 periods,
26,870 source contingencies per period and quality target remain unchanged.

## Tests and launch requirements

The new tests compare nonlinear constraint values, Jacobians and Lagrangian
Hessians from the two backends at three tiny source-model points (`1e-10`
comparison tolerance). They also confirm unchanged variable/constraint identity,
bounds and objective; reject incompatible/unknown settings; and force numerical
recovery to verify backend selection after optimizer replacement.

The final focused derivative/recovery test passed 49 Julia assertions,
including checks of the instantiated native evaluator. The Python
suite passed 166 tests, including exact r12-to-r13 configuration-difference
checks and verification-coverage rejection tests. The focused full tiny
three-period pipeline completed all AC periods and final reserves, and passed
independent and official checking: 9/9 contingencies, both official feasibility
flags one, objective agreement, objective 1732.1459693041525, maximum hard
residual `2.7755575615628914e-17`, and candidate SHA256
`252f9dc41b84934ce88b67152da75f2ee90320ccc91917c18e54c228a38c285f`.
The source evidence is `tmp/ac_numerics_development_zx1eucq_`. The later full gate
must repeat both tests and the pipeline with the final source inventory.

Before any full case: complete the entire fresh source-matched regression gate,
check its exact evidence/log/runtime/source hashes, archive the evidence,
commit/push the frozen implementation, and pass the read-only preflight. Only
then may the single registered cold r13 run start. This document is not a claim
that the gate or large-case run has completed.
