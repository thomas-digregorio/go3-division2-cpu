# Initial primal construction only. No source/model/bounds/objective edits,
# no optimization call and no input from a previous attempt.
const AC_INITIALIZATION_POLICY = "current_schedule_preserving_restarts_v1"

function complete_requested_ac_start(model)
    variables=all_variables(model)
    values_=Float64[something(start_value(v),NaN) for v in variables]
    all(isfinite,values_) || error("Incomplete/nonfinite requested AC start")
    (variables=variables,values=values_)
end

function preserve_ac_primal_initialization!(model)
    # Ordinary primal initialization: no invented or unconverged dual start.
    # Use the small pushes already exercised by adjacent-hour continuation.
    options=Dict{String,Any}("warm_start_init_point"=>"no",
        "bound_push"=>1e-8,"bound_frac"=>1e-8,
        "slack_bound_push"=>1e-8,"slack_bound_frac"=>1e-8)
    for (key,val) in options
        set_optimizer_attribute(model,key,val)
        get_optimizer_attribute(model,key)==val || error("Primal initialization option lost")
    end
    options
end

function initialize_ac_from_current_schedule!(model,reserve,input,i,schedule,scheduled_power)
    i==first(input.periods) || error("Cold schedule initialization is restricted to the first interval")
    began=time(); adjusted=Ref(0)
    function put(v,x)
        x=Float64(x);isfinite(x) || error("Nonfinite current-schedule AC seed")
        lo=has_lower_bound(v) ? lower_bound(v) : -Inf
        hi=has_upper_bound(v) ? upper_bound(v) : Inf
        y=is_fixed(v) ? fix_value(v) : clamp(x,lo,hi)
        isfinite(y) || error("Nonfinite projected AC seed")
        adjusted[]+=y!=x
        set_start_value(v,y)
        start_value(v)==y || error("Requested AC seed was not retained")
    end
    # Retain upstream voltage/angle/device starts where specified; explicitly
    # populate all otherwise-default auxiliary values without changing domains.
    for v in all_variables(model)
        put(v,something(start_value(v),0.0))
    end
    ids=Set(axes(model[:p_sdd],1))
    for uid in input.sdd_ids
        scheduled_p,scheduled_q=schedule.real_power[uid][i],schedule.reactive_power[uid][i]
        if uid in ids
            put(model[:p_sdd][uid],scheduled_p);put(model[:q_sdd][uid],scheduled_q)
        else
            scheduled_p==0.0 && scheduled_q==0.0 || error("AC filtering omitted a nonzero scheduled device")
        end
    end
    blocks=ac_cost_block_map(model,input,i)
    objective=objective_function(model)
    for (uid,vs) in blocks
        power_variable=model[:p_sdd][uid]; capacity=sum(upper_bound(v) for v in vs)
        lo=is_fixed(power_variable) ? fix_value(power_variable) :
            (has_lower_bound(power_variable) ? lower_bound(power_variable) : -Inf)
        hi=is_fixed(power_variable) ? fix_value(power_variable) :
            (has_upper_bound(power_variable) ? upper_bound(power_variable) : Inf)
        max(0.0,lo)<=min(capacity,hi) || error("No feasible original PWL start range for $uid")
        # As in adjacent-hour continuation, project only the initial value onto
        # the exact intersection. Do not turn scheduling roundoff into failure
        # or modify the source generator / cost-block bounds.
        target=clamp(start_value(power_variable),max(0.0,lo),min(capacity,hi))
        adjusted[]+=target!=start_value(power_variable)
        put(power_variable,target)
        remaining=target
        for j in sortperm(vs;by=v->-coefficient(objective,v))
            v=vs[j]; x=min(remaining,upper_bound(v));put(v,x);remaining-=x
        end
        abs(remaining)<=1e-10 || error("Incomplete source-cost-block AC seed")
        if haskey(object_dictionary(model),:p_slack_pos) && uid in axes(model[:p_slack_pos],1)
            delta=target-scheduled_power[uid]
            put(model[:p_slack_pos][uid],max(delta,0.0))
            put(model[:p_slack_neg][uid],max(-delta,0.0))
        end
    end
    products=(:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,:p_rru_off,
        :p_rrd_on,:p_rrd_off,:q_qru,:q_qrd)
    for key in products
        hasproperty(schedule,key) || error("Current joint schedule lacks reserve product $key")
        for uid in input.sdd_ids
            put(getproperty(reserve.variables,key)[uid],getproperty(schedule,key)[uid][i])
        end
    end
    zones=GO3._get_sdd_in_zones(input)
    active_power(u)=u in ids ? start_value(model[:p_sdd][u]) : 0.0
    r(key,u)=start_value(getproperty(reserve.variables,key)[u])
    total(keys_,members)=sum((r(k,u) for k in keys_ for u in members);init=0.0)
    rgu,rgd,scr,nsc,rru,rrd,qru,qrd=reserve.shortfalls
    for z in input.azr_ids
        members=zones.sdd_in_azone[z];zone=input.azr_lookup[z]
        peak=maximum((active_power(u) for u in zones.p_sdd_in_azone[z]);init=0.0)
        put(reserve.peak[z],peak)
        load=sum((active_power(u) for u in zones.c_sdd_in_azone[z]);init=0.0)
        up,down=zone["REG_UP"]*load,zone["REG_DOWN"]*load
        for (v,requirement,keys_) in (
                (rgu[z],up,(:p_rgu,)),(rgd[z],down,(:p_rgd,)),
                (scr[z],up+zone["SYN"]*peak,(:p_rgu,:p_scr)),
                (nsc[z],up+(zone["SYN"]+zone["NSYN"])*peak,(:p_rgu,:p_scr,:p_nsc)),
                (rru[z],input.azr_ts_lookup[z]["RAMPING_RESERVE_UP"][i],(:p_rru_on,:p_rru_off)),
                (rrd[z],input.azr_ts_lookup[z]["RAMPING_RESERVE_DOWN"][i],(:p_rrd_on,:p_rrd_off)))
            put(v,max(0.0,requirement-total(keys_,members)))
        end
    end
    for z in input.rzr_ids
        members=zones.sdd_in_rzone[z]
        put(qru[z],max(0.0,input.rzr_ts_lookup[z]["REACT_UP"][i]-total((:q_qru,),members)))
        put(qrd[z],max(0.0,input.rzr_ts_lookup[z]["REACT_DOWN"][i]-total((:q_qrd,),members)))
    end
    point=complete_requested_ac_start(model)
    record=Dict("policy"=>AC_INITIALIZATION_POLICY,"source"=>"current_attempt_joint_schedule",
        "interval"=>i,"variable_count"=>length(point.variables),"complete_current_primal_vector"=>true,
        "source_devices"=>length(input.sdd_ids),"cost_blocks_initialized"=>sum(length,values(blocks)),
        "reserve_values_initialized"=>length(products)*length(input.sdd_ids),
        "bounds_adjusted_start_assignments"=>adjusted[],"initialization_seconds"=>time()-began,
        "optimization_calls"=>0,"external_solution_read"=>false,"source_bounds_changed"=>false,
        "model_structure_changed"=>false,"objective_changed"=>false,"feasibility_claimed"=>false,
        "scope"=>"Complete same-attempt primal only; AC and exhaustive verification remain mandatory")
    record,point
end
