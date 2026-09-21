# Same-algorithm regression: frozen 2713e5d

## Explicitly authorized replacement after the path-saving failure

The first 617-bus attempt completed optimization and exhaustive verification,
but the newly lengthened checkout/run identifiers made the retained certificate's
temporary filename 279 characters long. Windows long-path support was disabled,
and the frozen controller failed to publish that retained certificate. The queue
correctly stopped. Its original outputs and consumed authorization remain in
`C:/Users/thoma/Documents/go3-division2-cpu-2713e5d-regression` without modification.

The user explicitly authorized fixing the saving issue, rerunning 617 cold, then
continuing. This replacement uses `C:/Users/thoma/Documents/go3-r2713`, short
`campaign_r2_NNNNN` identifiers, and a new queue/latch. The maximum anticipated
certificate temporary path is 234 characters, checked against a conservative
240-character preflight cap. A targeted test invokes the unchanged real
`Incumbent.consider` / `atomic_json` write-copy-hash-rename sequence at an even
longer synthetic path and confirms the retained solution and certificate exist.
Windows registry settings need not change. No numerical source file changes.

The complete 45-stage numerical gate already passed on these exact source bytes
(93 Python tests, 3,450 Julia assertions); its original evidence is retained and
hash-audited. The changed registration, path guard and real saving workflow receive
fresh targeted tests before the replacement is committed, pushed and launched.

## Common frozen contract

User authorization: run the previously selected smaller GO3 Division 2 cases
on algorithm `2713e5df972f8cae7b77d8963419eba4e1f28424`, including 6,717 buses,
sequentially, and stop on the first failure. No numerical changes or retry.

Order: 617/s002, 2,000/s005, 4,224/s002, 6,049/s003, 6,717/s002.
The existing 8,316/s103 result is historical evidence, not another authorized
run in this queue. Nothing here runs the 23,643-bus case.

Every solver/model/checker/controller source and dependency lock matches the
original frozen component-gate source inventory byte for byte. Configurations
copy the successful 8,316 r03 settings verbatim, changing only case identity,
manifest paths and new experiment-registration metadata. Each run is cold,
with 7,200 seconds end-to-end, the existing resource guards, all 48 hours,
exhaustive independent/official verification, and the existing score-quality
gate (at least 90% of the sixth-best eligible published score). GO3-allowed
penalties remain; this is not a zero-overload or global-optimality claim.

`run.py` is a new registration/queue adapter. It supplies an explicitly
authorized, fresh exclusive latch to the unchanged `scripts/run_pilot.py`.
This is necessary because the historical pilot/campaign authorizations are
consumed and the old campaign does not include the 617-bus network. It does not
override any optimizer, physics, objective, screening, tolerance or acceptance
function. The original preflight and execution controller remain in use.

The numerical algorithm commit and the separate registration/evidence commit
are recorded separately in each preflight. All original authorization latches
and results remain untouched. The current 23k working branch is not checked out
or altered. Local dependency/raw-input junctions avoid duplicating large data;
their targets are outside OneDrive and are hash checked before use.

Before launch: run the frozen tiny-fixture component gate and `test_harness.py`,
commit/push the registration and test evidence, then run `run.py --check`.
`run.py --run` consumes one queue authorization and at most one attempt per
listed case. Any failed stage, absent completion, failed verification or score
gate, or timeout stops the queue. No automatic replacement is permitted.
