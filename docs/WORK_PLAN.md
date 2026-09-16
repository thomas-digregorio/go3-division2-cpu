# Work plan

1. Inspect GO2 source and retained correctness evidence, without changing GO2.
2. Pin official GO3 formulation, schema, evaluator and results; resolve historical
   Final Event compatibility and identify one scenario deterministically.
3. Publish a numerical-component reuse audit and explicit model coverage matrix.
4. Implement candidate construction, exhaustive checking and deadline control.
5. Pass positive and negative tiny-fixture tests for every applicable feature.
6. Freeze and push code/configuration/manifests; report the preflight manifest.
7. Run one cold 1,800-second pilot, preserving full solution and evidence.
8. Report objective, penalties, coverage, timings and matched published results;
   stop for review, including on failure or a prerequisite blocker.

Storage floor: 30 GiB of physical C: free space, plus estimated pending writes.
If setup cannot honor that floor, stop and request direction. Do not prune GO2.

The pilot is not authorized until all required implementation and component-test
gates pass. A partially implemented model must not consume the sole full run.
