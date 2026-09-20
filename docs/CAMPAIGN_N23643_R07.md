# Cold 23,643-bus attempt r07: preregistration

Status: component regression in progress; no r07 full-case run has started.

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
