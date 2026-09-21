# r15: exact reserve zero-domain reduction before AC optimization

Status at the pre-run freeze: implementation, focused checks and the complete
source-matched gate passed. One separately registered cold 23,643-bus attempt
is still required. This is not a claim that the large case now converges or
passes its score target.

## Measured motivation

[r14](CAMPAIGN_N23643_R14.md) finished within RAM and time limits, but all three
first-hour AC phases failed the `1e-8` original-model residual check. Complete
primal initialization and preserved recovery starts were confirmed. The logs
still contained tiny-slack warnings and large dual residuals. Those warnings
alone do not establish a cause.

A separate **no-optimization structural audit** loaded only the immutable raw
case and built its first-period reserve algebra with an all-online pattern.
It did not read a saved optimized point or solve the network. The all-online
pattern is the one selected by r14's scheduling constructor; the audit is not
itself proof of a feasible schedule or network operating point.

- Source SHA256:
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- 18,005 source devices and 180,050 reserve auxiliaries.
- 24,279 additional reserve auxiliaries provably equal to zero.
- 72,020 satisfied reserve-related constant affine rows after propagation.
- The implemented reduction replayed all proofs and matched the independently
  computed structural counts. This reserve-only diagnostic took 1.690 seconds
  in the reduction function; it is not a full AC timing forecast.

The source audit evidence is `tmp/reserve_zero_audit_jwhzsexf`. Its optimizer
call count is zero. The original full-case run remains untouched.

## Mathematical equivalence, not relaxed feasibility

For example, the source reserve constraints for an online device can imply

```
x >= 0, y >= 0, x + y <= 0  =>  x = y = 0.
```

Explicit zero fixings expose that implication to the numerical solver. A
resulting constant row `0 <= 0` carries no further restriction and can be left
out of the solver representation. The implication holds exactly; no epsilon
threshold, approximate redundancy test or rounded source coefficient is used.

