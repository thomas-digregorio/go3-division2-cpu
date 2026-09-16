# GO3 Division 2 CPU prototype

Source-audited, laptop-only development toward one public GO Competition
Challenge 3 Final Event, Division 2, 617-bus pilot.

## Status

The original authorized cold pilot ran at frozen commit `3ad6ef2` and stopped after
**197.398 seconds with NO_VERIFIED_INCUMBENT**. It exposed an independent
consumer-cost ordering bug, a fatal Windows live-status replacement conflict,
and a weak imbalance-penalty configuration in candidate scheduling. Its artifacts
and latch are retained unchanged. The user subsequently authorized **one replacement
pilot**, registered separately as `pilot_002`; see
[the correction and replacement registration](docs/REPLACEMENT_002.md).
No replacement result is claimed before that experiment and its checks finish.

See [the complete first-pilot failure report](docs/PILOT_001_RESULTS_20260916.md)
for timings, retained artifacts, initial-candidate penalties, matched published
results and proposed corrections. The frozen first-pilot revision remains available;
the new corrections do not rewrite its historical evidence or the official evaluator.

## Scope

- Registered `C3E4N00617D2`, scenario `002`: 48 one-hour intervals and 562
  source contingencies per interval. Matching public results allow switching;
  candidate topology/taps are fixed to source values as a disclosed heuristic.
- Actual GO3 multi-period formulation, not repeated GO2 snapshots.
- Open-source CPU solvers only. No commercial solvers or GPU execution.
- GO2 repository is a read-only reference; do not modify or delete its artifacts.
- All files, caches, environments and outputs must be outside OneDrive.
- Maintain at least 30 GiB of physical Windows free space.
- Tiny component tests precede one cold, 1,800-second end-to-end pilot.
- Freeze implementation, configuration, inputs and evaluator before that pilot.
- No supplied solved solution, competitor solution, warmup, automatic retry,
  pricing solve or additional case.
- Independent and official evaluation must finish inside the pilot deadline.

Large inputs, caches, environments and run artifacts are deliberately ignored.
The first complete solution must be retained for independent re-evaluation.

## Authoritative sources

- [Official dataset and results catalog](https://catalog.data.gov/dataset/arpa-e-grid-optimization-go-competition-challenge-3)
- [Official evaluator](https://github.com/GOCompetition/C3DataUtilities)
- [Official data model](https://github.com/Smart-DS/GO-3-data-model)
- [LANL benchmark](https://github.com/lanl-ansi/GOC3Benchmark.jl)

See [reuse audit](docs/REUSE_AUDIT.md),
[formulation and limitations](docs/FORMULATION_AND_LIMITATIONS.md),
[test evidence](docs/TESTS.md), and [reproduction notes](docs/REPRODUCING.md).
`manifests/` pins the exact input, upstream files, component-test code hashes
and same-scenario published records. Hard-feasible GO3 outputs can contain
penalized violations; no global GO3 optimality certificate is claimed.

No license is granted for newly authored code at this stage. Upstream components
retain their own licenses and attribution; see `THIRD_PARTY_NOTICES.md` as the
audit progresses. This project is not the proprietary implementation of an
original competition team.
