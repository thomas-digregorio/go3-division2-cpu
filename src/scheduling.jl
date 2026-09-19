# Project-owned adapter; pinned upstream code and source penalties are untouched.
function source_balance_scheduling_model(input; include_reserves::Bool=true,
        consumer_dominance::Bool=false)
    model = GO3.get_copperplate_scheduling_model(without_upstream_startup_windows(input);
        include_reserves=include_reserves,relax_balances=true,relax_reserves=true,
        overcommitment_factor=1.0)
    original = objective_function(model)
    for (symbol, source_key) in ((:p_balance_slack_pos,"p_bus_vio_cost"),
            (:p_balance_slack_neg,"p_bus_vio_cost"),
            (:q_balance_slack_pos,"q_bus_vio_cost"),
            (:q_balance_slack_neg,"q_bus_vio_cost"))
        for t in input.periods
            variable=model[symbol][t]
            # Guard the precise pinned upstream objective structure before adapting it.
            coefficient(original,variable)==-input.violation_cost["e_vio_cost"] ||
                error("Unexpected upstream aggregate-balance penalty; stop rather than guess")
            set_objective_coefficient(model,variable,-input.dt[t]*input.violation_cost[source_key])
        end
    end
    add_source_startup_windows!(model,input)
    consumer_dominance && apply_consumer_online_dominance!(model,input)
    model
end

