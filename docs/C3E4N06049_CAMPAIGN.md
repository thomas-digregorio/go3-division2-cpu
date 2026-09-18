# 6,049-bus cold quality campaign

The 2,000- and 4,224-bus networks have passed their independently verified
sixth-best-score targets. Their immutable result/completion hashes authorize
this next network. No preceding successful attempt is repeated.

## Input and source-feature audit

Scenario **003** is the smallest-numbered public Division 2 scenario, chosen
before inspecting our solve quality. The archive lists 18 scenarios: 003, 007,
009, 013, 015, 019, 025, 031, 037, 043, 049, 055, 057, 061, 063, 067, 069, 073.
Only `D2/C3E4N06049D2/scenario_003.json` was retrieved by bounded HTTP ranges from
<https://data.openei.org/files/5997/C3E4N06049_20231002.zip>.
Source archive ETag: `"23764100-617cc5c77c400"`. The transfer was 8,715,944 bytes;
the raw JSON is 64,038,939 bytes. No supplied POP or other optimized solution
was downloaded or used. Raw SHA256:
`312b066e51e4e058d0f2e1a96ea32c8f30a3f1dbfc9c4266b6d5d73af4206e41`.

The case contains 48 one-hour intervals, 6,049 buses, 406 producers, 3,368
consumers, 4,920 AC lines, 3,086 transformers, 236 shunts, no DC lines and
six each of active/reactive reserve zones. Its 3,902 source contingencies per
hour require **187,296** independent contingency-hour evaluations. All 7,548
source startup-count windows and 402 devices with affine P-Q capability bounds
remain covered. The complete required-feature gate passes without any feature
omission or new model relaxation.

## Published-score target

The unchanged official workbook SHA256 is
`8ae933e17368428ffdb822b3fd3b28ea2969b65a8446e4d1f35e7f8b45654ff1`.
A read-only spreadsheet audit preserves the original values, source rows,
eligibility, switching permission and evaluator identities in the comparison
manifest. The sixth-best eligible score is **597,463,992.571312** by
Electric-Stampede (source row 1748). The required 90% minimum is
**537,717,593.314181**. Only the same scenario, Division 2 and switching permission
are compared, with one active feasible result per team, excluding ARPA-e's
benchmark. Missing/inactive/infeasible records are not assigned artificial scores.

| Eligible rank | Team | Published score | Source row |
| --- | --- | ---: | ---: |
| 1 | TIM-GO | 609,159,208.762250 | 9107 |
| 2 | YongOptimization | 609,001,575.108100 | 9776 |
| 3 | GOT-BSI-OPF | 608,909,921.153217 | 3086 |
| 4 | GravityX | 608,584,286.387930 | 3755 |
| 5 | LLGoMax | 608,563,770.630885 | 4424 |
| 6 | Electric-Stampede | 597,463,992.571312 | 1748 |

These are retrospective score references, not global optimality bounds or
hardware-normalized timings. Eligibility follows official active/feasibility
fields; our own hard end-to-end cap remains 7,200 seconds.

## Registered first attempt

`campaign_n06049_s003_r01` retains the numerical algorithm and settings of the
successful 4,224-bus r04: HiGHS/simplex source-reserve scheduling with guarded
consumer dominance, joint reserve-aware AC refinement, complete same-interval
rounded-shunt primal-dual starts and preceding locally screened hour's primal
continuation. The process begins cold, hour 1 uses raw/default initialization,
and no external solution or previous-attempt primal/basis/dual is read.

The end-to-end cap is 7,200 seconds, reserving 600 seconds for final exhaustive
verification and 30 for serialization. Scheduling has a 3,600-second maximum
and 1e-3 relative gap; AC phases retain their 90/240-second maxima under the
remaining global budget. Source PMIN, costs, all temporal/reserve/AC constraints,
official penalty semantics and independent acceptance tolerances are unchanged.
Only scenario identity/provenance changes from the preceding configuration.
No GPU or commercial solver is used. Full component tests and a clean pushed
commit precede the single cold full-size attempt.

The prelaunch component gate passed **69 Python tests and 520 Julia assertions**.
All six tiny end-to-end pipelines passed official hard/physical feasibility and
independent 9/9 contingency-interval verification. Evidence resides in
`tmp/pilot002_component_gate_7waw6df_` and is hash-registered in
`manifests/component_tests.json`. No full-size scenario was used by this gate.
