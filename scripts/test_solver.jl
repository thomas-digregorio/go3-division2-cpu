using Test, JSON, JuMP, HiGHS, Ipopt, GOC3Benchmark, LinearAlgebra
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const ROOT = abspath(joinpath(@__DIR__,".."))
const CASE = joinpath(ROOT,"tmp","official_tiny","problem.json")
# This path is generated only from tests/fixtures.py, never a competition case.
@assert occursin("official_tiny",CASE)
input = GOC3Benchmark.process_input_data(JSON.parsefile(CASE))
@testset "GO3 tiny whole-horizon UC" begin
    opt = optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"mip_rel_gap"=>1e-6,
        "mip_feasibility_tolerance"=>1e-9,"primal_feasibility_tolerance"=>1e-9)
    m,s = GOC3Benchmark.schedule_power_copperplate(input;optimizer=opt,time_limit=15.0,
        include_reserves=true,relax_balances=true,set_silent=true)
    @test s !== nothing
    @test primal_status(m) == FEASIBLE_POINT
    @test length(s.on_status["g"]) == 3
    initial = candidate_from_schedule(input,s)
    @test initial["time_series_output"]["simple_dispatchable_device"][1]["on_status"] isa Vector
    awards = GOC3Benchmark.calculate_reserves_from_generation(input,initial;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>2.0))
    put_reserves!(initial,awards)
    @test all(isfinite,awards.p_rgu["g"])
    atomic_json(joinpath(ROOT,"tmp","solver_tiny_schedule.json"),initial)
    model,sol = GOC3Benchmark.compute_optimal_power_flow_at_interval(input,s,1;
        optimizer=optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
            "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes","tol"=>1e-9,
            "constr_viol_tol"=>1e-9,"max_wall_time"=>15.0,"print_level"=>0),
        allow_switching=false,relax_power_balance=true,relax_thermal_limits=true,
        resolve_rounded_shunts=true,set_silent=true)
    @test has_values(model)
    @test all(isfinite(value(x)) for x in all_variables(model))
    @test haskey(sol,"bus")
    println("TINY_IPOPT_STATUS ",termination_status(model))
end
