# Third-party notices and source references

- GO2 source reference: Thomas DiGregorio's `gravityx-go2-cpp`, audited revision
  `b5433e9d8a8fd4a22ab7df33e5c78198ad6a1f7d`. No source files copied yet.
- GOC3Benchmark.jl: Robert Parker and Carleton Coffrin, Los Alamos National
  Laboratory; revision `588f3566ab29df240622a9a98c758af1bfc66bb1`.
  Upstream BSD-3 license is retained in the ignored, unmodified upstream checkout
  at `.cache/upstream/GOC3Benchmark.jl/LICENSE.md` and in the tracked
  `licenses/GOC3Benchmark.BSD-3.txt`. The project-owned `src/scheduling.jl`
  adapter calls the pinned model/extraction functions and adapts their objective
  coefficients without modifying the upstream checkout. The project-owned
  `src/reserve_ac.jl` follows the reserve rows in upstream `reserves.jl` and the
  two-solve shunt-rounding workflow in `opf.jl`; it uses their pinned helpers to
  co-optimize source reserve allocations inside each fixed-commitment AC solve.
  Reference: Parker and Coffrin, *Managing Power Balance
  and Reserve Feasibility in the AC Unit Commitment Problem*, 2024,
  https://doi.org/10.1016/j.epsr.2024.110670.
- GO-3-data-model: NREL/Alliance for Sustainable Energy LLC and Battelle Memorial
  Institute; revision `5472a2373f456cc7e9923cdd31be1d4345d9830f`.
  BSD-3 license retained in the ignored checkout's `LICENSE`.
- C3DataUtilities: Jesse Holzer/PNNL and GOCompetition, revision
  `bb5df337553b21ab8be89ae5f9106958541730d4`. No repository license file was found
  in this revision. It is downloaded as an unmodified, ignored external evaluator,
  **not redistributed or relicensed by this project**.
- Data and results: official GO Competition Challenge 3 Final Event resources
  published via OpenEI/OEDI submission 5997. Only one raw scenario is extracted;
  supplied solved POPs and competitor solutions are not used.
- Solver dependencies retain their upstream notices: HiGHS (MIT), Ipopt (EPL),
  MUMPS and JuMP/Julia dependencies according to their installed package licenses.
- The optional native setup guard patches HiGHS 1.15.1, upstream commit
  `04024d701f79feb8e2f18bc3df0dffc04ef05088`. The complete changes are retained in
  `patches/highs-1.15.1-setup-guard.patch`, with the upstream copyright and MIT
  license in `patches/HIGHS-LICENSE.txt`. The separately built local library is
  ignored, hash-bound by `manifests/native_highs_setup_guard_v1.json`, and does
  not replace the installed solver. Build tooling and its notices stay local;
  this repository does not redistribute native binaries or the toolchain.
- `patches/highs-1.15.1-root-memory-guard.patch` is a separate cumulative HiGHS
  patch adding an optional analytic-center opt-out and root timing markers on
  the same pinned MIT-licensed source. Its build manifest is
  `manifests/native_highs_root_memory_guard_v1.json`; the earlier patched build
  and the installed JLL remain unchanged.

This project is an independent prototype, not an original team's proprietary
solver or an official competition submission. Upstream comparison times do not
establish a laptop speedup.
