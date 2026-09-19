# C3E4N23643D2: queued after verified 8,316-bus success

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

This is metadata only: no raw case, supplied POP, or full archive was downloaded
by this inspection. The raw SHA256, source feature support, contingency count,
score reference, memory demand and solvability remain unverified. Before later
extraction, test a bounded network-specific raw-size allowance covering this
audited member; the existing 16 MiB compressed transfer cap is sufficient.
Register and freeze the full attempt only after the 8,316-bus acceptance gate
passes. This document does not claim a completed experiment.

## Predecessor gate completed

On 2026-09-19, 8,316-bus scenario 103 attempt r03 passed its full acceptance
gate in 6,508.759884 seconds: all 48 hours, all 301,872 source contingency-hour
checks, independent hard feasibility, objective agreement, official `feas=1`
and `phys_feas=1`, and the sixth-best-score target. Its compact evidence is
`evidence/campaign/campaign_n08316_s103_r03/` and the completion registration
is hash-bound in `manifests/authorization_campaign.json`.

The 23,643-bus source audit and component-tested setup can now proceed. No
23,643-bus full-case run has been launched or claimed successful by this record.
