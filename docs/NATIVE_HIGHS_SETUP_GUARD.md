# Bounded optional objective-clique setup in local HiGHS

The user authorized another cold 23,643-bus attempt after bug fixes and explicitly
allowed retaining FP64. The r06 native log identifies a stall inside MIP setup,
after presolve and before the root LP. It does not identify its exact C++ routine.
The already-tested external native-call watchdog fixes deadline enforcement;
this separate patch limits one plausible expensive setup operation and adds
attribution for the rest. It is not yet evidence of a full-case speedup.

## Mathematical scope

The patch adds `mip_objective_clique_max_size`, whose default is the largest
32-bit integer (unchanged upstream behavior). If the number of nonzero-cost
binary columns exceeds the configured cap, the optional objective clique
partition is left empty. Otherwise the upstream routine runs unchanged.
The intended large-case cap is 4,096. This bounds the size passed to the
potentially quadratic neighborhood-scanning routine; it is not a strict CPU
instruction budget or a replacement for the external deadline.

With no objective clique partitions, upstream `HighsDomain::ObjectivePropagation`
uses its existing independent-bound calculation. For minimization this begins
with the valid lower bound

`sum_j min(c_j * lower_j, c_j * upper_j)`

with the upstream handling for infinite bounds. Clique information can strengthen
this bound but is not required for its validity. Leaving it unused can reduce
propagation strength and potentially increase later search. It does not delete
any source row, change a cost/bound, relax an integer domain, change feasibility
tolerances, or remove clique constraints from the actual LP/MIP model.

The patch logs transitions through initialization, transpose/locks, row
integrality, objective clique grouping, objective propagation, row activities,
domain propagation, objective integrality, basis transfer and heuristic-column
setup. A skip records its actual objective-binary count and cap. These observations
will distinguish the candidate hotspot from other setup costs in the next run.

## Isolation and provenance

- Upstream source: HiGHS 1.15.1, commit
  `04024d701f79feb8e2f18bc3df0dffc04ef05088`.
- The installed Julia HiGHS artifact is unmodified. A separate local build lives
  under `environments/highs-setup-guard-build` (ignored by Git).
- `patches/highs-1.15.1-setup-guard.patch` contains the complete source change.
  `manifests/native_highs_setup_guard_v1.json` binds the patch, DLL, executable,
  support DLL and process-local artifact override by SHA256.
- Only native Benders master/recourse child processes receive the overlay depot.
  Raw-case builders, AC refinement, and ordinary configurations retain the stock
  library. Each native child independently records/checks the loaded DLL hash.
- The current local build uses portable w64devkit 2.10.0 / GCC 16.2.0 and CMake
  4.4.3, Release without fast-math, 32-bit indices and FP64 values. GPU support,
  HiPO and zlib are disabled; there is no external BLAS in this build. The
  registered native route uses simplex. This is a changed native build, not a
  claim that compiler/library differences have no effect on timings.
- Artifacts and overrides are checked before launch. A changed binary/patch
  fails closed. Both manifests and patch files are covered by the component
  source inventory. No global package, PATH, or machine configuration is changed.

## Rebuilding the local library

Setup is separate from timed experiments. Use the pinned source and portable
toolchain checksum from the manifest, outside OneDrive. Apply the tracked patch
to a fresh checkout of the exact source revision. With the toolchain `bin`
directory on the current process PATH, configure and build:

```powershell
cmake -S environments/highs-native-source-04024d701f -B environments/highs-setup-guard-build -G Ninja `
  '-DCMAKE_C_COMPILER=gcc.exe' '-DCMAKE_CXX_COMPILER=g++.exe' `
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF `
  -DBUILD_EXAMPLES=OFF -DBUILD_CXX_EXE=ON -DHIPO=OFF -DZLIB=OFF `
  -DCUPDLP_GPU=OFF -DHIGHSINT64=OFF
cmake --build environments/highs-setup-guard-build --parallel 4
```

The overlay contains only an `artifacts/Overrides.toml` mapping the pinned stock
artifact ID to this local build prefix. It is passed via the child-specific
`JULIA_DEPOT_PATH`, followed by the unchanged ordinary depot. A rebuild must
update the explicit build hashes and pass fresh tests before registration;
do not silently replace the binary beneath a frozen run.

HiGHS is MIT-licensed; the original copyright and license remain in the local
source checkout. The patch modifies HiGHS source under that license. Portable
w64devkit and its runtime notices are retained with the local toolchain. Binaries
are not published in this repository; distributing them would also require
their applicable runtime/dependency notices.

## Acceptance remains unchanged

Small tests compare the cap disabled, 4,096, and zero (forced skip) against
exhaustively enumerated mixed-integer fixtures, including infeasibility. Native
identity tests and a guarded three-period AC pipeline supplement the complete
existing regression gate. A source-matched completed gate is mandatory before
the new cold full-case attempt. Full-case success still requires all original
scheduling audits, all 48 AC intervals, complete independent and official
security verification, the registered score target and the 7,200-second limit.
