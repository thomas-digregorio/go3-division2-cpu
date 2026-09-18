# C3E4N06717D2 scenario 002: cold quality campaign

## Registration before the first attempt

Selected scenario **002**, the smallest numeric public Division 2 scenario,
before inspecting our solve quality. The archive contains 18 raw D2 scenarios:
002, 004, 005, 008, 010, 011, 014, 016, 017, 020, 026, 032, 038, 044, 050, 056,
062, and 068. Only the selected raw JSON was extracted. No provided POP solution
or earlier optimized point was retrieved or used.

- Source archive: <https://data.openei.org/files/5997/C3E4N06717_20231002.zip>
- Exact entry: `D2/C3E4N06717D2/scenario_002.json`.
- Archive ETag: `"23310f77-617cc5cb65f58"`.
- Raw bytes: 104,661,506. Extraction transferred 13,265,495 bytes by HTTP ranges;
  the preceding central-directory-only listing transferred 19,851 bytes.
- Raw SHA256: `bccfff47a3f6de9d28117d8c76aabf47716afb92a16982067764dcc6f34f769e`.
- The audited raw size exceeds the previous 64 MiB safety cap. A tested,
  network-specific 128 MiB cap now applies only to C3E4N06717D2. The 16 MiB
  compressed transfer cap and refusal of full-archive fallback remain unchanged.

The raw case passes the required-feature gate without changing any source value.
It has no startup-count windows or affine/equality P-Q capability devices, unlike
the preceding 6,049-bus case. The feature audit alone does not imply AC feasibility.

| Property | Value |
| --- | ---: |
| Buses | 6,717 |
| Producers / consumers | 731 / 5,095 |
| AC lines / two-winding transformers | 7,173 / 1,967 |
| Shunts / DC lines | 634 / 0 |
| Active / reactive reserve zones | 9 / 12 |
| Intervals / total duration | 48 / 48 hours |
| Source contingencies per interval | 2,670 |
| Required exhaustive contingency-interval evaluations | 128,160 |

## Frozen published reference

The unchanged official Final Event workbook is read-only. Comparison is the same
network, scenario, Division 2 and switching permission (`SW=1`). Eligibility uses
the published active and feasibility fields; missing scores, infeasible entries
and the ARPA-e benchmark are excluded. There are nine eligible competitors.

Source: <https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx>, `data` sheet.
Workbook SHA256:
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
Exact rows, UUIDs and eligibility fields are retained in
`manifests/campaign/published_C3E4N06717D2_s002.json`.

| Published rank | Team | Score | Published runtime (s) | Source row |
| --- | --- | ---: | ---: | ---: |
| 1 | YongOptimization | 798,048,810.838310 | 1,781 | 9897 |
| 2 | GravityX | 798,014,001.114725 | 7,215 | 3876 |
| 3 | GOT-BSI-OPF | 796,752,986.348886 | 1,044 | 3207 |
| 4 | quasiGrad | 791,263,521.853814 | 6,850 | 7221 |
| 5 | TIM-GO | 789,365,501.736817 | 4,116 | 9228 |
| 6 | Occams razor | 755,375,223.938404 | 4,416 | 5214 |

The requested minimum is **679,837,701.5445635** (90% of sixth place). We do not
exclude officially eligible rows based on a separately reported runtime; timing
boundaries can differ. Our own limit remains 7,200 seconds end to end. This is a
published-score comparison, not an official placement, hardware-matched speed
comparison or global-optimality certificate.

## First attempt protocol

`config/campaign_n06717_s002_r01.json` copies the successful 6,049-bus r03 numerical
settings without alteration. Differences are case identity, raw digest and
provenance paths only. The implementation includes the complete-residual rounded-
iterate guard, bounded numerical recovery and protected finalization budget.
No previous solution is imported. Within-attempt primal/dual transfer remains
allowed and logged. All 48 AC intervals and all source contingency checks must
finish; a partial horizon is not success.

The cold scheduling MILP has at most 3,600 seconds, subject to the global budget.
Continuous/rounded/recovery AC budgets are at most 90/240/360 seconds per solve,
again limited by time remaining. Reserve finalization has a protected 90 seconds.
The controller reserves 600 seconds for exhaustive verification and 30 seconds
for result finalization. Source PMIN, bounds, costs and all acceptance tolerances
are unchanged. Native early-stop statuses are never described as local/global
optimality. Source-priced overload penalties remain part of the score.

Before launch: complete fixture-only component tests, freeze and push the clean
revision, verify prior-network completion hashes and check physical disk space.
The permanent r01 latch permits one full cold attempt only. No full run has yet
been executed at the time of this registration.

The complete fixture-only gate passed before freezing: **73 Python tests and
776 Julia assertions**, plus seven complete tiny verification pipelines. Each
checked all nine fixture contingency-interval combinations with official hard
and physical feasibility. All six normal worker variants had exact 3/3 AC
interval coverage. Evidence: `tmp/pilot002_component_gate_cm9yu1_y` and the
hash-indexed `manifests/component_tests.json`. No competition-case solve was used
as a test or warmup.
