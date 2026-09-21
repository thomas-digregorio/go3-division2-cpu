# Ordinary root-LP progress and measured master allowance

The 23,643-bus r08 attempt reached its 600-second native-call deadline rather
than the memory floor. It had spent 334.694 seconds in presolve, setup,
heuristics and root loading; only about 265 seconds remained for its first
ordinary LP. That LP did not return, and upstream suppresses its progress log.
The outer display's earlier `LpIters=0` does not measure work inside the LP.
See `CAMPAIGN_N23643_R08.md` for the preserved outcome and limits of attribution.

## Logging-only native change

The separately built `root_progress_guard_v1` library adds
`mip_root_lp_logging`, default **false**, on top of the unchanged r08 patch.
When explicitly true for the top-level first-root LP:

- Forward parent output/console and developer-log settings to the inner LP.
- If the parent has a file log, use the separate `<parent>.root_lp.log` path.
  Never share a file handle or truncate the parent log.
- Leave `highs_debug_level` unchanged; enabling debug checks merely to obtain
  logging would add substantial unrepresentative work.
- After the first-root solve returns, close the temporary log, restore prior
  inner logging settings, and retain upstream's disabled subsequent output.

No source row, variable, bound, cost, tolerance, solver algorithm, iteration
limit, numeric precision or branching rule changes. Logging itself has some
I/O overhead and is not claimed to accelerate the solve. The ordinary root LP
and optional memory controls remain as in r08. No GPU work is introduced.

The cumulative patch is `patches/highs-1.15.1-root-progress-guard.patch`, against
the same pinned HiGHS commit `04024d701f79feb8e2f18bc3df0dffc04ef05088`.
Source, build and child-only depot are respectively
`environments/highs-root-progress-source-04024d701f`,
`environments/highs-root-progress-build`, and
`environments/highs-root-progress-depot`. The build manifest hashes the DLL,
executable, support DLL, patch and artifact override. Compiler/flags remain the
same as r08. The installed JLL and both earlier custom builds remain unmodified.
The code checks exact library identity and sets/reads back native options before
each designated master. Stock AC refinement is unchanged.

## Tiny checks and full gate

Initial direct native tests passed 985 assertions: 32 feasible solves covering
logging on/off, analytic-center on/off, and root-only presolve on/off, plus four
infeasible fixtures and API/scope tests. All feasible optima/bounds match exhaustive
enumeration. Enabled cases produced ordinary LP iteration and final-status logs
with debug level zero; disabled cases produced no additional file. The complete
source-matched gate must also pass before any full-case launch. Its new backend
pipeline checks original scheduling feasibility, cut/start handling, audited
native identities/options, and independent/official tiny AC verification.

An initial Python registration check caught extra descriptive metadata inside
the exact attempt-identity dictionary. The description was moved to a separate
authorization-context record; identity validation remains unchanged and strict.
No full-case latch was consumed by component tests.

## Registered r09 experiment

Only four config fields differ from r08: new pilot ID, new hashed logging
backend, explicit root-LP logging enabled, and master-call cap **1100** instead
of **600** seconds. The cap remains bounded by the remaining 1500-second
scheduling-stage allowance, recourse/finalization reserves and global work
deadline. No budget is enlarged during an active run.

The complete original FP64 48-period model, exact PMIN, source penalties,
26,870 contingencies per period, score target, independent/official verification,
7200-second end-to-end maximum, 2400-second final verification reserve,
2 GiB available-RAM floor and 30 GiB disk floor remain unchanged. A bounded
schedule can proceed only after a full original-model primal audit; it must not
be mislabeled as having a certified MIP gap. Full-case success still requires
every final physical, coverage, quality and timing gate.

More time may still be insufficient, or memory may grow later. This is an
observable, preregistered next attempt, not a promise of a feasible result. r08
remains failed and immutable; r09 needs its own clean pushed freeze and unused
latch.

## Completed full regression gate

`tmp/pilot002_component_gate_tgmkaley` completed successfully on 2026-09-20:
**76 stages, 155 Python tests, and 16,498 Julia assertions**. All stages returned
zero. The final manifest names this exact evidence directory, records no
competition-case runs, and its runtime and complete source inventory match the
current revision. Summed stage wall time was 2404.768 seconds (setup, not a
competition benchmark). All owned test processes exited.

All four stock/setup-guard/root-memory/root-progress decomposition pipelines
passed. The new pipeline is `tmp/reserve_loop_components_n7l3fw2y`; it checked
16 native worker identities and eight master option records. Its final tiny
candidate passed independent and official verification with all 9/9 contingency
checks and both official feasibility flags equal to 1. Objective:
1732.1459647319407. Candidate SHA256:
`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`,
identical to the earlier tiny baseline.

The complete evidence directory, all four nested integrations and final manifest
were copied to `evidence/components/native_root_progress_20260920` and every
copied file was SHA256-compared against its original. The archive summary
records counts and per-tree inventory hashes. Original evidence and prior native
builds remain intact; nothing was deleted. The completed manifest SHA256 is
`41fbc3ad276df9f7a79d40bf59fc61dbb9eec5f6d4507f0ef122543d575f04d7`.

This qualifies r09 for the normal clean/pushed preflight. It is not evidence of
a successful 23,643-bus solution or of adequate memory for the full root LP.
