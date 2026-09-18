# Tiny development tests only. Never accepts a competition-case path.
using Test, JSON
const DOM_GUARDS_ONLY = "--guards-only" in ARGS
if !DOM_GUARDS_ONLY
    @eval using JuMP, HiGHS
    include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
else
    include(joinpath(@__DIR__,"..","src","consumer_dominance.jl"))
end
const DOM_ROOT=abspath(joinpath(@__DIR__,".."))
const DOM_TINY=joinpath(DOM_ROOT,"tmp","official_tiny","problem.json")
@assert occursin("official_tiny",DOM_TINY)

# The guard-only path does not load or invoke any optimizer. Its immutable
# lookups contain the same raw fields as GO3.process_input_data.
function dominance_test_input(data)
    devices=data["network"]["simple_dispatchable_device"]
    series=data["time_series_input"]["simple_dispatchable_device"]
    general=data["time_series_input"]["general"]
    (dt=general["interval_duration"],periods=1:general["time_periods"],
        sdd_lookup=Dict(d["uid"]=>d for d in devices),
        sdd_ts_lookup=Dict(d["uid"]=>d for d in series),
        sdd_ids_consumer=sort([d["uid"] for d in devices if d["device_type"]=="consumer"]))
end

function dominance_fixture()
    data=JSON.parsefile(DOM_TINY)
    d=only(filter(x -> x["uid"]=="d",data["network"]["simple_dispatchable_device"]))
    ts=only(filter(x -> x["uid"]=="d",data["time_series_input"]["simple_dispatchable_device"]))
    nt=data["time_series_input"]["general"]["time_periods"]
    d["on_cost"]=0.0
    d["startup_cost"]=0.0
    d["shutdown_cost"]=0.0
    d["in_service_time_lb"]=0.0
    d["down_time_lb"]=0.0
    d["p_ramp_up_ub"]=8.0
    d["p_ramp_down_ub"]=8.0
    d["p_startup_ramp_ub"]=8.0
    d["p_shutdown_ramp_ub"]=8.0
    d["p_ramp_res_down_online_ub"]=0.5
    d["p_ramp_res_down_offline_ub"]=0.5
    ts["p_lb"]=zeros(nt)
    ts["on_status_lb"]=zeros(Int,nt)
    ts["q_lb"]=fill(-1.0,nt)
    ts["q_ub"]=fill(1.0,nt)
    ts["p_ramp_res_down_online_cost"]=fill(0.01,nt)
    ts["p_ramp_res_down_offline_cost"]=fill(0.02,nt)
    data,d,ts
end

@testset "GO3 consumer dominance guards" begin
    data,d,ts=dominance_fixture()
    inp=dominance_test_input(data)
    @test isempty(consumer_online_dominance_reasons(inp,"d"))
    @test consumer_online_dominance_reasons(inp,"g")==["not_a_consumer"]
    audit=consumer_online_dominance_audit(inp)
    @test audit["eligible_consumer_uids"]==["d"]
    @test audit["fixed_online_variables"]==3
    @test audit["generator_commitments_changed"]==0
    @test audit["source_values_changed"]==false
    for (key,bad,reason) in (
        ("on_cost",1e-14,"nonzero_online_cost"),
        ("startup_cost",-1e-14,"negative_transition_cost"),
        ("shutdown_cost",-1e-14,"negative_transition_cost"),
        ("q_bound_cap",1,"coupled_reactive_capability"),
        ("q_linear_cap",1,"coupled_reactive_capability"),
        ("p_ramp_up_ub",0.01,"online_ramp_up_can_restrict_dispatch"),
        ("p_ramp_down_ub",0.01,"online_ramp_down_can_restrict_dispatch"),
        ("p_shutdown_ramp_ub",0.01,"initial_shutdown_curve_can_be_nonzero"),
        ("p_startup_ramp_ub",0.0,"nonpositive_transition_ramp"),
        ("p_ramp_res_down_online_ub",0.1,"offline_down_reserve_capacity_is_larger"))
        raw,dev,_=dominance_fixture()
        dev[key]=bad
        @test reason in consumer_online_dominance_reasons(dominance_test_input(raw),"d")
    end
    for (key,bad,reason) in (
        ("p_lb",1e-14,"nonzero_source_pmin"),
        ("p_ub",-1e-14,"negative_source_pmax"),
        ("on_status_ub",0,"online_not_always_allowed"),
        ("q_lb",1e-14,"reactive_bounds_exclude_zero"),
        ("q_ub",-1e-14,"reactive_bounds_exclude_zero"),
        ("p_ramp_res_down_online_cost",0.03,"online_down_reserve_is_more_expensive"))
        raw,_,series=dominance_fixture()
        series[key][2]=bad
        @test reason in consumer_online_dominance_reasons(dominance_test_input(raw),"d")
    end
    raw,dev,_=dominance_fixture()
    dev["initial_status"]["on_status"]=0
    @test "not_initially_online" in consumer_online_dominance_reasons(dominance_test_input(raw),"d")
    raw,dev,_=dominance_fixture()
    dev["startup_states"]=[[1.0,2.0]]
    @test "special_startup_states" in consumer_online_dominance_reasons(dominance_test_input(raw),"d")
    # Unequal durations matter: a rate that covers a one-hour jump must still
    # be rejected when it cannot cover the 15-minute jump in this fixture.
    raw,dev,_=dominance_fixture()
    dev["p_ramp_up_ub"]=2.0
    @test "online_ramp_up_can_restrict_dispatch" in consumer_online_dominance_reasons(dominance_test_input(raw),"d")
