# Original tiny tests. Never reads a competition input or saved optimized point.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const FEATURE_TINY=joinpath(@__DIR__,"..","tmp","official_tiny","source_features_problem.json")
@assert occursin("official_tiny",FEATURE_TINY)

@testset "GO3 startup window exact half-open source membership" begin
    dt=[0.5,1.0,0.25,0.25]
    examples=[(0.0,1.5,[1,2]),(1.5,2.0,[3,4]),(0.0,0.0,Int[]),
        (2.0,2.0,Int[]),(1.5+5e-7,2.0,[3,4]),(0.0,1.5+5e-7,[1,2]),
        (0.0,1.5+2e-6,[1,2,3])]
    for (a,b,expected) in examples
        @test source_startup_window_members(dt,a,b)==expected
    end
    raw=JSON.parsefile(FEATURE_TINY)
    raw["network"]["simple_dispatchable_device"][1]["startups_ub"]=
        [[0.0,0.0,0],[0.0,1.75,1],[1.75,1.75,0]]
    original=deepcopy(raw)
    input=GO3.process_input_data(raw)
    saved=deepcopy(input.sdd_lookup)
    model=source_balance_scheduling_model(input;consumer_dominance=true)
    @test input.sdd_lookup==saved
    @test raw==original
    @test length(model[:source_maximum_startups])==5
    @test isempty(model[:max_starts_over_intervals])
    for ((uid,w),row) in model[:source_maximum_startups]
        a,b,count=input.sdd_lookup[uid]["startups_ub"][w]
        expected=source_startup_window_members(input.dt,a,b)
        @test normalized_rhs(row)==count
        for t in input.periods
            @test normalized_coefficient(row,model[:u_su][uid,t])==(t in expected ? 1.0 : 0.0)
        end
    end
    @test model.ext[:source_startup_windows]["source_values_changed"]===false
end

@testset "GO3 maximum startups cannot be repaired by soft balance" begin
    raw=JSON.parsefile(FEATURE_TINY)
    g=raw["network"]["simple_dispatchable_device"][1]
    g["initial_status"]["on_status"]=0
    g["initial_status"]["p"]=0.0
    g["initial_status"]["accu_up_time"]=0.0
    g["initial_status"]["accu_down_time"]=10.0
    g["in_service_time_lb"]=g["down_time_lb"]=0.0
    g["p_startup_ramp_ub"]=g["p_shutdown_ramp_ub"]=100.0
    for maximum in (1,2)
        g["startups_ub"]=[[0.0,1.75,maximum]]
        input=GO3.process_input_data(raw)
        model=source_balance_scheduling_model(input)
        for (t,status) in enumerate([1,0,1])
            fix(model[:p_on_status]["g",t],status;force=true)
        end
        set_optimizer(model,optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
            "mip_lp_solver"=>"simplex","time_limit"=>10.0,"output_flag"=>false))
        optimize!(model)
        @test termination_status(model)==(maximum==1 ? MOI.INFEASIBLE : MOI.OPTIMAL)
        @test get_optimizer_attribute(model,"mip_lp_solver")=="simplex"
        if maximum==2
            @test sum(value(model[:u_su]["g",t]) for t in input.periods)≈2.0
        end
    end
end

@testset "GO3 source P-Q capability survives scheduling and AC models" begin
    input=GO3.process_input_data(JSON.parsefile(FEATURE_TINY))
    m=source_balance_scheduling_model(input)
    for t in input.periods
        @test normalized_coefficient(m[:pq_ub_prod]["g",t],m[:q_qru]["g",t])==1.0
        @test normalized_coefficient(m[:pq_ub_prod]["g",t],m[:p]["g",t])==-0.1
        @test normalized_coefficient(m[:pq_lb_prod]["g",t],m[:q_qrd]["g",t])==-1.0
    end
end