Ipopt handles equal variable bounds as fixed variables. See its
[TNLP adapter documentation](https://coin-or.github.io/Ipopt/classIpopt_1_1TNLPAdapter.html)
and [fixed-variable options](https://coin-or.github.io/Ipopt/OPTIONS.html#OPT_fixed_variable_treatment).
The hypothesis is that explicitly resolving these zero-interior reserve
domains will reduce degeneracy and unnecessary barrier work. Improvement on
the full AC model remains an experiment, not a conclusion from this audit.

## Implementation and retained invariants

Opt-in `ac_zero_reserve_policy = exact_zero_reserve_domains_v1`:

1. Build the existing full reserve-aware AC model without changing raw inputs.
2. Record exact original domains, including zero lower/upper-bound pairs.
3. Consider only reserve auxiliaries for new fixings. Infer zero only from an
   exact zero right-hand side and a nonnegative sum after already-proven zeros
   are substituted. Replay each proof in order using original domains, so
   cyclic arguments cannot manufacture fixings.
4. Remove only satisfied constant affine rows that reference reserve
   auxiliaries. Keep network-reporting rows and every inconsistent constant
   row. Do not delete variable identities or alter dispatch, PMIN, voltages,
   flows, nonlinear equations, source costs or the objective.
5. Retain removed constraint objects and original changed domains in memory.
   Every local residual audit checks those original rows and domains as well
   as the active solver model, at the unchanged `1e-8` acceptance threshold.
6. Preserve current-attempt initialization, eligible mapped dual transfers,
   rounded-shunt repair and fresh numerical recovery. The reduction occurs
   before optimizer attachment; no additional structural change is made
   inside a numerical call.
7. Continue to require all 48 AC periods, final original reserve optimization,
   independent and official exhaustive checking of all 1,289,760 source
   contingency/hour pairs, both feasibility flags, objective agreement and
   the existing score target within the 7,200-second deadline.

The previous `off` path remains available. Relative to r14, r15 changes only
the attempt ID and this new policy. FP64, HiGHS scheduling, Ipopt settings,
phase budgets, source constraints and costs, cold-start rules, safety floors
and quality/verification requirements are unchanged. The reduction changes
the numerical representation, not the source feasible set.

## Component coverage

The dedicated tiny tests cover exact propagation, original-row residual
checking, corrupted proof order, circular implications, nonzero right-hand
sides as small as `1e-12`, negative variable domains, both inequality signs,
equalities, signed zero, exact lower/upper-bound fixings, inconsistent rows,
unchanged named network-reporting rows and non-reserve dispatch bounds.

Reserve LP tests compare objective values and cross-check solutions against
both the original and reduced formulations for all four two-device commitment
combinations. A forced iteration-limited AC example checks rounded repair and
fresh recovery, the intended FP64 derivative backend and original residuals.
The integrated three-hour DC-device fixture must additionally pass independent
and official verification of all nine source contingency/hour pairs, original
final reserve allocation and the within-run start/dual mapping checks.

No full-case attempt is authorized by a focused test alone. A new complete
source-matched regression manifest, immutable evidence archive, frozen pushed
revision and preflight are required before consuming the r15 latch.

## Final focused evidence

`tmp/focused_ac_zero_reserves_ap77mpq_` passed 78 dedicated Julia assertions,
all 169 Python tests, the three-hour complete pipeline and independent/official
verification of all 9/9 source contingency/hour pairs. All three intervals
retained eligible complete dual transfers. Objective: `1732.1459693041531`;
maximum P/Q imbalance: `1.4433e-15` / `1.2036e-14` p.u.; both official
feasibility flags one, with independent objective agreement. Candidate SHA256:
`2762b292c78cb7e9c934d7b066ead73344f672e30998413aec1082d28cac082f`.

The no-solve structural source audit and this focused evidence are archived
under `evidence/components/ac_zero_reserves_focused_20260921`. Those focused
checks alone did not authorize the full case; the complete gate is recorded
below. A verified 23k full-case result remains required.

## Completed source-matched regression gate

The single complete regression session finished successfully with exact
evidence directory `tmp/pilot002_component_gate_iukqiizv`. It was not restarted
after observation interruptions. The older r14 manifest was not used as proof.

| Gate | Verified result |
|---|---:|
| Top-level stages | 89/89 passed |
| Python tests | 169 passed |
| Julia assertions | 16,801 passed |
| Covered source-file fingerprints | 215 matched |
| Top-level and nested stage-log hashes | 129 matched |
| Nested decomposition integrations | 5/5 complete, eight stages each |
| Full-case optimization runs performed by this gate | 0 |

The integrated exact-zero pipeline passed all three AC intervals, final
original reserve allocation, original removed-row audits and all 9/9
independent/official contingency-hour checks. Both official feasibility flags
are one, and independent objective agreement passed. Its objective, maximum
residuals and candidate SHA256 match the final focused evidence above. Three
eligible complete dual transfers were verified.

Current component manifest SHA256:
`bcba56b0d5ac2dabfbdbad2062708ac4a8eade9b763d83b254d9d99cd390a603`.
The new complete archive is
[`evidence/components/ac_zero_reserves_20260921`](../evidence/components/ac_zero_reserves_20260921).
It contains 5,344 files: the main gate, five nested integrations, final focused
development evidence, manifest and archive summary. Every copied file was
hash-compared with its retained original, and all 5,344 staged Git blobs were
checked against the archived working bytes. No evidence or old run was deleted.

The registered r15 configuration SHA256 is
`3461ca1c30ce434f8a274624377c74a2a30b87b973c21a0d445378113c12338f`.
A semantic comparison with r14 confirmed only the attempt ID and the new
exact-zero policy differ. Preflight must still check the pushed frozen commit,
clean worktree, unused latch, current source/runtime identity and available
RAM/disk before the single cold full-case attempt starts. Component success
does not substitute for any of the 48-hour, exhaustive, score or time gates.
