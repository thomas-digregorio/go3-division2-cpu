# GO2 numerical reuse audit (before solver implementation)

Read-only source: `C:/Users/thoma/Documents/gravityx-go2-cpp`, HEAD
`b5433e9d8a8fd4a22ab7df33e5c78198ad6a1f7d`. Its retained V34 campaign
identifies algorithm `3b335872647296c2d0e2c8ae5acbe4359ae72f0a` (not
`6f0afaa`), executable SHA256
`353439cb4b29a27b0a75cf4a006a894c65adf7bf5d0f06f8bd193bd21ab93efa`.
The recorded campaign has 37/37 passes and 44,517 checked GO2 contingencies.
These are prior GO2 results, not GO3 validation or evidence of global optimality.
No GO2 benchmark was rerun for this audit.

The source was inspected alongside
`docs/V34_ALL_SCENARIOS_RESULTS_20260916.md` and its evidence manifest.
In particular, `run_validated_source_base_json` in `src/main.cpp` takes source
commitment directly. That is not an adequate GO3 multi-period UC search.

| Component and source | Decision | Reason | Required regression tests |
|---|---|---|---|
| AC admittance/branch calculations: `src/case_data.cpp`, `src/fast_power_flow.cpp`, `src/validation.cpp` | Adapt technique; replace model binding | Complex admittance algebra is reusable; source transformer/shunt domains differ | Both-end flows, losses, taps, phase shifts, shunt signs versus independent complex arithmetic |
| Sparse Jacobian/Hessian and factorization: `src/fast_power_flow.cpp`, `src/sparse_ac_economic.cpp` | Defer native port; use GO3 JuMP/Ipopt derivatives | Current C++ sparsity/index maps are bound to GO2 state; exact-Hessian PWL guard deliberately rejects unsupported curves | Finite-difference derivatives on tiny GO3 fixture; reject unsupported curve semantics |
| Ipopt/scaling: `src/sparse_ac_economic.cpp` | Adapt candidate/validation policy | Solver success is not physical validation; GO2 penalty magnitudes and objective scaling are not GO3 data | Hard-bound residuals, source cost signs, failed optimization cannot replace a valid incumbent |
| HiGHS/linearized seed: `src/linearized_ac_seed.cpp`, `src/active_feasibility_repair.cpp` | Replace with GO3 whole-horizon scheduling | One-interval GO2 linearizations omit minimum times, trajectories, reserve coupling | Exact conditional PMIN, initial duration, unequal-time ramps, off/on transitions |
| Incumbent retention: `src/algorithm.cpp`, `src/main.cpp` | Adapt policy, new implementation | Preserve atomic verified snapshots; warm starts must match the model | Reject nonfinite/partial candidates and retain the last valid solution |
| Local dispatch and shunts: `src/local_bus_dispatch.cpp` | Replace | GO2 corrective ramps and shunt representation cannot define GO3 controls | Integer shunt bounds and round-and-resolve; full time-coupling recheck |
| Independent validation: `src/validation.cpp` | Replace equations; adapt identity/error reporting | GO2 source ramp windows, slack caps and 1e-5 tolerance are not GO3 rules | Official 1e-8 hard tolerance, all UID/interval coverage, negative bounds/ramp/reserve tests |
| Worker scheduling/deadlines: `scripts/run_experiment.py` | Adapt absolute-deadline pattern, replace GO2 worker graph | GO3 contingencies use specified linear security physics, not independent corrective AC solves | Cancellation, serialization reserve, no orphan task processes, incomplete is not PASS |
| Logging/provenance/storage: `scripts/run_reliability_suite.py`, `scripts/run_experiment.py` | Adapt policy, new small implementation | Hashes, immutable inputs and explicit physical Windows free space are reusable safeguards | Hash tampering, OneDrive paths, physical free-space floor and pending writes |
| RAW/JSON/CON parser, solution writer, generator-outage logic, GO2 evaluator | Replace entirely | Different input/output contract, devices, objective and contingency equations | Pinned GO3 schema, exact output round trip and unchanged official evaluator |

No GO2 numerical source has been copied into this project yet. Existing Julia
runtime and package files outside OneDrive may be used read-only; the new project
must put all new environment, compiled cache and scratch files under its own
directory. No GO2 environment or run tree is copied.

## Initial architecture decision

Use audited LANL GO3 model functions for candidate construction instead of
transplanting C++ GO2 model classes. Supply **HiGHS** and **Ipopt/MUMPS** explicitly;
never invoke a CLI that defaults to a commercial solver. Add a project-owned
controller, complete GO3 validation, source identity/hashes and a one-pilot latch.
The approximate scheduling bound is labelled a subproblem bound only.

No successful implementation is claimed by this audit. Official source and tiny
fixture gates remain prerequisites to any full experiment.
