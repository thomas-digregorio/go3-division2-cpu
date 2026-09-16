# GO3 Division 2 CPU prototype

Source-audited, laptop-only development toward one public GO Competition
Challenge 3 Final Event, Division 2, 617-bus pilot.

## Status

Source audit and implementation in progress. **No full experiment has run.**
This is not a claim of a working or competition-certified GO3 solver.

## Scope

- One deterministically selected scenario; prefer published no-switching results.
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

Exact revisions, hashes, source compatibility, limitations and reuse decisions
will be recorded in `docs/` and `manifests/` before a pilot is permitted.

No license is granted for newly authored code at this stage. Upstream components
retain their own licenses and attribution; see `THIRD_PARTY_NOTICES.md` as the
audit progresses. This project is not the proprietary implementation of an
original competition team.
