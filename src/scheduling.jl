# Project-owned adapter; pinned upstream code and source penalties are untouched.
function source_balance_scheduling_model(input)
    model = GO3.get_copperplate_scheduling_model(input;
        include_reserves=true,relax_balances=true,relax_reserves=true,
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
    model
end

function schedule_source_balances(input;optimizer,time_limit,set_silent=false)
    model=source_balance_scheduling_model(input)
    set_optimizer(model,optimizer)
    set_time_limit_sec(model,time_limit)
    set_silent && JuMP.set_silent(model)
    # No saved starts, no preceding pilot data, no external optimized solution.
    optimize!(model)
    schedule=nothing
    if primal_status(model)==FEASIBLE_POINT
        schedule=GO3.extract_data_from_scheduling_model(input,model;include_reserves=true)
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
