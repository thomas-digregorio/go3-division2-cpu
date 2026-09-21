# r12: guarded reserve extraction and within-attempt AC handoff

r11 completed and independently audited the entire source scheduling matrix,
including all 48 reserve recourse LPs, but failed before any AC interval. An
additional initial-reserve LP returned zero results; the pinned upstream wrapper
unconditionally requested `VariablePrimal(1)`. Its termination status was not
retained, so r11 does **not** establish whether that LP timed out, was infeasible,
or encountered a different solver failure. Its configured allowance was two
seconds. See `CAMPAIGN_N23643_R11.md` for the immutable evidence.

## Implementation

The bounded-lifetime wrapper now invokes the exact pinned upstream reserve-model
constructor, then the same solver and projection functions. It checks result
count and primal status before querying any values. A complete finite point must
also pass the original interval LP rows and bounds at the existing `1e-8`
residual tolerance. A feasible time-limited point may be used, without claiming
optimality; an infeasibility certificate is not a dispatch. All ten reserve
products and source constraints remain unchanged, in FP64.

Every interval records termination, primal and raw solver statuses, result count,
objective only when available, residual, extraction/projection flags, and model
release. Failed intervals emit their diagnostics before raising a specific
failure; later intervals are not run and no unchecked awards are exported.
The original upstream checkout is untouched. Successful numeric awards are
compared with the upstream implementation on tiny fixtures.

r12 uses the existing `use_joint_schedule_unverified` initialization policy.
It transfers only the current cold attempt's already constructed scheduling
awards, checking identity, all ten products, horizon length and finiteness. These
are an **unverified AC starting candidate**, not a feasible GO3 result: candidate
dispatch projection may change their compatibility. The audit explicitly says
no external solution was read, no extra initial optimization was done, and final
reserve optimization and full-case checking remain required. The default for
older registrations remains initial reallocation.

AC still jointly optimizes source reserves. After AC and audited export, all
final per-interval reserve LPs are solved using the guarded bounded-lifetime path.
Independent and official complete-horizon verification, objective agreement,
all 1,289,760 source contingency checks and the unchanged score gate remain
mandatory. There is no relaxed tolerance, omitted check or global-optimality
claim.

## Registered r12 differences from r11

Only four JSON fields differ: a fresh single-use pilot identity, the explicit
initial reserve handoff policy, final reserve per-interval cap `2 -> 30` seconds,
and end-of-work reserve allowance `90 -> 600` seconds. The larger finalization
reservation leaves less time for AC and is not a guarantee every LP can use its
maximum allowance. All calls remain clipped to the absolute work deadline; the
controller retains the 7,200-second end-to-end cap, 2,400-second final verification
reserve, 30-second serialization reserve, 2 GiB available-RAM floor and 30 GiB
free-disk floor. Scheduling implementation and time limits are unchanged.

Each replacement rebuilds from the same raw source. Prior model files, optimized
points and consumed latches are never reused. No previous attempt is relabeled
successful. The separately recorded positive master-only objective from r11 is
not a complete scheduling objective or final score.

## Pre-run requirements

Tiny tests distinguish no-result time limits, infeasibility and solver errors;
they reject invalid points even when a mock solver calls them feasible. They
also cover complete within-attempt handoff, nonfinite/missing awards, identical
upstream numeric results, and release of the sole live interval model. A tiny
handoff/AC/final-reserve pipeline must pass independent and official exhaustive
checks. The entire source-matched component gate must pass before freezing and
launching the one newly registered full attempt. Tiny tests do not prove large
case runtime, memory, feasibility or economic quality.

## Focused development checks

`tmp/reserve_handoff_development_ctk_m6r0` passed all 162 Python tests and
171 reserve-storage Julia assertions. The new tiny handoff pipeline then
completed all three AC intervals and final reserve LPs. Independent and official
verification passed all 9/9 contingency checks, both official feasibility flags
were one, and objective agreement passed. The final objective was
1732.1459647319407; candidate SHA256
`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`
matches the previous tiny baseline byte for byte. This focused development check
does not replace the mandatory fresh full regression gate.