function schedule_source_balances(input;optimizer,time_limit,set_silent=false,
        include_reserves::Bool=true,consumer_dominance::Bool=false,
        storage_policy="cached_model_v1",
        seed_policy="off",construction_seconds=0,cost_seconds=0,cost_lp_solver="simplex",deadline=Inf,
        native_log_path=nothing,on_phase=record->nothing,
        on_seed=(schedule,audit,label)->nothing,on_event=(name,details)->nothing)
    seed_policy in ("off",SCHEDULING_SEED_POLICY) || error("Unknown scheduling seed policy")
    storage_policy in SCHEDULING_STORAGE_POLICIES || error("Unknown scheduling storage policy")
    storage_policy=="native_handoff_v1" && seed_policy!="off" &&
        error("Native handoff is supported only for the original cold scheduling route")
    if seed_policy!= "off"
        include_reserves || error("Cold construction must retain joint source reserves")
        all(x->isfinite(x) && x>0,(construction_seconds,cost_seconds)) ||
            error("Cold construction requires positive finite phase budgets")
    end
    started=time()
    model=source_balance_scheduling_model(input;include_reserves=include_reserves,
        consumer_dominance=consumer_dominance)
    model.ext[:scheduling_formulation]=Dict(
        "include_reserves"=>include_reserves,
        "build_seconds"=>time()-started,
        "variables"=>num_variables(model),
        "constraints_excluding_variable_bounds"=>num_constraints(model;count_variable_in_set_constraints=false),
        "reserve_policy"=>include_reserves ? "joint_scheduling_then_full_reallocation" :
            "candidate_schedule_only_then_full_reserve_allocation_and_evaluation")
    model.ext[:scheduling_formulation]["source_startup_windows"]=model.ext[:source_startup_windows]
    model.ext[:scheduling_formulation]["source_pq_bound_devices"]=
        count(u->input.sdd_lookup[u]["q_bound_cap"]==1,input.sdd_ids)
    if consumer_dominance
        model.ext[:scheduling_formulation]["consumer_online_dominance"]=
            model.ext[:consumer_online_dominance]
    end
    println("GO3_SCHEDULING_MODEL ",JSON.json(model.ext[:scheduling_formulation])); flush(stdout)
    on_event("model_built",Dict("build_seconds"=>time()-started))
    if storage_policy=="native_handoff_v1"
        on_event("native_handoff_begin",Dict("variables"=>num_variables(model)))
        model=native_scheduling_handoff!(model,optimizer)
        gc_started=time()
        GC.gc(true)
        model.ext[:scheduling_storage]["post_handoff_gc_seconds"]=time()-gc_started
        on_event("native_handoff_complete",model.ext[:scheduling_storage])
    else
        set_optimizer(model,optimizer)
    end
    set_time_limit_sec(model,time_limit)
    set_silent && JuMP.set_silent(model)
    best=nothing
    seed_audit=nothing
    if seed_policy!= "off"
        best,phases=construct_scheduling_seed!(model,input;
            construction_seconds=construction_seconds,cost_seconds=cost_seconds,
            cost_lp_solver=cost_lp_solver,deadline=deadline,on_phase=on_phase,on_event=on_event,
            on_seed=(point,audit,label)->on_seed(schedule_at_scheduling_point(input,model,point;
                include_reserves=include_reserves),audit,label))
        model.ext[:scheduling_formulation]["cold_construction"]=Dict(
            "policy"=>seed_policy,"phases"=>phases,"external_initialization"=>false)
        if best!==nothing
            seed_audit=audit_scheduling_point(model,best)
        end
        # Start a fresh native MIP with all original domains/costs. Do not carry
        # the restricted LP's basis, bound, or integrality relaxation into it.
        set_optimizer(model,optimizer)
        get_optimizer_attribute(model,"solver")=="choose" || error("Economic MIP inherited an LP-only solver")
        set_silent && JuMP.set_silent(model)
        if native_log_path!==nothing
            occursin("onedrive",lowercase(abspath(native_log_path))) && error("OneDrive log forbidden")
            isfile(native_log_path) && error("Native scheduling log already exists")
            mkpath(dirname(native_log_path))
            set_optimizer_attribute(model,"log_file",abspath(native_log_path))
        end
        if best!==nothing
            on_event("economic_mip_start_audit_begin",Dict())
            start=supply_scheduling_primal!(model,best)
            model.ext[:scheduling_formulation]["cold_construction"]["mip_start"]=start
            println("GO3_SCHEDULING_START ",JSON.json(start));flush(stdout)
            on_event("economic_mip_start_ready",Dict("variable_count"=>start["variable_count"]))
        end
        set_time_limit_sec(model,max(0.0,min(Float64(time_limit),deadline-time()-1.0)))
    end
    # No saved starts, preceding pilot data, or external optimized solution.
    economic_started=time()
    on_event("economic_solve_begin",Dict())
    optimize!(model)
    on_event("economic_solve_returned",Dict("wall_seconds"=>time()-economic_started))
    schedule=nothing
    if seed_policy!= "off"
        native_stats=merge(model_stats(model),Dict("phase"=>"original_economic_mip",
            "wall_seconds"=>time()-economic_started))
        on_phase(native_stats)
        construction=model.ext[:scheduling_formulation]["cold_construction"]
        construction["economic_mip"]=native_stats
        if haskey(construction,"mip_start") && native_log_path!==nothing && isfile(native_log_path)
            lines=filter(line->occursin("MIP start",line) || occursin("supplied solution",lowercase(line)),
                readlines(native_log_path))
            construction["mip_start"]["native_log_evidence"]=lines
            construction["mip_start"]["native_acceptance"]=any(
                line->occursin("mip start solution is feasible",lowercase(line)),lines) ?
                "native_log_confirms_feasible_start" : "not_confirmed_by_native_log"
        end
        best!==nothing && termination_status(model)==MOI.INFEASIBLE &&
            error("Native MIP infeasibility contradicts audited original-model seed")
        native=nothing
        audit=nothing
        if primal_status(model)==FEASIBLE_POINT
            native=capture_scheduling_point(model)
            audit=audit_scheduling_point(model,native)
            construction["native_returned_point_audit"]=audit
        end
        best,seed_audit,origin=select_scheduling_point(best,seed_audit,native,audit)
        if best!==nothing
            model.ext[:selected_schedule_audit]=merge(seed_audit,Dict("origin"=>origin))
            model.ext[:selected_schedule_balance]=schedule_balance_summary(input,model;
                getter=v->scheduling_point_value(best,v))
            schedule=schedule_at_scheduling_point(input,model,best;include_reserves=include_reserves)
        end
        return model,schedule
    end
    if primal_status(model)==FEASIBLE_POINT
        schedule=GO3.extract_data_from_scheduling_model(input,model;include_reserves=include_reserves)
        schedule=GO3._process_schedule_data(input,schedule)
    end
    model,schedule
end

function schedule_balance_summary(input,model;getter=value)
    Dict("policy"=>"source_P_Q_bus_penalties_times_interval_duration",
        "source_p_penalty"=>input.violation_cost["p_bus_vio_cost"],
        "source_q_penalty"=>input.violation_cost["q_bus_vio_cost"],
        "p_imbalance_pu"=>[getter(model[:p_balance_slack_pos][t])-getter(model[:p_balance_slack_neg][t]) for t in input.periods],
        "q_imbalance_pu"=>[getter(model[:q_balance_slack_pos][t])-getter(model[:q_balance_slack_neg][t]) for t in input.periods],
        "penalty_cost"=>sum(input.dt[t]*(
            input.violation_cost["p_bus_vio_cost"]*(getter(model[:p_balance_slack_pos][t])+getter(model[:p_balance_slack_neg][t]))+
            input.violation_cost["q_bus_vio_cost"]*(getter(model[:q_balance_slack_pos][t])+getter(model[:q_balance_slack_neg][t]))) for t in input.periods))
end
