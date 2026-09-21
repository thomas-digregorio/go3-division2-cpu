# Same-algorithm regression: frozen 2713e5d

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
