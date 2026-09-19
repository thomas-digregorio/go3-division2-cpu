# C3E4N23643D2 scenario 003: source audit, not yet run

The user authorized one 23,643-bus Division 2 scenario after one 8,316-bus
scenario, using the original CPU HiGHS scheduling and Ipopt/MUMPS refinement
route. The target remains at least 90% of the sixth-best eligible published
score, full independent and official verification, and a 7,200-second hard
end-to-end limit. No optimized external solution may initialize either run.

## Read-only archive audit before scenario selection

An HTTP-range central-directory inspection transferred only 2,358 bytes. It
listed two exact raw Division 2 members: scenarios **003** and **004**. Select
**003**, the smallest numeric scenario, before inspecting our solve quality.

- Archive: <https://data.openei.org/files/5997/C3E4N23643_20231002.zip>.
- Archive ETag: `"315dafa-617cc5d4408f8"`.
- Archive size: 51,763,962 bytes.
- Selected member: `D2/C3E4N23643D2/scenario_003.json`.
- Declared raw size: 236,784,393 bytes.
- Declared compressed size: 8,618,679 bytes.
- Declared CRC32: `b6ba8919`.

This initial inspection transferred metadata only: no raw case, supplied POP,
or full archive was downloaded at that stage. It did not establish a raw hash,
feature support, contingency count, comparison target, or solvability. The
subsequent retrieval and audit below preserve this preselection. No full attempt
may be registered before the predecessor and source-support gates pass.

## Predecessor gate completed

On 2026-09-19, 8,316-bus scenario 103 attempt r03 passed its full acceptance
gate in 6,508.759884 seconds: all 48 hours, all 301,872 source contingency-hour
checks, independent hard feasibility, objective agreement, official `feas=1`
and `phys_feas=1`, and the sixth-best-score target. Its compact evidence is
`evidence/campaign/campaign_n08316_s103_r03/` and the completion registration
is hash-bound in `manifests/authorization_campaign.json`.

The 23,643-bus source audit and component-tested setup can now proceed. No
23,643-bus full-case run has been launched or claimed successful by this record.

## Raw-source audit after the predecessor passed

Four bounded-download component tests passed before extraction, including the
network-specific 256 MiB raw limit and rejection of oversized members before
reading them. The 16 MiB compressed transfer limit, exact raw-member selection,
CRC checks, and prohibition on POP/full-archive fallback were unchanged.
Only the selected raw member was downloaded: 8,621,100 transferred bytes,
236,784,393 raw bytes, SHA256
`9bc54c983ac79a16a5f40f1d27e17d4750c84ed8659e40ad64a68d171943c5e5`.
No supplied or previous optimized solution was read.

| Source quantity | Count |
|---|---:|
| Buses | 23,643 |
| Producers / dispatchable consumers | 6,274 / 11,731 |
| Total simple dispatchable devices | 18,005 |
| AC lines / two-winding transformers | 23,797 / 9,942 |
| DC devices | 1 |
| Shunts | 2,717 |
| Active / reactive reserve zones | 16 / 36 |
| One-hour intervals | 48 |
| Source contingencies per interval | 26,870 |
| Required contingency-hour evaluations | 1,289,760 |

Every source contingency is a single existing AC-line or transformer outage.
There are no DC-device outages. The one source DC link is `dcl_0`, from
`bus_12794` to `bus_13032`; its source active-power upper-bound parameter is
15 p.u. and its reactive bounds at each terminal are -1.5 to 4.5 p.u.
All three source initial terminal-flow values are zero.

The current feature gate **correctly refuses this input** because independent
DC-device validation is not implemented. The other previously gated features
(energy windows, startup-state costs, startup-count windows, P-Q equality or
affine bounds, and additional branch shunts) are absent here. The DC link must
be modeled, serialized, and independently checked with its original source
bounds; it must not be discarded to make the gate pass. No full-case solver
has started. This audit is not a successful feature-support registration.

## Comparison target requires a user decision

The unchanged eligibility rules find eight active, feasible competitors but
only five positive scores for scenario 003, Division 2, switching enabled:

| Positive rank | Team | Published score | `data` sheet score cell |
|---:|---|---:|---|
| 1 | YongOptimization | 600,577,211.010372 | H10036 |
| 2 | quasiGrad | 598,132,224.471649 | H7360 |
| 3 | GOT-BSI-OPF | 589,696,575.511268 | H3346 |
| 4 | TIM-GO | 588,991,289.929324 | H9367 |
| 5 | Artelys_Columbia | 353,804,820.240399 | H1339 |

The other three eligible scores are zero. Consequently the **sixth-best
eligible score is zero**, not a missing sixth row. A relative 10% shortfall from
zero is undefined, and the existing comparison gate refuses it. It has not been
weakened or silently replaced. The user has been asked to choose a meaningful
reference (for example the fifth-best positive score or the best score).

The spreadsheet audit read the original stored numeric cells and eligibility
fields, including their formula metadata, without modifying/recalculating the
workbook. The score cells above are numeric source values with no formulas.
The retained workbook SHA256 remains
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
Source: <https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx>.

Most published entries for this network list a 259,200-second (72-hour) time
limit; two list 7,200 seconds. These workbook fields must not be described as
a uniformly two-hour competition comparison. The user's stricter **7,200-second
end-to-end limit remains unchanged**. No replacement score reference or new
full-run configuration has been selected.

The machine-readable audit is
`manifests/campaign/audit_C3E4N23643D2_s003.json`; the raw published comparison
records are in `manifests/campaign/published_C3E4N23643D2_s003.json`.
