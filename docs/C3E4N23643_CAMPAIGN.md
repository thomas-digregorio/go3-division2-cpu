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

The initial feature gate **correctly refused this input** because independent
DC-device validation was not implemented. The other previously gated features
(energy windows, startup-state costs, startup-count windows, P-Q equality or
affine bounds, and additional branch shunts) are absent here. The DC link must
be modeled, serialized, and independently checked with its original source
bounds; it must not be discarded to make the gate pass. No full-case solver
has started. The subsequent component evidence below addresses this feature;
the original audit did not itself prove feature support.

## DC support: tested component milestone, not a full-case result

The pinned upstream AC solver already includes the lossless DC-link model,
with `p_to = -p_from` and independent reactive power at its two terminals.
Project-owned changes add source-domain and identity checks, independent
terminal-bound checks, and the signed DC injections to both the AC balance
and every explicit post-outage solve. Exported reports retain p.u., MW and
Mvar terminal values. Cold schedule candidates preserve source initial DC
values; AC optimization does not fix the link to those values or to zero.
No upstream model/evaluator file, source limit, tolerance or penalty changed.
DC-device outages remain explicitly unsupported; this source has none.

The focused gate `tmp/dc_feature_gate_7c426sjo` passed all five stages:
103 Python tests, 31 Julia assertions, and a complete original two-bus,
three-interval DC integration. All nine outage-interval checks completed;
independent hard feasibility, objective agreement, official `feas=1` and
`phys_feas=1` passed. Maximum P/Q imbalance was respectively
1.525059246e-10 / 2.306201823e-9 p.u.; objective disagreement was
5.229594535e-12. Tests cover both active-flow directions, all six terminal
limits, invalid/missing data, nonzero initial powers, optimized flow export,
and within-run primal transfer. Initial test-fixture mistakes (an incomplete
mock schedule, an inadmissible transformer control combination, and an
exact-equality floating-point assertion) were corrected before this gate.
They did not require a change to solver tolerances or source physics.

The raw 23,643-bus input was subsequently reread and hash-checked without
solving. Its feature gate passes and its initial AC network is connected
without relying on the DC link. The raw hash is unchanged. Compact component
evidence is retained under `evidence/components/dc_support_20260919/`.
This focused gate is **not** the complete full-case preflight gate: a final
configuration, meaningful score reference, complete component regression,
clean frozen/pushed revision, and resource preflight are still required.

## Reserve-model lifetime: bounded storage without a different LP

Inspection of the pinned `GOC3Benchmark.jl/src/reserves.jl` found that the
horizon wrapper retains all `(model, data)` pairs even with `return_models=false`.
The opt-in `reserve_storage_policy=bounded_lifetime_v1` calls the identical
upstream per-interval builder, optimizer, extraction and projection functions.
It copies only numeric awards to the horizon result, releases each model, and
checks that its weak reference is empty before proceeding. It also avoids the
48-interval duplicate OPF-data representation and rechecks the existing global
budget before configuring each LP. No reserve constraint or cost is removed.
The legacy path remains the default for existing configurations. The policy is
restricted to the already-registered single Julia thread; it is not a switch
from a parallel full-case protocol. This is storage management, not DAYZER/SLP.

Focused evidence `tmp/reserve_feature_gate_5sgf6gbe` passed six stages:
104 Python tests, 31 DC Julia assertions, 115 reserve-storage Julia assertions,
and the complete three-interval AC/DC worker with initial and final reserves.
All six reserve LP models were released individually. The final solution is
byte-identical to the preceding legacy-storage tiny solution (SHA256
`1f1c5a600925f14c2bb494aed9a4276ebe29f7a4d1e50009fccb774fe14d1c65`).
Independent and official checks passed all nine contingency-hour combinations,
with `feas=1`, `phys_feas=1` and unchanged numerical results. Unit tests also
compare all ten reserve products in online/offline fixtures against the original
horizon wrapper, preserve all inputs, and exercise an exhausted budget before
the second LP. Compact evidence is in
`evidence/components/reserve_storage_20260919/`. This does not yet establish
full-case memory consumption or runtime.

## New preflight finding: official evaluator memory

A read-only allocation audit found a separate full-case resource concern in
the pinned official `C3DataUtilities/datautilities/ctgmodel.py`, SHA256
`0876bc72009fa9c91040ae0442fef1a74f854852b5ca994ecce1b912305d6f00`.
It allocates dense work arrays over all unique source contingency branches.
For this input there are 22,314 unique AC-line outages and 4,556 transformer
outages, 23,642 nonreference buses and 33,739 AC branches. Named arrays at lines
226-278 account for at least:

`8 * [23642 * (4 * 22314 + 6 * 4556) + 33739 * (22314 + 4556)]`

= **29,304,279,952 bytes (27.291737452 GiB)** of dense array storage. This excludes
temporary solve results, factors, source/solution arrays, Python objects and the
operating system. It is an allocation-size calculation, **not a measured RSS or
failed full solve**. Windows reports 31.43 GiB visible RAM and approximately
19.8 GiB available at the audit, so the unchanged evaluator is not a safe
memory plan. The reserve-storage fix does not address these separate arrays.

