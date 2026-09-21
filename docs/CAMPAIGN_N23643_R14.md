# Cold 23,643-bus r14: initialization repaired, AC convergence still failed

**NO_VERIFIED_INCUMBENT.** The one registered cold attempt finished in
**3,468.022541 seconds (57 min 48.023 s)**. It completed scheduling, the 48
source reserve subproblems and the original scheduling-model audit. The first
AC hour exhausted its three registered phase allowances without passing the
unchanged `1e-8` residual screen. No AC hour passed; hours 2--48 were not run.

This was not an out-of-memory failure, the global two-hour timeout, or a proof
of model infeasibility. There is no verified GO3 objective, score or certified
full-model gap. The initialization defect was corrected and measured, but
the full-case convergence result did not improve over r13.

## Frozen identity and pre-run gate

- Case: C3E4N23643D2 scenario 003, 23,643 buses, 18,005 dispatchable devices,
  48 one-hour periods and 26,870 source contingencies per period.
- Input SHA256:
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Frozen implementation: `d295287eb815a168386a37a52a1e83f1ad1910d6`.
- Configuration: `config/campaign_n23643_s003_r14.json`, SHA256
  `a94c7c2f8eb0f2e606d236a881674db0ca76c1bd58b4bf550d5c91f964efab6c`.
- Run: `C3E4N23643D2_s003_campaign_n23643_s003_r14_20260921T102418Z`.
- Fresh component gate: 86 top-level stages, 168 Python tests, 16,723 Julia
  assertions; all 211 source fingerprints and 126 parent/nested stage-log
  hashes audited. Manifest SHA256:
  `261a6cc1400832655f053c14fdd980fbc62051488fe99e1804ce393bfe5b65f1`.
- The complete-initialization tiny pipeline passed all three hours, final
  reserves and independent/official verification of all 9/9 source
  contingency/hour pairs. Both official feasibility flags were one, with
  objective agreement. Tiny success did not certify this competition case.

The attempt remained CPU-only, FP64 and cold from source conditions. No
previous-attempt optimized point, matrix spool or run latch was reused.
Source constraints, PMIN, periods, contingencies, score target and tolerances
were unchanged. The total 7,200-second cap, 2,400-second evaluation reserve,
30-second finalization reserve, 2 GiB RAM floor and 30 GiB disk floor remained
active. No frozen code or configuration changed while the run was active.

## What the initialization measurements establish

The new policy populated all 643,822 primal values from this attempt's
schedule and existing network starts, including 78,294 cost blocks and
180,050 reserve values. Initialization took 6.466 seconds and performed no
optimization. All three actual native first iterates had complete identity
mappings and maximum relative movement from the supplied starts of about
`1e-8`. Source bounds were not relaxed.

| Native first iterate | Original unscaled residual | Meaning |
|---|---:|---|
| Continuous shunts | 14.3999998949 | Complete algebraic start, not AC-feasible |
| Rounded shunts | 0.5765127945 | Shunt fixings change between these phases |
| Fresh recovery | 0.002197770530 | Matches preceding final rounded residual |

The rounded phase ended at `0.0021977705298685812`; recovery began at
`0.002197770529861476`. This confirms that the new small interior pushes
preserved the preceding point's residual instead of recreating the large
restart jump seen in r13. Recovery supplied all 643,822 primal values and
cleared 1,697,950 dual-start attributes. No unverified dual start was used.
Start-domain projection counts were 20,722 for rounding and 311 for recovery;
these modify starts, not the source feasible set.

Every native solve confirmed FP64, the intended modern symbolic derivative
evaluator and adaptive barrier policy. There was no silent backend fallback.

## Timing and residuals

| Stage | Wall seconds | Outcome |
|---|---:|---|
| Cold builder process | 876.080 | Unsolved source model exported |
| Exact compaction process | 194.897 | Equivalence proof passed |
| Source reserve partition process | 122.338 | Complete source partition |
| Scheduling coordinator process | 708.629 | Construction, fixed-cost LP, 48 reserve LPs and audits |
| Scheduling total | 1,911.881 | Original scheduling model audit passed |
| First AC hour, all phases and overhead | 1,444.418 | Failed residual screen |
| End-to-end through serialization | **3,468.023** | **No verified incumbent** |

Rows overlap and must not all be summed. The original scheduling audit covers
19,323,456 variables and 20,211,928 rows, bounds, integrality and objective
agreement. Its maximum residual was `6.000000010719653e-10`. Its objective,
including source reserve recourse, was `-20572608194.137283`, identical to
r13's scheduling objective. This is not a final GO3 score. Construction
optimality or the fixed-commitment cost LP does not certify the original
economic MILP; its bound and gap remain null.

