# Tiny synthetic tests only. No competition case or previous run is read.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 complete primal map and start-only projection" begin
    model=Model()
    @variable(model,0 <= x <= 4)
    @variable(model,0 <= shunt <= 3)
    @variable(model,offline == 0)
    point=(variables=all_variables(model),values=[4.1,1.4,-1e-12])
    fix(shunt,1.0;force=true)
    original_bounds=(lower_bound(x),upper_bound(x),fix_value(shunt),fix_value(offline))
    record=restore_complete_ac_primal!(model,point)
    @test record["complete"]===true
    @test record["variable_count"]==3
    @test record["accepted_interface_count"]==3
    @test record["bounds_adjusted_start_count"]==3
    @test record["source_bounds_changed"]===false
    @test record["external_solution_read"]===false
    @test start_value.([x,shunt,offline])==[4.0,1.0,0.0]
    @test original_bounds==(lower_bound(x),upper_bound(x),fix_value(shunt),fix_value(offline))
    @test point.values==[4.1,1.4,-1e-12]
    @test_throws ErrorException capture_complete_ac_primal(model)
    @test_throws ErrorException restore_complete_ac_primal!(model,
        (variables=point.variables,values=[NaN,1.0,0.0]))
    @test_throws ErrorException restore_complete_ac_primal!(model,
        (variables=reverse(point.variables),values=point.values))
    @variable(model,new_variable)
    @test_throws ErrorException restore_complete_ac_primal!(model,point)
end

@testset "GO3 native Ipopt consumes primal start and nonlinear residual audit" begin
    model=Model(optimizer_with_attributes(Ipopt.Optimizer,
        "max_iter"=>0,"print_level"=>0,"bound_relax_factor"=>0.0))
    @variable(model,x,start=3.0)
    @constraint(model,x^2 <= 16.0)
    @objective(model,Min,(x-7.0)^2)
    optimize!(model)
    @test termination_status(model)==MOI.ITERATION_LIMIT
    @test value(x)≈3.0 atol=1e-12
    point=capture_complete_ac_primal(model)
    @test point.values≈[3.0] atol=1e-12
    @test ac_primal_residual(model,point)==0.0
    @test ac_primal_residual(model,(variables=point.variables,values=[5.0]))≈9.0
    @test_throws ErrorException ac_primal_residual(model,
        (variables=point.variables,values=[Inf]))
    record=restore_complete_ac_primal!(model,(variables=point.variables,values=[2.0]))
    optimize!(model)
    @test value(x)≈2.0 atol=1e-12
    @test record["accepted_interface_count"]==1
end

@testset "GO3 fail-fast is residual-based and checkpoint precedes stop" begin
    metadata(res,status="TIME_LIMIT")=Dict("phases"=>[
        Dict("complete_finite_point"=>true,"max_primal_residual"=>res,"termination"=>status)])
    @test !ac_requires_stop(Dict(),false)
    @test_throws ErrorException ac_requires_stop(Dict(),true)
    @test !ac_requires_stop(metadata(0.0),true)
    @test !ac_requires_stop(metadata(1e-8),true)
    @test ac_requires_stop(metadata(1.001e-8,"LOCALLY_SOLVED"),true)
    @test ac_requires_stop(metadata(NaN),true)
    @test ac_requires_stop(metadata(nothing),true)
    @test ac_requires_stop(metadata(-1.0),true)
    input=GO3.process_input_data(JSON.parsefile(joinpath(@__DIR__,"..","tmp",
        "official_tiny","dominance_problem.json")))
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),
        reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
    results=opf_view(candidate_from_schedule(input,schedule),input.periods)
    # An intentionally unphysical tiny point is kept as evidence, not accepted.
    results[1]["bus"][first(input.bus_ids)]["vm"]=2.0
    out=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="ac_stop_fixture_")
    @test_throws ErrorException checkpoint_ac_interval!(out,input,schedule,results,1;must_stop=true)
    file=joinpath(out,"checkpoints","candidate_ac_0001.json")
    @test isfile(file)
    saved=JSON.parsefile(file)
    @test length(saved["time_series_output"]["bus"][1]["vm"])==3
    @test maximum(b["vm"][1] for b in saved["time_series_output"]["bus"])==2.0
    @test !isfile(joinpath(out,"candidate_final.json"))
end
