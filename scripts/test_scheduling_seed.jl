using Test, JSON, JuMP, HiGHS, Ipopt, GOC3Benchmark
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const ROOT=abspath(joinpath(@__DIR__,".."))
const INPUT=GO3.process_input_data(JSON.parsefile(joinpath(ROOT,"tmp","official_tiny","source_features_problem.json")))
const OPT=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
    "mip_rel_gap"=>1e-6,"primal_feasibility_tolerance"=>1e-9,
    "mip_feasibility_tolerance"=>1e-9,"highs_analysis_level"=>128)
domain(v)=(is_binary(v),is_integer(v),is_fixed(v) ? fix_value(v) : nothing,
    has_lower_bound(v) ? lower_bound(v) : nothing,
    has_upper_bound(v) ? upper_bound(v) : nothing)

@testset "GO3 cold seed exact domain restoration including failure" begin
    m=Model(OPT);set_silent(m)
    @variable(m,b,Bin);set_lower_bound(b,0.2);set_upper_bound(b,1.0)
    @variable(m,-2<=j<=3,Int)
    @variable(m,f,Bin);fix(f,1.0;force=true)
    @variable(m,x>=0)
    @constraint(m,j+x==2)
    @objective(m,Max,b+j-x+f)
    optimize!(m)
    point=capture_scheduling_point(m)
    before=domain.(all_variables(m))
    @test audit_scheduling_point(m,point)["pass"]
    events=String[]
    observer=(name,details)->begin
        push!(events,name)
        if occursin("cache_edits",name)
            @test MOI.Utilities.state(backend(m))==MOI.Utilities.EMPTY_OPTIMIZER
            @test MOI.is_empty(backend(m).optimizer)
        end
    end
    with_fixed_scheduling_integers(m,point;on_event=observer) do
        @test !any(is_binary,all_variables(m))
        @test !any(is_integer,all_variables(m))
        @test all(is_fixed,[b,j,f])
        @test !is_fixed(x)
    end
    @test events==["fixed_pattern_native_detach_begin","fixed_pattern_cache_edits_begin",
        "fixed_pattern_cache_edits_complete","restore_native_detach_begin",
        "restore_cache_edits_begin","restore_cache_edits_complete"]
    @test domain.(all_variables(m))==before
    @test_throws ErrorException with_fixed_scheduling_integers(m,point) do
        error("Injected cost LP failure")
    end
    @test domain.(all_variables(m))==before
    bad=(;point...,values=copy(point.values));bad.values[point.positions[index(b).value]]=0.5
    @test !audit_scheduling_point(m,bad)["pass"]
    @test_throws ErrorException supply_scheduling_primal!(m,bad)
    @test_throws ErrorException with_fixed_scheduling_integers(()->nothing,m,bad)
    @test domain.(all_variables(m))==before
    other=Model();@variable(other,b)
    @test_throws ErrorException scheduling_point_value(point,b)
    @variable(m,hole);delete(m,hole);@variable(m,after_hole>=0)
    @test_throws ErrorException audit_scheduling_point(m,point)
    optimize!(m)
    @test audit_scheduling_point(m,capture_scheduling_point(m))["pass"]
    @test_throws ErrorException scheduling_set_residual(0.0,MOI.Semicontinuous(1.0,2.0))
end

@testset "GO3 cold seed source objective constraints and extraction" begin
    m=source_balance_scheduling_model(INPUT;include_reserves=true,consumer_dominance=true)
    original=objective_function(m)
    domains=domain.(all_variables(m))
    constraints=[string.(all_constraints(m,F,S)) for (F,S) in list_of_constraint_types(m)]
    set_optimizer(m,OPT);set_silent(m)
    solver_options=Dict(k=>get_optimizer_attribute(m,k) for k in
        ("solver","run_crossover","ipm_optimality_tolerance"))
    checkpoints=String[];events=String[]
    seed,records=construct_scheduling_seed!(m,INPUT;construction_seconds=15,cost_seconds=15,
        cost_lp_solver="ipx",on_seed=(p,a,label)->push!(checkpoints,label),
        on_event=(name,details)->begin
            push!(events,name)
            name=="cost_lp_solve_begin" && @test checkpoints==["online_commitment_construction"]
        end)
    @test seed!==nothing
    @test length(records)==2
    @test objective_function(m)==original
    @test objective_sense(m)==MOI.MAX_SENSE
    @test domain.(all_variables(m))==domains
    @test [string.(all_constraints(m,F,S)) for (F,S) in list_of_constraint_types(m)]==constraints
    audit=audit_scheduling_point(m,seed)
    @test audit["pass"]
    @test audit["constraints_including_bounds_and_integrality"]==num_constraints(m;count_variable_in_set_constraints=true)
    @test audit["maximum_residual"]≈maximum(values(primal_feasibility_report(v->scheduling_point_value(seed,v),m));init=0.0)
    start=supply_scheduling_primal!(m,seed)
    @test start["complete"]
    @test start["accepted_interface_count"]==num_variables(m)
    @test records[1]["objective_scope"]=="producer_online_hours_not_source_economics"
    @test records[2]["original_model_audit"]["pass"]
    @test records[2]["solver"]=="ipx"
    @test records[2]["run_crossover"]=="off"
    @test !records[2]["bound_and_gap_queried"]
    @test records[2]["bound"]===nothing
    @test records[2]["relative_gap"]===nothing
    @test records[2]["native_relative_gap"]===nothing
    @test all(get_optimizer_attribute(m,k)==v for (k,v) in solver_options)
    @test checkpoints==["online_commitment_construction","constructed_commitment_cost_lp"]
    @test findfirst(==("cost_lp_solve_returned"),events)<findfirst(==("restore_native_detach_begin"),events)
    @test get_optimizer_attribute(m,"highs_analysis_level")==128
    retained,retained_audit,origin=select_scheduling_point(seed,audit,nothing,nothing)
    @test retained===seed && retained_audit===audit && origin=="within_run_constructed_commitment"
    @test select_scheduling_point(seed,audit,seed,Dict("pass"=>false))[1]===seed
    @test select_scheduling_point(nothing,nothing,nothing,nothing)==(nothing,nothing,"none")
    # Re-solve only this tiny fixture to cross-check the project-owned extractor.
    optimize!(m)
    native=capture_scheduling_point(m)
    expected=GO3._process_schedule_data(INPUT,GO3.extract_data_from_scheduling_model(INPUT,m;include_reserves=true))
    @test schedule_at_scheduling_point(INPUT,m,native)==expected
    @test schedule_balance_summary(INPUT,m;getter=v->scheduling_point_value(native,v))==schedule_balance_summary(INPUT,m)
