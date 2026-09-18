using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 current-hour block identity and within-run AC continuation" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    for ts in raw["time_series_input"]["simple_dispatchable_device"]
        ts["cost"][2]=ts["uid"]=="g" ? [[10.0,1.0],[20.0,2.0]] : [[1000.0,0.3],[900.0,1.7]]
        if ts["uid"]=="d"
            ts["p_ub"][2]=0.6
        end
    end
    original=deepcopy(raw)
    input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids))
    curves=fixed_schedule_power_curves(input,schedule)
    opt=optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes","tol"=>1e-9,
        "constr_viol_tol"=>1e-9,"max_wall_time"=>15.0,"max_iter"=>500,"print_level"=>0)
    seed=nothing
    for i in input.periods
        m,sol=compute_reserve_aware_ac(deepcopy(input),input,i;
            on_status=Dict(u=>1 for u in input.sdd_ids),
            real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves,
            optimizer=opt,set_silent=true,shunt_primal_start="within_interval_primal_dual_v1",
            audit_phases=true,rounded_seconds=15.0,interval_seed=seed)
        @test !ac_requires_stop(m.ext[:reserve_ac],true)
        @test raw==original
        record=m.ext[:reserve_ac]["interval_primal_start"]
        if i==1
            @test record["policy"]=="cold_defaults"
        else
            @test record["source_interval"]==i-1
            @test record["complete_current_primal_vector"]===true
            @test record["reused_named_values"]>0
            @test record["current_variable_count"]==num_variables(m)
            @test record["external_solution_read"]===false
            @test record["source_bounds_changed"]===false
            @test record["dual_start"]===false
            @test isfinite(record["start_model_residual"])
        end
        blocks=ac_cost_block_map(m,input,i)
        @test Set(keys(blocks))==Set(["g","d"])
        if i==2
            @test length(blocks["g"])==2 && length(blocks["d"])==2
            @test record["bounds_adjusted_starts"]>0
            @test upper_bound(m[:p_sdd]["d"])==0.6
        end
        seed=capture_ac_interval_start(m,input,i)
        @test seed.interval==i
        @test seed.source_residual<=1e-8
        @test all(isfinite,values(seed.named))
        @test all(!isempty(k) for k in keys(seed.named))
        @test_throws ErrorException apply_ac_interval_start!(m,input,i,seed,
            Dict(u=>1.0 for u in input.sdd_ids))
    end
    @test raw==original
end

@testset "GO3 continuation refuses unknown economic variable identity" begin
    input=GO3.process_input_data(JSON.parsefile(joinpath(@__DIR__,"..","tmp",
        "official_tiny","dominance_problem.json")))
    m=Model()
    @variable(m,p_sdd[u in ["g","d"]]>=0)
    @objective(m,Max,p_sdd["d"]-p_sdd["g"])
    @test_throws ErrorException ac_cost_block_map(m,input,1)
    @test_throws ErrorException apply_ac_interval_start!(m,input,2,
        (interval=1,named=Dict("x"=>NaN),source_residual=0.0),Dict())
    @test_throws ErrorException apply_ac_interval_start!(m,input,2,
        (interval=1,named=Dict("x"=>0.0),source_residual=1e-4),Dict())
end
