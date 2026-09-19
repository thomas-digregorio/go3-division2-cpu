# Only original synthetic fixtures; never constructs a competition model.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const STORAGE_TINY=joinpath(@__DIR__,"..","tmp","official_tiny","source_features_problem.json")
@assert occursin("official_tiny",STORAGE_TINY)
const STORAGE_OPT=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
    "mip_rel_gap"=>1e-6,"primal_feasibility_tolerance"=>1e-9,
    "mip_feasibility_tolerance"=>1e-9,"mip_lp_solver"=>"simplex","output_flag"=>false)

function assert_exact_native_copy(old,new,index_map)
    src=backend(old);dest=backend(new)
    @test MOI.get(src,MOI.ObjectiveSense())==MOI.get(dest,MOI.ObjectiveSense())
    F=MOI.get(src,MOI.ObjectiveFunctionType())
    @test MOI.Utilities.map_indices(index_map,MOI.get(src,MOI.ObjectiveFunction{F}()))≈
        MOI.get(dest,MOI.ObjectiveFunction{F}()) atol=0.0 rtol=0.0
    for (F,S) in MOI.get(src,MOI.ListOfConstraintTypesPresent())
        for ci in MOI.get(src,MOI.ListOfConstraintIndices{F,S}())
            @test MOI.get(src,MOI.ConstraintSet(),ci)==MOI.get(dest,MOI.ConstraintSet(),index_map[ci])
            original=MOI.Utilities.map_indices(index_map,MOI.get(src,MOI.ConstraintFunction(),ci))
            actual=MOI.get(dest,MOI.ConstraintFunction(),index_map[ci])
            @test original≈actual atol=0.0 rtol=0.0
        end
    end
end

@testset "GO3 native scheduling production route and ownership guards" begin
    input=GO3.process_input_data(JSON.parsefile(STORAGE_TINY))
    events=Any[]
    native,schedule=schedule_source_balances(input;optimizer=STORAGE_OPT,time_limit=15.0,
        consumer_dominance=true,storage_policy="native_handoff_v1",set_silent=true,
        on_event=(name,details)->push!(events,(name,details)))
    @test mode(native)==DIRECT
    @test schedule!==nothing
    @test termination_status(native)==MOI.OPTIMAL
    @test native.ext[:scheduling_storage]["cached_model_emptied"]
    @test native.ext[:scheduling_storage]["post_handoff_gc_seconds"]>=0
    @test [name for (name,_) in events]==["model_built","native_handoff_begin",
        "native_handoff_complete","economic_solve_begin","economic_solve_returned"]
    @test length(schedule.p_rgu)==length(input.sdd_ids)
    @test !haskey(native.ext,:selected_schedule_audit)
    @test !haskey(native.ext[:scheduling_formulation],"cold_construction")
    cached=source_balance_scheduling_model(input)
    cached.ext[:accidental_old_reference]=cached[:p]["g",1]
    @test_throws ErrorException native_scheduling_handoff!(cached,STORAGE_OPT)
    @test num_variables(cached)>0 # Failed copy cannot discard the original.
end

@testset "GO3 exact scheduling native handoff with complete domains" begin
    raw=JSON.parsefile(STORAGE_TINY); saved=deepcopy(raw)
    input=GO3.process_input_data(raw)
    for reserves in (false,true)
        original=source_balance_scheduling_model(input;include_reserves=reserves,consumer_dominance=true)
        count_before=num_variables(original)
        native=native_scheduling_handoff!(original,STORAGE_OPT;on_copied=assert_exact_native_copy)
        @test raw==saved
        @test num_variables(original)==0
        @test isempty(original.ext)
        @test mode(native)==DIRECT
        @test num_variables(native)==count_before
        @test native.ext[:scheduling_storage]["rows_or_columns_eliminated"]==0
        @test !haskey(object_dictionary(native),:cost_block_p) # Columns remain in native model.
        @test get_optimizer_attribute(native,"mip_lp_solver")=="simplex"
        set_time_limit_sec(native,15.0); optimize!(native)
        @test termination_status(native)==MOI.OPTIMAL
        baseline,schedule=schedule_source_balances(input;optimizer=STORAGE_OPT,time_limit=15.0,
            include_reserves=reserves,consumer_dominance=true,set_silent=true)
        @test objective_value(native)≈objective_value(baseline) atol=1e-7 rtol=1e-10
        extracted=GO3.extract_data_from_scheduling_model(input,native;include_reserves=reserves)
        @test all(all(isfinite,values) for values in values(extracted.real_power))
        @test length(extracted.on_status)==length(input.sdd_ids)
        @test schedule_balance_summary(input,native)["penalty_cost"]≈
            schedule_balance_summary(input,baseline)["penalty_cost"] atol=1e-8
        @test model_stats(native)["relative_gap"]<=1e-6
    end
end

@testset "GO3 native scheduling handoff does not hide infeasibility" begin
    raw=JSON.parsefile(STORAGE_TINY)
    g=raw["network"]["simple_dispatchable_device"][1]
    g["initial_status"]["on_status"]=0;g["initial_status"]["p"]=0.0
    g["initial_status"]["accu_up_time"]=0.0;g["initial_status"]["accu_down_time"]=10.0
    g["in_service_time_lb"]=g["down_time_lb"]=0.0
    g["p_startup_ramp_ub"]=g["p_shutdown_ramp_ub"]=100.0
    g["startups_ub"]=[[0.0,1.75,1]]
    input=GO3.process_input_data(raw)
    cached=source_balance_scheduling_model(input)
    for (t,status) in enumerate([1,0,1])
        fix(cached[:p_on_status]["g",t],status;force=true)
    end
    native=native_scheduling_handoff!(cached,STORAGE_OPT;on_copied=assert_exact_native_copy)
    set_time_limit_sec(native,15.0);optimize!(native)
    @test termination_status(native)==MOI.INFEASIBLE
    @test model_stats(native)["objective"]===nothing
    @test_throws ErrorException native_scheduling_handoff!(native,STORAGE_OPT)
    @test_throws ErrorException schedule_source_balances(input;optimizer=STORAGE_OPT,time_limit=1,
        storage_policy="unknown")
    @test_throws ErrorException schedule_source_balances(input;optimizer=STORAGE_OPT,time_limit=1,
        storage_policy="native_handoff_v1",seed_policy=SCHEDULING_SEED_POLICY)
end
