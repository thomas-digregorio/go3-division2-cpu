using Test, JSON, JuMP, HiGHS, Ipopt, GOC3Benchmark, LinearAlgebra
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const ROOT = abspath(joinpath(@__DIR__,".."))
const CASE = joinpath(ROOT,"tmp","official_tiny","problem.json")
# This path is generated only from tests/fixtures.py, never a competition case.
@assert occursin("official_tiny",CASE)
input = GOC3Benchmark.process_input_data(JSON.parsefile(CASE))
@testset "GO3 CPU HiPO backend and root option" begin
    # Presolve is disabled only on these three-variable synthetic probes, so
    # acceptance of an option alone cannot masquerade as an available backend.
    lp=Model(optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
        "solver"=>"hipo","presolve"=>"off","ipm_optimality_tolerance"=>1e-9,
        "time_limit"=>15.0))
    @variable(lp,0 <= x[1:3] <= 1)
    @constraint(lp,[i=1:3],x[i]+x[mod1(i+1,3)] >= 1)
    @objective(lp,Min,sum(x))
    optimize!(lp)
    @test termination_status(lp)==MOI.OPTIMAL
    @test objective_value(lp) ≈ 1.5 atol=1e-8
    @test MOI.get(lp,MOI.BarrierIterations()) > 0
    @test get_optimizer_attribute(lp,"solver")=="hipo"
    mip=Model(optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
        "mip_lp_solver"=>"hipo","presolve"=>"off","time_limit"=>15.0))
    @variable(mip,y[1:3],Bin)
    @constraint(mip,[i=1:3],y[i]+y[mod1(i+1,3)] >= 1)
    @objective(mip,Min,sum(y))
    optimize!(mip)
    @test termination_status(mip)==MOI.OPTIMAL
    @test objective_value(mip) ≈ 2.0 atol=1e-8
    @test get_optimizer_attribute(mip,"mip_lp_solver")=="hipo"
end

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

@testset "GO3 separated reserve candidate scheduling" begin
    joint=source_balance_scheduling_model(input)
    separated=source_balance_scheduling_model(input;include_reserves=false)
    @test num_variables(separated) < num_variables(joint)
    @test num_constraints(separated;count_variable_in_set_constraints=false) <
        num_constraints(joint;count_variable_in_set_constraints=false)
    @test count(is_binary,all_variables(separated)) == count(is_binary,all_variables(joint))
    @test !haskey(object_dictionary(separated),:p_rgu)
    @test haskey(object_dictionary(joint),:p_rgu)
    # All shared temporal constraints and balances are literally the same.
    for symbol in (:on_status_evolution,:prohibit_su_sd,:min_up,:min_dn,
            :ramp_ub,:ramp_lb,:copperplate_p_balance,:copperplate_q_balance)
        @test string.(separated[symbol]) == string.(joint[symbol])
    end
    original_data=JSON.parsefile(CASE)
    source_copy=deepcopy(original_data)
    inp=GO3.process_input_data(original_data)
    opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"mip_rel_gap"=>1e-6,
        "mip_feasibility_tolerance"=>1e-9,"primal_feasibility_tolerance"=>1e-9)
    m,s=schedule_source_balances(inp;optimizer=opt,time_limit=15.0,set_silent=true,
        include_reserves=false)
    @test s !== nothing
    @test !hasproperty(s,:p_rgu)
    @test all(inp.sdd_ts_lookup[uid]["p_lb"][t]*s.on_status[uid][t]-1e-8 <=
        value(m[:p_on][uid,t]) <= inp.sdd_ts_lookup[uid]["p_ub"][t]*s.on_status[uid][t]+1e-8
        for uid in inp.sdd_ids for t in inp.periods)
    candidate=candidate_from_schedule(inp,s)
    awards=GO3.calculate_reserves_from_generation(inp,candidate;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>2.0))
    put_reserves!(candidate,awards)
    @test sum(awards.p_rgu["g"]) > 0.0
    @test all(hasproperty(awards,k) for k in (:p_rgu,:p_rgd,:p_scr,:p_nsc,
        :p_rru_on,:p_rrd_on,:p_rru_off,:p_rrd_off,:q_qru,:q_qrd))
    @test original_data == source_copy
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
    _,separated=schedule_source_balances(inp;optimizer=opt,time_limit=15.0,
        set_silent=true,include_reserves=false)
    @test all(separated.on_status["g"] .== 1)
end