end

@testset "GO3 cold scheduling native start evidence and zero-budget retention" begin
    dir=mktempdir(joinpath(ROOT,"tmp"))
    phases=Any[];checkpoints=Any[]
    m,s=schedule_source_balances(INPUT;optimizer=OPT,time_limit=15,
        consumer_dominance=true,seed_policy=SCHEDULING_SEED_POLICY,
        construction_seconds=15,cost_seconds=15,cost_lp_solver="ipx",native_log_path=joinpath(dir,"native.log"),
        on_phase=r->push!(phases,r),on_seed=(s,a,label)->push!(checkpoints,(;s,a,label)))
    @test s!==nothing
    @test length(phases)==3
    @test length(checkpoints)==2 && all(c.a["pass"] for c in checkpoints)
    @test checkpoints[1].label=="online_commitment_construction"
    seed=m.ext[:scheduling_formulation]["cold_construction"]
    @test seed["mip_start"]["native_acceptance"]=="native_log_confirms_feasible_start"
    @test m.ext[:selected_schedule_audit]["pass"]
    @test all(is_binary,m[:p_on_status])
    @test get_optimizer_attribute(m,"solver")=="choose"
    # A zero-budget native solve may immediately accept the supplied point.
    # Either way, it must not erase it or import the restricted LP's bound.
    short=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"presolve"=>"off",
        "primal_feasibility_tolerance"=>1e-9,"mip_feasibility_tolerance"=>1e-9)
    m,s=schedule_source_balances(INPUT;optimizer=short,time_limit=0.0,set_silent=true,
        consumer_dominance=true,seed_policy=SCHEDULING_SEED_POLICY,
        construction_seconds=15,cost_seconds=15)
    @test s!==nothing
    @test m.ext[:selected_schedule_audit]["pass"]
    @test m.ext[:selected_schedule_audit]["origin"] in
        ("within_run_constructed_commitment","original_economic_mip")
    @test termination_status(m)==MOI.TIME_LIMIT
    @test all(is_binary,m[:p_on_status])
    @test_throws ErrorException schedule_source_balances(INPUT;optimizer=OPT,time_limit=1,
        seed_policy=SCHEDULING_SEED_POLICY,include_reserves=false,
        construction_seconds=1,cost_seconds=1)
end

@testset "GO3 restricted IPX LP native proof and timeout restoration" begin
    # Nontrivial tiny LP proves the installed IPX path actually executes.
    m=Model(OPT)
    ipx_log=joinpath(mktempdir(joinpath(ROOT,"tmp")),"ipx.log")
    set_optimizer_attribute(m,"log_file",ipx_log)
    set_optimizer_attribute(m,"log_to_console",false)
    set_optimizer_attribute(m,"presolve","off")
    set_optimizer_attribute(m,"solver","ipx")
    set_optimizer_attribute(m,"run_crossover","off")
    set_optimizer_attribute(m,"ipm_optimality_tolerance",1e-10)
    @variable(m,0<=x[1:3]<=10)
    @constraint(m,2x[1]+x[2]>=3)
    @constraint(m,x[2]+3x[3]>=4)
    @objective(m,Min,sum(x))
    optimize!(m)
    @test termination_status(m)==MOI.OPTIMAL
    @test MOI.get(m,MOI.BarrierIterations())>0
    @test occursin("IPX",read(ipx_log,String))
    @test !occursin("Running HiPO",read(ipx_log,String))
    @test audit_scheduling_point(m,capture_scheduling_point(m))["pass"]
    m=source_balance_scheduling_model(INPUT;include_reserves=true,consumer_dominance=true)
    set_optimizer(m,OPT);set_silent(m)
    set_optimizer_attribute(m,"presolve","off")
    before=domain.(all_variables(m));checkpoints=String[]
    point,records=construct_scheduling_seed!(m,INPUT;construction_seconds=15,
        cost_seconds=1e-12,cost_lp_solver="ipx",
        on_seed=(p,a,label)->push!(checkpoints,label))
    @test point!==nothing
    @test records[2]["termination"]=="TIME_LIMIT"
    @test records[2]["primal_status"]!="FEASIBLE_POINT"
    @test !records[2]["bound_and_gap_queried"]
    @test checkpoints==["online_commitment_construction"]
    @test audit_scheduling_point(m,point)["pass"]
    @test domain.(all_variables(m))==before
    @test get_optimizer_attribute(m,"solver")=="choose"
    @test get_optimizer_attribute(m,"run_crossover")=="on"
    @test MOI.Utilities.state(backend(m))==MOI.Utilities.EMPTY_OPTIMIZER
end
