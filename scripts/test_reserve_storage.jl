# Original tiny fixtures only; storage lifetime must not alter the LP results.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 bounded reserve storage preserves all numeric upstream awards" begin
    for state in ("online","offline_interval")
        raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dc_problem.json"))
        original=deepcopy(raw)
        input=GO3.process_input_data(raw)
        schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
            real_power=Dict(u=>ones(3) for u in input.sdd_ids),
            reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
        solution=candidate_from_schedule(input,schedule)
        if state=="offline_interval"
            g=only(x for x in solution["time_series_output"]["simple_dispatchable_device"] if x["uid"]=="g")
            g["on_status"]=[1,0,1]
            g["p_on"]=[0.8,0.0,0.9]
        end
        saved=deepcopy(solution)
        saved_input=deepcopy(input)
        opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>5.0,
            "primal_feasibility_tolerance"=>1e-9,"output_flag"=>false)
        reference=GO3.calculate_reserves_from_generation(input,solution;optimizer=opt)
        events=Any[]; factory_calls=Int[]
        bounded,audit=source_reserve_allocation(input,solution;policy="bounded_lifetime_v1",
            optimizer_for_interval=i->(push!(factory_calls,i); opt),
            interval_callback=info->push!(events,deepcopy(info)))
        @test keys(bounded)==keys(reference)
        @test factory_calls==[1,2,3]
        for field in RESERVE_STORAGE_FIELDS, uid in input.sdd_ids
            @test getproperty(bounded,field)[uid]≈getproperty(reference,field)[uid] atol=1e-12 rtol=0
            @test eltype(getproperty(bounded,field)[uid])==Float64
        end
        @test length(events)==3
        @test all(x["model_released"] for x in events)
        @test audit["all_models_released"]
        @test audit["maximum_live_interval_models"]==1
        @test audit["intervals_completed"]==audit["intervals_required"]==3
        @test audit["rows_or_columns_eliminated"]==0
        @test !audit["source_values_changed"]
        @test audit["upstream_interval_model_unchanged"]
        @test audit["upstream_projection_unchanged"]
        @test raw==original && input==saved_input && solution==saved
        # Legacy remains the default, including one optimizer configuration for
        # the entire upstream horizon wrapper, so old registrations stay intact.
        legacy_calls=Int[]
        legacy,old_audit=source_reserve_allocation(input,solution;
            optimizer_for_interval=i->(push!(legacy_calls,i); opt))
        @test legacy_calls==[0]
        @test legacy==reference
        @test old_audit["policy"]=="legacy_horizon_v1"
    end
end

@testset "GO3 bounded reserve storage rechecks budget before each interval" begin
    input=GO3.process_input_data(JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dc_problem.json")))
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),
        reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
    solution=candidate_from_schedule(input,schedule)
    calls=Int[]; events=Any[]
    function budgeted_optimizer(i)
        push!(calls,i)
        i==2 && error("Synthetic exhausted global budget; do not solve a second LP")
        optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>5.0,"output_flag"=>false)
    end
    @test_throws ErrorException source_reserve_allocation(input,solution;policy="bounded_lifetime_v1",
        optimizer_for_interval=budgeted_optimizer,interval_callback=x->push!(events,deepcopy(x)))
    @test calls==[1,2]
    @test length(events)==1 && events[1]["model_released"]
    @test_throws ErrorException source_reserve_allocation(input,solution;policy="drop_source_reserves")
    duplicate=deepcopy(solution)
    push!(duplicate["time_series_output"]["simple_dispatchable_device"],
        deepcopy(first(duplicate["time_series_output"]["simple_dispatchable_device"])))
    @test_throws ErrorException source_reserve_allocation(input,duplicate;policy="bounded_lifetime_v1")
end
