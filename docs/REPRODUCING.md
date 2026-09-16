# Reproduction and launch boundaries

Use a local path outside OneDrive. Do not use the GO2 working directory or copy
its environment/results. The development branch and draft PR are public, while
raw inputs, dependency checkouts and full solutions remain local and ignored.

## Environment actually used

- Windows laptop, Lenovo 83F5, Intel Core Ultra 9 275HX; 24 physical/logical
  processor entries reported by Windows; approximately 32 GiB RAM installed.
- Julia 1.10.11, JuMP 1.31.2, HiGHS.jl 1.25.4 / HiGHS 1.15.1,
  Ipopt.jl 1.15.0 / Ipopt 3.14.19, MUMPS_seq 5.9.1.
- Python 3.12.14, NumPy 1.26.4, SciPy 1.13.1, pandas 2.2.3,
  networkx 3.3, pydantic 1.10.24, psutil 7.0.0.
- Existing Julia and Python executable installations are used read-only.
  New Julia packages/compiled caches are isolated under `environments/julia-depot`.
  Evaluator-only pydantic/psutil dependencies are isolated under `.cache/pydeps`.
- HiGHS thread cap 4 consistently for scheduling and reserve models; Julia
  interval worker and BLAS/OpenMP thread caps 1. No GPU/commercial solver.

The exact Julia environment is `Project.toml` + `Manifest.toml`. Upstream paths
in that manifest are relative to this repository. Clone each URL in
`manifests/sources.json` to `.cache/upstream/<name>` and checkout its exact commit;
preserve all notices. Instantiate using this project's isolated `JULIA_DEPOT_PATH`.
Do not invoke LANL's general CLI, which may select commercial defaults. Our worker
supplies explicit open-source optimizers. Do not run an extra benchmark as setup.

The selected raw input is retrieved by `scripts/audit_sources.py` using the exact
entry in `manifests/case.json`. The script refuses a non-range archive response
and does not extract supplied solved POPs. Official documents and the workbook
are referenced with SHA256 values in `manifests/sources.json`.

## Tests, preflight, and the one permitted run

Use the pinned Python environment, with `TEMP`/`TMP` under local `tmp/`:

```
python scripts/test_official_adapter.py
python -m unittest discover -s tests -v
julia --startup-file=no --project=. scripts/test_solver.jl
python scripts/run_pilot.py --preflight-only
```

The Julia command requires `JULIA_DEPOT_PATH=<local project>/environments/julia-depot`,
`JULIA_NUM_THREADS=1` and `OPENBLAS_NUM_THREADS=1`. The preflight refuses dirty or
unpushed code, changed upstream/input hashes, an unregistered configuration,
insufficient physical Windows free space or an existing pilot latch. Setup must
also have satisfied the documented test gates. The full source-loaded pilot is:

```
python scripts/run_pilot.py
```

**Do not execute that final command again without a new user authorization.**
The persistent `runs/pilot_latch.json` is intentional, including on failure.
Do not delete the latch to bypass the boundary. An official-format retained
solution can be re-evaluated only as a separately requested follow-up; re-evaluation
does not reconstruct deleted solution fields from a certificate alone.

The controller overwrites its children's TEMP/TMP, Julia depot, Python bytecode
cache and numerical thread settings with paths/settings within this local project.
It records a live physical-storage gate, hardware inventory, implementation/config
hashes and sampling-based process memory/CPU measurements for the run.
