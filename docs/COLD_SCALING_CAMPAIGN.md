# Cold Division 2 quality campaign

The user authorized iterative development on one selected scenario per network,
in this order: C3E4N02000D2, C3E4N04224D2, C3E4N06049D2, C3E4N06717D2,
C3E4N08316D2, C3E4N23643D2. They clarified the comparison reference is the
**sixth-best eligible competition score**, not the best or the top-six average.
This supersedes the old pilot-only authorization for these new registered attempts.
Both historical 617-bus pilot latches, solutions and reports remain unchanged.

## Acceptance and order

For each network, select the smallest numeric public Division 2 scenario before
inspecting our solve quality. Compare only the same scenario and switching
permission in the frozen official Final Event workbook. Exclude the ARPA-e
benchmark, inactive rows, infeasible rows and missing/nonfinite scores. Require
one unambiguous row per team. Retain the exact six rows, UUIDs and workbook hash.

For positive sixth-best score S6, the requested threshold is `score >= 0.90*S6`.
Also require a complete cold pipeline, within the registered deadline, independent
hard-feasibility and objective agreement, official `feas=1` and `phys_feas=1`, and
every source contingency at every interval checked. This score comparison is not
a proof of global optimality. GO3's permitted thermal/reserve penalties remain
reported; physical feasibility does not mean zero overload penalties.

Do not advance to the next network until the preceding network's result and
completion hashes and quality gate pass. Every new attempt is registered
separately and consumes its own permanent one-run latch. No silent retry and no
repetition of a successful attempt. Changes are tested on tiny fixtures and frozen
and pushed before the next full cold attempt.

## Completed networks

| Network | Scenario | Accepted numerical commit | Verified score | Sixth-best published score | End-to-end seconds | Exhaustive checks | Target |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| C3E4N02000D2 | 005 | 2e16d83 | 755,301,043.857519 | 754,720,348.826734 | 2,960.691 | 132,288 / 132,288 | PASS |
| C3E4N04224D2 | 002 | da1d7ab | 493,989,736.571029 | 467,272,744.768504 | 2,477.004 | 111,024 / 111,024 | PASS |
| C3E4N06049D2 | 003 | cfe7ea0 | 606,322,317.416927 | 597,463,992.571312 | 6,277.024 | 187,296 / 187,296 | PASS |

All completed within the registered 7,200-second end-to-end cap with official
hard/physical feasibility and independent verification. These are separately
frozen development milestones, **not** results from one identical final revision.
No successful scenario is rerun automatically. Detailed failures, numerical
warnings, penalties and attribution are recorded in the per-network reports.

## Cold and source-faithful execution

Every attempt starts a fresh process from the immutable raw input, its source
initial conditions, and solver defaults. No earlier run, other scenario, provided
POP solution, competitor solution, primal, basis or dual is a starting point.
Within-run scheduling outputs can feed that run's AC stage. Inputs, source PMIN,
costs, constraints, official evaluator and acceptance tolerances stay unchanged.
Unsupported features must be implemented and tested, never dropped to get a pass.
Open-source CPU solvers only; no GPU or commercial solver work is included.

The first 2,000-bus attempt is scenario 005. Its source digest is
`a0036576821f955e79fcf260b66fefbc9ab31127a48a788d0da84b0d8acd81bf`.
Only its raw JSON was retrieved by HTTP ranges (3,580,587 transferred bytes,
31,483,855 decompressed bytes), not the full archive or solved POP.
All selected-case features pass the current implementation's required-feature
gate. It has 48 hours, 544 producers, 1,350 consumers and 2,756 outages per hour.

The user subsequently authorized **up to two hours per attempt**, matching the
Division 2 allowance. First attempt: preserve the existing numerical method to
establish scaling; allocate up to 900 s to the cold scheduling MILP and 45 s per
AC subsolve, under one 7,200 s end-to-end limit. Reserve 600 s for exhaustive verification
and 30 s for finalization. Checkpoint each four intervals to avoid needless
full-horizon copies. Full verification is never replaced with a sample.

The first attempt's scheduling root relaxation exhausted its internal budget
without a feasible integer point. The separately registered r02 separates
candidate commitment scheduling from subsequent full reserve allocation and
allows scheduling 1,800 seconds within the same total limit. See the
[measured failure and correction](C3E4N02000_CAMPAIGN.md). This modifies candidate
generation, never official constraints, penalties, tolerances or acceptance.

Use the existing read-only Python interpreter at
`C:/Users/thoma/Documents/goc2-ac-score-check/evaluator-venv/Scripts/python.exe`,
which matches the historical 617-bus Python 3.12.14, NumPy 1.26.4 and SciPy 1.13.1
environment. Project-local pydantic/psutil overlays and caches remain local.
The preflight now verifies that Python and numerical dependency identities equal
the runtime used by the completed component gate. The shell's default Anaconda
Python 3.13 is not the campaign runtime.

## Storage and artifacts

All writes stay in this local repository, outside OneDrive. Keep >=30 GiB
physical Windows free space. Initially about 206 GiB is free, so no deletion is
needed. Preserve raw sources, code, frozen manifests, complete best/first verified
solutions, certificates and compact per-attempt evidence. Only inactive,
reproducible scratch or superseded checkpoints may later be pruned after a
verified evidence archive. Never delete active runs, historical latches or GO2.

## Work sequence

1. Audit and register the 2,000-bus case and sixth-place target.
2. Extend the runner's explicit case/authorization handling; tiny tests first.
3. Freeze and push, run once cold, evaluate and retain evidence.
4. If needed, diagnose the measured loss/feasibility/runtime bottleneck and improve
   the algorithm. Freeze and run the revised attempt cold, without imported starts.
5. On verified target attainment, repeat this process for the next requested size.
6. Report all attempts, final per-network scores/shortfalls, timings, verification
   and remaining penalties, without claiming official competition placement.

## Physically feasible incumbent preference after r04

A read-only audit during r04 found that the historical `Incumbent` class orders
all hard-verified points by objective, even when the campaign additionally needs
`phys_feas=1`. A higher-scoring hard-only candidate could therefore mask a lower-
scoring physical candidate. The quality gate would correctly reject the retained
hard-only point, but could miss an eligible result already produced by the run.
This is a retention edge case, not a change to optimization or official scoring.

`go3cpu/selection.py` prepares a pure ordering helper: after checking complete,
exhaustive hard verification and objective agreement, prefer a physical point
over a hard-only point, then maximize objective within each class. Ties retain
the first point. Before a physical point exists, the best hard-only point remains
useful failure evidence but never becomes campaign success. Historical non-
campaign pilots retain objective-only ordering. Six fixture-only unit tests pass.

The helper was **not imported by the frozen r04 controller**. That completed run
passed with a physical final point and is not repeated or retrospectively changed.
After it finished, the helper was integrated into `Incumbent` and enabled only
for quality-campaign callers. Fixture tests exercise actual hash-checked file
retention, a lower-scoring physical point replacing a hard-only point, exhaustive
coverage rejection, ties, subsequent improvements, and unchanged historical
ordering. Previously retained files remain immutable. The complete matched-runtime
component gate must be regenerated before a new registered attempt. No saved
solver point or solver call is used by the retention tests.