No upstream evaluator file has been changed, no contingency has been dropped,
and no large run has been launched. Before launch, a bounded-memory exhaustive
evaluation approach must be established and tested (including correct global
worst/average penalty aggregation and complete source coverage); it must not
silently replace an official full-case result with a partial-subset result.
The score-reference decision below also remains unresolved.

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

## Approved continuation: fifth-positive reference and bounded evaluation

The user's subsequent "yes proceed" approved both the fifth-best positive
reference and a memory-bounded exhaustive official evaluation wrapper. For
**scenario 003 only**, the reference is **353,804,820.240399** and the required
score is **318,424,338.2163591**. The sixth-best score remains recorded as zero;
every other case and all historical results retain their original sixth-best
policy. No reference is used as a solver start.

`go3cpu/official_batching.py` partitions outage columns into batches of 512,
invoking the unchanged, hash-pinned official contingency routine on the entire
network and all 48 periods each time. The original official caller still checks
connectivity for the full set, computes all base/hard/reserve checks, and forms
global worst-case and average penalties from the complete source-ordered
`t_k_z` array. It does not average averages of unequal batches. Duplicate
outaged components with distinct source contingency IDs remain distinct.
Reported maxima are merged with original source-index/time tie ordering.
Missing/nonfinite batch results, skipped execution, unknown source hashes and
exhausted deadlines cannot produce a complete batch audit. The process-local
hook is restored on success or exception; upstream files remain unchanged.
The independent explicit post-outage factorization checker remains separate.

Synthetic tests compare every penalty, global objective and reported maximum
against the unsplit official routine, including nonzero DC flow, transformer
phase/taps, varying topology, congestion, uneven batches and duplicate-component
identities. Failure tests cover deadlines, incomplete/nonfinite results,
disconnected contingencies, invalid sizes, nested use and source-pin mismatch.
A full tiny AC/DC pipeline also goes through the CLI and both checkers.

Registered attempt `campaign_n23643_s003_r01` preserves the successful 8,316-bus
numerical route and enables bounded reserve-model lifetime and batched official
verification. Its 7,200-second global limit includes a **2,400-second reserved
final verification window** and 30 seconds for finalization. This reserves more
time for 1,289,760 contingency-hour checks; it is a budget, not a claim that the
larger case will finish. The component suite and hash/clean-commit preflight
must pass before a full-case process can start. The successful 8,316-bus run
will not be repeated.

### Completed component gate

`tmp/pilot002_component_gate_zxdkioae` completed with process exit 0:
**52 stages, 118 Python tests and 3,596 Julia assertions**, all passing. Summed
stage wall time was 1,225.006 seconds; this is setup/testing, not a full-case
experiment. The new batched AC/DC tiny certificate has `feas=1`, `phys_feas=1`,
independent hard pass, and all **9/9** contingency-hour evaluations. Objective
is **1,732.1459647319407**, identical to the unbatched evaluation; independent
objective discrepancy is **5.229594535194337e-12**. Maximum P/Q imbalance is
**1.525059245555127e-10 / 2.3062018232600234e-9 p.u.**

Compact evidence, including the full hash-bound component manifest, both tiny
certificates, batch coverage, independent results, tiny candidate and test logs,
is retained in `evidence/components/official_batches_20260919/`. The copied
files were individually hash-verified; Git preserves their exact bytes.
No full 23,643-bus run was started during this gate. Its measured memory,
runtime, objective and final verification remain to be established by r01.

## r01: safe memory stop during native scheduling handoff

Frozen implementation **f48d82a489a33d149cf3a5f2fbb404364df99d37** and config
SHA256 `023160d35614940c0adc12092ed26e85feaf8e313e74f696eb3ff0605ed35a99`
started one cold attempt. It stopped and finalized after **745.168658 seconds
(12.42 minutes)**, inside the two-hour limit. All owned processes exited.

The scheduling model was built in **538.001 seconds**, with **19,323,456
variables** before solver presolve. During the whole-model native handoff,
available host memory fell to **1.856629 GiB**, below the registered **2 GiB**
safety floor. Sampled peak process-tree RSS was **18.954803 GiB**. The controller
recorded `HostMemoryPressureError` and `NO_VERIFIED_INCUMBENT`.

This is a resource stop, **not infeasibility**. The economic optimization had
not started; there is no objective, bound, gap or schedule. Zero AC intervals
completed, and full-case independent/official verification was not reached.
The new batched evaluator remains proven only by the component tests, not by
this incomplete large run. The registered fifth-positive target remains unmet.

Compact hash-audited evidence is in
`evidence/campaign/campaign_n23643_s003_r01/`. Raw inputs, previous successful
results and all r01 artifacts remain intact. No successful 8,316-bus run was
repeated. The next storage-only investigation is to discard unused construction
lookup containers before the native copy; this must not remove mathematical
rows, columns, names, coefficients, bounds or source values.
