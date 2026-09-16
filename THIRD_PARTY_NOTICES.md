# Third-party notices and source references

- GO2 source reference: Thomas DiGregorio's `gravityx-go2-cpp`, audited revision
  `b5433e9d8a8fd4a22ab7df33e5c78198ad6a1f7d`. No source files copied yet.
- GOC3Benchmark.jl: Robert Parker and Carleton Coffrin, Los Alamos National
  Laboratory; revision `588f3566ab29df240622a9a98c758af1bfc66bb1`.
  Upstream BSD-3 license is retained in the ignored, unmodified upstream checkout
  at `.cache/upstream/GOC3Benchmark.jl/LICENSE.md`. Any future redistribution must
  include that full license. Reference: Parker and Coffrin, *Managing Power Balance
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

This project is an independent prototype, not an original team's proprietary
solver or an official competition submission. Upstream comparison times do not
establish a laptop speedup.