| AC phase | Configured cap (s) | Native algorithm wall (s) | Optimizer-reported time (s) | API wall (s) | Iterations | Audited maximum residual |
|---|---:|---:|---:|---:|---:|---:|
| Continuous shunts | 600 | 600.826 | 609.180 | 642.612 | 258 | 1.035325208e-2 |
| Rounded shunts | 240 | 240.090 | 248.780 | 248.781 | 93 | 2.197770530e-3 |
| Fresh recovery | 360 | 362.065 | 370.441 | 399.550 | 163 | 1.418553089e-2 |

All three returned `TIME_LIMIT` with `INFEASIBLE_POINT`. These describe the
returned iterates, not a mathematical infeasibility certificate. The API and
audit timers include work outside Ipopt's algorithm wall timer. The overall
deadline remained enforced and was not reached.

Independent model-residual audits took 18.547, 16.645 and 17.378 seconds.
Initial AC model construction took 46.785 seconds. The nested native
`PDSystemSolverTotal` wall times were 466.127, 164.756 and 276.292 seconds:
907.175 seconds, about 75% of the 1,202.981-second native algorithm total.
This is the recorded primal-dual linear-system block, not factorization-only
time, and it must not be added again to total solve time.

The logs contain repeated tiny-slack warnings and large dual residuals. The
guard never certified a stable feasible point. Those observations identify
remaining numerical instability but do not by themselves prove its cause.

| Outcome comparison | r13 | r14 |
|---|---:|---:|
| Total seconds | 3,488.520 | 3,468.023 |
| Final first-hour residual | 1.908807238e-5 | 1.418553089e-2 |
| Successful AC hours | 0/48 | 0/48 |
| Full-case verification | Not reached | Not reached |

The small runtime difference between single failed attempts is not a speedup
claim. Neither run solves the required problem; r14's final residual is worse.

## Resources, preserved evidence and completion status

- Peak controller-sampled process-tree RSS: **15.738262 GiB**.
- Minimum available host RAM among 2,741 native-process memory samples:
  **5.783150 GiB**, above the 2 GiB floor. This is a sampled minimum, not a
  continuously measured minimum across every stage.
- No memory, disk or global-deadline stop occurred. All owned solver processes
  were confirmed exited after completion.
- One attempted AC-hour record; **0/48 successful hours**. Final reserve
  reoptimization and complete independent/official verification were not
  reached. None of the required 1,289,760 complete-candidate contingency/hour
  checks is claimed as certified.
- `worker/checkpoints/candidate_ac_0001.json` remains **UNVERIFIED**. The
  controller skipped evaluation of an incomplete horizon and correctly
  reported `NO_VERIFIED_INCUMBENT`; the evaluation list is empty.
- The compact archive contains 522 copied files plus summary and retained-file
  manifest. Copy hashes and terminal identity were audited. The original
  1,520-file, 8,177,414,872-byte run remains local; **nothing was deleted**.
- Result SHA256:
  `b9e6d9546950c475cb33a02b9925844cb1e67512830f594d90b4915c1f4ec7ff`.

Evidence: [archived summary](../evidence/campaign/campaign_n23643_s003_r14/summary.json).
Implementation and component details: [r14 initialization](AC_INITIALIZATION_R14.md).
The consumed r14 latch is retained. Archival and report creation performed no
additional solve, official reevaluation or replacement run.

## Read-only first-hour checkpoint diagnostic

A later read-only calculation reread the immutable source and hash-matched
the retained failed checkpoint. It used the existing independent complex AC
branch-flow and startup/shutdown-trajectory routines, but did **not** run an
optimizer, the official evaluator or any contingency analysis. It examined
only interval one and is not an additional feasibility certificate.

- Largest active-power imbalance: `0.0018181311673477474` p.u.
  (`0.1818131167` MW), at `bus_02154`.
- Largest reactive-power imbalance: `0.01418553089493746` p.u.
  (`1.4185530895` MVAr), at `bus_02155`. This agrees, to roundoff, with
  the failed recovery phase's recorded maximum model residual. It identifies
  a physical reactive-balance mismatch in the exported point, rather than
  establishing the cause of the numerical failure.
- First-hour voltage-box, exact conditional PMIN/PMAX and simple reactive-box
  checks showed zero violation. These are only selected constraints; reserve,
  intertemporal and security feasibility are not certified by this diagnostic.
- The exported point also has source-soft base-case overloads, including
  `12.839730116898489` p.u. on `acl_12422`. No score or secure dispatch is
  inferred from this incomplete point.
- All 6,274 producers and 11,731 consumers are online in this checkpoint.
- Checkpoint SHA256:
  `0ee0b4eac5aa3239d74212f5c7ab43aec8a9e88496206750bccac827844dd852`.

This is the export-projected checkpoint, not a retained raw optimizer vector.
The other 47 hours were not evaluated. The data remain excluded from r15's
cold initialization. The report and exact diagnostic helper are archived in
[`evidence/diagnostics/r14_checkpoint_20260921`](../evidence/diagnostics/r14_checkpoint_20260921).
