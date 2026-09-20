# Cold 23,643-bus attempt r07: preregistration

Status: one cold r07 attempt completed with `NO_VERIFIED_INCUMBENT`; the host
memory guard stopped the first native root-LP phase. No additional run followed.

## Full-case outcome

Frozen implementation: `2b6c827a95133691c83b29412fb94cdd36bb253a`.
Configuration SHA256:
`0476610da30ea8dc0873018fe84a42fa257f71b6265ee26829d56939d5696d96`.
Run: `C3E4N23643D2_s003_campaign_n23643_s003_r07_20260920T224331Z`.
End-to-end elapsed through result serialization: **1,591.526548 seconds
(26 minutes 31.527 seconds)**. It was neither a time-limit stop nor a proof of
infeasibility. The host-available-memory floor triggered at **1.962059 GiB**,
below the unchanged 2 GiB threshold. All owned Julia processes exited.

| Stage | Measured seconds | Outcome |
|---|---:|---|
| Cold builder process, including import/JIT, raw loading and export | 877.596 | Complete, zero solve calls |
| Exact compaction process | 194.419 | Complete; all 20,211,928 rows and 19,323,456 columns checked |
| Source reserve partition process | 122.183 | Complete; partition proof passed |
| Native coordinator, through last memory sample | 393.187 | Interrupted by host-memory floor |
| End-to-end, including cleanup and serialization | 1,591.527 | No verified incumbent |

The native-stage entry is the observed elapsed time at the last retained memory
sample, not a completed solver-call timing. The following native timing markers
are nested within that stage and must not be added to the table above:

- Presolve completed before setup initialization at **220.862947 seconds**.
- MIP setup finished at **224.843437 seconds**: approximately **3.980490 seconds**
  after initialization. The optional objective-clique guard skipped grouping
  **640,839** nonzero-cost binary columns (registered cap 4,096).
- The log then entered feasibility-jump search, root-node evaluation, an
  analytic-centre calculation, and the first LP relaxation. The first LP log
  timestamp was **343.3 seconds**. There was no completed LP result before stop.
- The resource-floor event was approximately **385.697 seconds** after the
  Python-observed native solve-begin marker, within the 600-second call budget.

The ordinary end-to-end sampler recorded peak process-tree RSS **18.803185 GiB**;
the denser native-stage sampler captured **18.993607 GiB**. These are sampled
resident-memory measurements, not exact peak allocations or the same sampling
instants. Do not conflate them with committed/private memory.

The setup phase that r06 did not finish was passed in this run. However, the
local compiler/library build also differs, so this is not a controlled attribution
of every timing difference to the cap. The code patch did not change source
coefficients, integer domains, feasibility tolerances or floating-point precision.

No feasible scheduling incumbent was returned or independently audited. No AC
interval refinement or exhaustive final contingency verification started. There
is no verified objective, finite incumbent gap, dispatch, or successful score.
The native log's preliminary `BestBound` of 933,919,174.5322 is retained as a log
observation, not presented as an independently verified final GO3 certificate.

### Remaining memory question

The pinned HiGHS source's `evaluateRootNode` starts an analytic-centre task before
loading/solving the ordinary root LP. `startAnalyticCenterComputation` constructs
a separate `Highs` object, copies the presolved LP, clears its objective and
integrality, and runs IPX in this build. This is a plausible additional memory
consumer at the observed stop point. The logs do not attribute memory by routine
or prove that this task alone caused the stop; the root LP itself may still exceed
the available memory. No analytic-centre change or further experiment was made.

### Retained evidence

`evidence/campaign/campaign_n23643_s003_r07` retains 142 copied compact evidence
files plus the summary and retained-file inventory. Copies were hash-checked.
The original run's 7,272,523,455 bytes, including binary spools, remain local.
No source, prior solution, or run data was deleted. This attempt consumed its own
authorization latch; it must not be silently relaunched.

The latest user request authorizes another run after bug fixes and allows
retaining floating-point precision. This attempt keeps FP64 and the complete
existing GO3 scenario 003 contract. It is not a lower-precision approximation.

## Changes relative to r06

1. The previously committed native-call watchdog enforces the requested native
   solve budget externally, even if HiGHS remains in a setup routine without
   polling its internal time limit. It stops only the owned child process tree
   and records the interrupted stage. It does not fabricate an incumbent.
2. A separately built, hash-bound HiGHS library limits optional objective-clique
   grouping to 4,096 nonzero-cost binary variables, and logs setup transitions.
   See `NATIVE_HIGHS_SETUP_GUARD.md` for the mathematical scope and build details.
3. The full regression manifest now requires the same covered source inventory
   at the beginning and end of the suite. It explicitly includes guarded native
   tests, the guarded Benders integration, and their test counts.

Only the pilot ID and two native-backend fields differ between the r06 and r07
configuration files. The local library differs from the installed JLL build,
so any timing change cannot be attributed exclusively to the clique guard.

## Unchanged acceptance and resource boundaries

- Raw input SHA256:
  `9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
- Cold start; all 48 intervals and all 26,870 source contingencies per interval.
- Exact source scheduling audit, original AC/reserve constraints, source costs
  and PMIN, independent and official exhaustive verification.
- 7,200-second end-to-end limit, 2 GiB minimum host-available memory and 30 GiB
  minimum physical Windows disk headroom.
- Scheduling master round 600 seconds; scheduling phase 1,500 seconds;
  hourly recourse 30 seconds; evaluation reserve 2,400 seconds.
- The previously authorized fifth-positive-score fallback applies because the
  sixth published eligible score is zero. Minimum score: 318,424,338.2163591.
- A scheduling incumbent without the requested gap certificate is not described
  as optimal. Full physical, coverage, score and elapsed-time gates still apply.

## Evidence before the full regression

The local native solver passed 24 tiny solves checked against enumerated optima
and all three infeasible fixtures. The guarded tiny integration passed 11 stages,
including 147 Python tests and all original scheduling audits. Its final candidate
passed independent and official verification: three intervals, nine required and
completed contingency checks, both official feasibility flags 1, hard residual
0, objective agreement within 5.23e-12, and maximum P/Q imbalance below 2.31e-9 p.u.
All 16 designated native workers loaded the registered DLL. The later six-test
policy check also passed, including the r07/r06 configuration-difference test.

The byte-verified focused archive contains 421 files / 704,838 bytes under
`evidence/components/native_setup_guard_20260920`. It records the source revision
tested at that time; it is not a substitute for the final fresh regression gate.

The r06 setup stall's exact routine remains unproven. The cap addresses a plausible
hotspot; the new stage timing will identify where the next attempt spends time.
No full-case speedup or successful 23,643-bus solution is claimed at preregistration.

## Completed full regression gate

The fresh suite in `tmp/pilot002_component_gate_314vmtz9` completed all 70 stages
with 148 Python tests and 14,974 Julia assertions passing. Covered sources were
identical at the beginning and end of the suite. No full-case solve was performed
by this gate. Stock and guarded Benders pipelines passed all three AC intervals
and all nine required contingency checks; both official feasibility flags were
1 and their final candidate SHA256 values matched exactly. All 16 guarded native
workers had the registered library identity.

The complete component manifest and all JSON/log evidence from the main suite
and both decomposition integrations are retained under the `full_gate` subfolder
of `evidence/components/native_setup_guard_20260920`. Every copied file was
individually hash-checked against its original. No original files were removed.
