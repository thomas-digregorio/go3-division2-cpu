# Numeric storage precision: read-only r06 master audit

On 2026-09-20, the user's suggestion to reduce numeric storage precision was
checked without an optimization call or modification to any original data.
All numerical solver coefficients, bounds, costs, and primal vectors in the
current pipeline use Float64 (64 bits, **8 bytes** per number). Matrix indices
and source-column/row mappings already use 32-bit integers where supported.

The installed HiGHS 1.15.1 revision is `04024d701f`. Its
[native C interface](https://github.com/ERGO-Code/HiGHS/blob/04024d701f/highs/interfaces/highs_c_api.h)
accepts `double` numeric arrays. Changing only our serialized array dtype does
not change the native solver's internal arithmetic or working allocations;
conversion back to double would still be required. We did not rebuild HiGHS,
quantize a model, run an FP8/FP16/FP32 optimization, or change any acceptance
tolerance.

## Exact audit scope

Input directory, relative to the repository:

`runs/C3E4N23643D2_s003_campaign_n23643_s003_r06_20260920T204625Z/worker/reserve_decomposition/reserve_partition/master`

Master manifest SHA256:
`0c9dedd06b7a740b260fc487167b00ba9363144f24e4f42f8de73b701a061692`.
It records 8,043,170 columns, 10,931,162 rows and 32,733,724 nonzeros.

Each of six numeric files was streamed in chunks of 262,144 Float64 elements.
Its SHA256 was checked against the immutable master manifest. For each finite
source value, NumPy converted a temporary copy to standard IEEE float32 or
float16 and back to float64. Existing infinite bounds were excluded from error
counts. No full input array was materialized and no file was rewritten.
FP8 was **not** tested; it would require choosing a format/scaling policy.

The six arrays contain **629,804,464 bytes (0.586551 GiB)** in Float64. Float32
storage would save **314,902,232 bytes (300.314 MiB / 0.293276 GiB)** for this
one array copy. This is not a prediction of whole-process RAM savings. The
observed r06 native stage peak was 13.119 GiB; sparse indices, solver copies,
presolve data, working vectors and other native allocations are outside this
six-file accounting.

| Array | FP32 max absolute finite conversion error | FP16 max absolute error among finite converted values | Finite source values overflowing in FP16 |
|---|---:|---:|---:|
| Matrix coefficients | 1.5258789e-6 | 0.00625 | 0 |
| Objective costs | 0.0117190000 | 15.999878 | 315,744 |
| Column lower bounds | 4.9926729e-11 | 0.0037078857 | 0 |
| Column upper bounds | 1.4722422e-5 | 0.0608000159 | 0 |
| Row lower bounds | 3.0398394e-5 | 0.2497999668 | 0 |
| Row upper bounds | 1.9073250e-6 | 0.0155999996 | 0 |

FP32 caused no overflow or nonzero-to-zero conversion in these files. FP16
overflowed 315,744 finite cost coefficients to infinity; all other finite
conversions had no overflow or nonzero-to-zero conversion. Counts and errors
describe plain casts, not an engineered mixed-precision/scaled method.

## Interpretation

Conversion errors are not solution residuals, and this audit does not prove
that every FP32-assisted method would fail. It does show that wholesale
conversion changes source data, including operating bounds, and that plain
FP16 cannot even represent all finite costs. Scaling can address range but does
not by itself restore lost precision or certify the original model.

A scheduling relative optimality gap of 1e-3 is distinct from row/bound
feasibility tolerances; it does not authorize rounding model data to 0.1%.
Any future mixed-precision algorithm would need refinement and verification
against unchanged original Float64 inputs. Lossless compression/packing of
metadata or repeated coefficients is a separate possibility, but a compressed
disk representation alone does not shrink HiGHS' double-precision internals.

The current decision is to retain FP64 and target proven allocation/setup
bottlenecks. r06 cleared native presolve without a RAM stop but timed out in
MIP setup; this audit does not establish a complete 23,643-bus solution or that
all later optimization/AC stages fit in memory.
