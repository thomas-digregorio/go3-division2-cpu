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
    m,s = schedule_source_balances(input;optimizer=opt,time_limit=15.0,set_silent=true)
    @test s !== nothing
    @test primal_status(m) == FEASIBLE_POINT
    @test length(s.on_status["g"]) == 3
    initial = candidate_from_schedule(input,s)
    @test initial["time_series_output"]["simple_dispatchable_device"][1]["on_status"] isa Vector
    awards = GOC3Benchmark.calculate_reserves_from_generation(input,initial;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>2.0))
    put_reserves!(initial,awards)
    @test all(isfinite,awards.p_rgu["g"])
    atomic_json(joinpath(mktempdir(joinpath(ROOT,"tmp")),"solver_tiny_schedule.json"),initial)
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

@testset "GO3 source penalty duration coefficients" begin
    data=JSON.parsefile(CASE)
    data["network"]["violation_cost"]["p_bus_vio_cost"]=10000.0
    data["network"]["violation_cost"]["q_bus_vio_cost"]=20000.0
    inp=GO3.process_input_data(data)
    model=source_balance_scheduling_model(inp)
    objective=objective_function(model)
    for t in inp.periods
        for symbol in (:p_balance_slack_pos,:p_balance_slack_neg)
            @test coefficient(objective,model[symbol][t]) == -inp.dt[t]*10000.0
        end
        for symbol in (:q_balance_slack_pos,:q_balance_slack_neg)
            @test coefficient(objective,model[symbol][t]) == -inp.dt[t]*20000.0
        end
    end
    @test inp.violation_cost["e_vio_cost"] == 1000.0
end

@testset "GO3 cheap slack cannot replace commitment" begin
    data=JSON.parsefile(CASE)
    data["network"]["violation_cost"]["e_vio_cost"]=0.01
    generator=data["network"]["simple_dispatchable_device"][1]
    generator["initial_status"]["on_status"]=0
    generator["initial_status"]["p"]=0.0
    generator["initial_status"]["accu_up_time"]=0.0
    generator["initial_status"]["accu_down_time"]=10.0
    # Isolate the energy-imbalance incentive: reserve requirements can otherwise
    # legitimately commit this unit even when the energy slack is underpriced.
    for zone in data["network"]["active_zonal_reserve"]
        for product in ("REG_UP","REG_DOWN","SYN","NSYN")
            zone[product]=0.0
        end
    end
    inp=GO3.process_input_data(data)
    opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"mip_rel_gap"=>1e-6,
        "mip_feasibility_tolerance"=>1e-9,"primal_feasibility_tolerance"=>1e-9)
    _,weak=GO3.schedule_power_copperplate(inp;optimizer=opt,time_limit=15.0,
        include_reserves=true,relax_balances=true,set_silent=true)
    model,corrected=schedule_source_balances(inp;optimizer=opt,time_limit=15.0,set_silent=true)
    @test all(weak.on_status["g"] .== 0)
    @test all(corrected.on_status["g"] .== 1)
    @test maximum(abs.(schedule_balance_summary(inp,model)["p_imbalance_pu"])) < 1e-8
    @test maximum(abs.(corrected.real_power["g"]-corrected.real_power["d"])) < 1e-8
end