end

if !DOM_GUARDS_ONLY
@testset "GO3 consumer dominance exhaustive tiny witness mapping" begin
    raw,_,_=dominance_fixture()
    source_copy=deepcopy(raw)
    inp=GO3.process_input_data(raw)
    original=source_balance_scheduling_model(inp)
    opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>10.0,
        "mip_rel_gap"=>1e-9,"primal_feasibility_tolerance"=>1e-9,
        "mip_feasibility_tolerance"=>1e-9,"output_flag"=>false)
    # Exhaust every load commitment pattern, not just the profitable all-on
    # optimum. All patterns are temporally allowed in this synthetic fixture.
    for mask in 0:7
        trial,refmap=copy_model(original)
        set_optimizer(trial,opt)
        for t in inp.periods
            on=(mask >> (t-1)) & 1
            fix(trial[:p_on_status]["d",t],on;force=true)
            if on==0
                # Exercise the actual offline-to-online reserve conversion.
                fix(trial[:p_rrd_off]["d",t],0.1;force=true)
            end
        end
        optimize!(trial)
        @test termination_status(trial)==MOI.OPTIMAL
        @test primal_status(trial)==MOI.FEASIBLE_POINT
        witness=Dict(v=>value(refmap[v]) for v in all_variables(original))
        before=JuMP.value(v->witness[v],objective_function(original))
        @test isempty(primal_feasibility_report(original,witness;atol=1e-8))
        for t in inp.periods
            witness[original[:p_on_status]["d",t]]=1.0
            witness[original[:u_su]["d",t]]=0.0
            witness[original[:u_sd]["d",t]]=0.0
            witness[original[:p_rrd_on]["d",t]] += witness[original[:p_rrd_off]["d",t]]
            witness[original[:p_rrd_off]["d",t]]=0.0
        end
        @test isempty(primal_feasibility_report(original,witness;atol=1e-8))
        after=JuMP.value(v->witness[v],objective_function(original))
        @test after >= before-1e-8
    end
    unrestricted,_=copy_model(original)
    reduced,_=copy_model(original)
    audit=apply_consumer_online_dominance!(reduced,inp)
    @test all(!is_fixed(reduced[:p_on_status]["g",t]) for t in inp.periods)
    @test all(is_fixed(reduced[:p_on_status]["d",t]) for t in inp.periods)
    for m in (unrestricted,reduced)
        set_optimizer(m,opt)
        optimize!(m)
        @test termination_status(m)==MOI.OPTIMAL
    end
    @test objective_value(reduced) ≈ objective_value(unrestricted) atol=1e-7
    @test raw==source_copy
end

@testset "GO3 consumer dominance fractional relaxation witnesses" begin
    raw,_,_=dominance_fixture()
    inp=GO3.process_input_data(raw)
    original=source_balance_scheduling_model(inp)
    relax_integrality(original)
    opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"time_limit"=>10.0,
        "primal_feasibility_tolerance"=>1e-9,"output_flag"=>false)
    for pattern in ([0.25,0.5,0.75],[0.75,0.25,0.5],[0.5,0.5,0.5])
        trial,refmap=copy_model(original)
        set_optimizer(trial,opt)
        for t in inp.periods
            fix(trial[:p_on_status]["d",t],pattern[t];force=true)
            fix(trial[:p_rrd_off]["d",t],0.1*(1-pattern[t]);force=true)
        end
        optimize!(trial)
        @test termination_status(trial)==MOI.OPTIMAL
        witness=Dict(v=>value(refmap[v]) for v in all_variables(original))
        before=JuMP.value(v->witness[v],objective_function(original))
        @test isempty(primal_feasibility_report(original,witness;atol=1e-8))
        for t in inp.periods
            witness[original[:p_on_status]["d",t]]=1.0
            witness[original[:u_su]["d",t]]=0.0
            witness[original[:u_sd]["d",t]]=0.0
            witness[original[:p_rrd_on]["d",t]] += witness[original[:p_rrd_off]["d",t]]
            witness[original[:p_rrd_off]["d",t]]=0.0
        end
        @test isempty(primal_feasibility_report(original,witness;atol=1e-8))
        @test JuMP.value(v->witness[v],objective_function(original)) >= before-1e-8
    end
    reduced,_=copy_model(original)
    apply_consumer_online_dominance!(reduced,inp)
    for m in (original,reduced)
        set_optimizer(m,opt)
        optimize!(m)
        @test termination_status(m)==MOI.OPTIMAL
    end
    @test objective_value(reduced) ≈ objective_value(original) atol=1e-7
end
end
