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
        include_reserves::Bool=true,consumer_dominance::Bool=false)
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
    set_optimizer(model,optimizer)
    set_time_limit_sec(model,time_limit)
    set_silent && JuMP.set_silent(model)
    # No saved starts, no preceding pilot data, no external optimized solution.
    optimize!(model)
    schedule=nothing
    if primal_status(model)==FEASIBLE_POINT
        schedule=GO3.extract_data_from_scheduling_model(input,model;include_reserves=include_reserves)
        schedule=GO3._process_schedule_data(input,schedule)
    end
    model,schedule
end

function schedule_balance_summary(input,model)
    Dict("policy"=>"source_P_Q_bus_penalties_times_interval_duration",
        "source_p_penalty"=>input.violation_cost["p_bus_vio_cost"],
        "source_q_penalty"=>input.violation_cost["q_bus_vio_cost"],
        "p_imbalance_pu"=>[value(model[:p_balance_slack_pos][t])-value(model[:p_balance_slack_neg][t]) for t in input.periods],
        "q_imbalance_pu"=>[value(model[:q_balance_slack_pos][t])-value(model[:q_balance_slack_neg][t]) for t in input.periods],
        "penalty_cost"=>sum(input.dt[t]*(
            input.violation_cost["p_bus_vio_cost"]*(value(model[:p_balance_slack_pos][t])+value(model[:p_balance_slack_neg][t]))+
            input.violation_cost["q_bus_vio_cost"]*(value(model[:q_balance_slack_pos][t])+value(model[:q_balance_slack_neg][t]))) for t in input.periods))
end
