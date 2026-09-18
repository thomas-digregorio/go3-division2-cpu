# Project-owned, conservative dominance test for flexible CONSUMERS only.
# This file is not enabled by any campaign configuration until its component
# tests pass and a new cold attempt is registered. It does not change raw data.

"""
Return reasons why fixing this consumer online cannot yet be justified.

An empty list proves a sufficient (not necessary) dominance condition: any
feasible binary schedule can be mapped to all-online with the same P/Q network
injections and no lower objective. Offline downward ramping reserve is moved to
the identical zonal product's online component. See docs/CONSUMER_DOMINANCE.md.
No tolerance is used to turn a nonzero source PMIN or cost into zero.
"""
function consumer_online_dominance_reasons(input, uid)
    d, ts = input.sdd_lookup[uid], input.sdd_ts_lookup[uid]
    reasons = String[]
    d["device_type"] == "consumer" || return ["not_a_consumer"]
    init = d["initial_status"]
    init["on_status"] == 1 && init["accu_down_time"] == 0 &&
        init["accu_up_time"] > 0 || push!(reasons,"not_initially_online")
    d["on_cost"] == 0 || push!(reasons,"nonzero_online_cost")
    d["startup_cost"] >= 0 && d["shutdown_cost"] >= 0 ||
        push!(reasons,"negative_transition_cost")
    isempty(d["startup_states"]) || push!(reasons,"special_startup_states")
    d["q_bound_cap"] == 0 && d["q_linear_cap"] == 0 ||
        push!(reasons,"coupled_reactive_capability")
    all(==(0),ts["p_lb"]) || push!(reasons,"nonzero_source_pmin")
    all(>=(0),ts["p_ub"]) || push!(reasons,"negative_source_pmax")
    all(t -> ts["on_status_lb"][t] <= 1 <= ts["on_status_ub"][t],input.periods) ||
        push!(reasons,"online_not_always_allowed")
    all(t -> ts["q_lb"][t] <= 0 <= ts["q_ub"][t],input.periods) ||
        push!(reasons,"reactive_bounds_exclude_zero")
    all(t -> isfinite(input.dt[t]) && input.dt[t] > 0,input.periods) ||
        push!(reasons,"invalid_interval_duration")
    isfinite(init["p"]) && init["p"] >= 0 || push!(reasons,"invalid_initial_power")
    d["p_startup_ramp_ub"] > 0 && d["p_shutdown_ramp_ub"] > 0 ||
        push!(reasons,"nonpositive_transition_ramp")
    # PMIN is zero after the initial condition; this also excludes a nonzero
    # shutdown power trajectory from the initially-online state in interval 1.
    input.dt[first(input.periods)]*d["p_shutdown_ramp_ub"] >= init["p"] ||
        push!(reasons,"initial_shutdown_curve_can_be_nonzero")
    for t in input.periods
        previous_max = t == first(input.periods) ? init["p"] : ts["p_ub"][t-1]
        previous_min = t == first(input.periods) ? init["p"] : 0.0
        input.dt[t]*d["p_ramp_up_ub"] >= max(0.0,ts["p_ub"][t]-previous_min) ||
            push!(reasons,"online_ramp_up_can_restrict_dispatch")
        input.dt[t]*d["p_ramp_down_ub"] >= previous_max ||
            push!(reasons,"online_ramp_down_can_restrict_dispatch")
    end
    d["p_ramp_res_down_online_ub"] >= d["p_ramp_res_down_offline_ub"] ||
        push!(reasons,"offline_down_reserve_capacity_is_larger")
    all(t -> ts["p_ramp_res_down_online_cost"][t] <=
        ts["p_ramp_res_down_offline_cost"][t],input.periods) ||
        push!(reasons,"online_down_reserve_is_more_expensive")
    sort!(unique!(reasons))
end

function consumer_online_dominance_audit(input)
    eligible = String[]
    rejected = Dict{String,Vector{String}}()
    for uid in sort(input.sdd_ids_consumer)
        reasons = consumer_online_dominance_reasons(input,uid)
        isempty(reasons) ? push!(eligible,uid) : (rejected[uid]=reasons)
    end
    Dict("policy"=>"proven_zero_minimum_consumer_online_dominance_v1",
        "eligible_consumer_uids"=>eligible,"rejected_consumers"=>rejected,
        "eligible_consumers"=>length(eligible),
        "fixed_online_variables"=>length(eligible)*length(input.periods),
        "generator_commitments_changed"=>0,"source_values_changed"=>false)
end

function apply_consumer_online_dominance!(model,input)
    audit=consumer_online_dominance_audit(input)
    for uid in audit["eligible_consumer_uids"], t in input.periods
        # Leave startup/shutdown consequences to the ORIGINAL evolution rows
        # and native solver presolve. No constraints or generator columns drop.
        JuMP.fix(model[:p_on_status][uid,t],1.0;force=true)
    end
    model.ext[:consumer_online_dominance]=audit
    audit
end
