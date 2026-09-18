# Cold, within-attempt commitment construction. No saved or external solution.
const SCHEDULING_SEED_POLICY = "cold_online_construction_cost_lp_v2"
const SCHEDULING_POINT_TOLERANCE = 1e-8

function capture_scheduling_point(model)
    variables=all_variables(model)
    values=value.(variables)
    all(isfinite,values) || error("Nonfinite scheduling point")
    # Dense index lookup also supports deleted-variable holes, without a large Dict.
    positions=zeros(Int,maximum(index(v).value for v in variables;init=0))
    for (i,v) in enumerate(variables)
        positions[index(v).value]=i
    end
    (;variables,values,positions)
end

function scheduling_point_value(point,v)
    k=index(v).value
    1 <= k <= length(point.positions) || error("Scheduling point index missing")
    i=point.positions[k]
    i > 0 && point.variables[i]==v || error("Scheduling point model/mapping mismatch")
    point.values[i]
end

scheduling_set_residual(x,s::MOI.LessThan)=max(0.0,x-s.upper)
scheduling_set_residual(x,s::MOI.GreaterThan)=max(0.0,s.lower-x)
scheduling_set_residual(x,s::MOI.EqualTo)=abs(x-s.value)
scheduling_set_residual(x,s::MOI.Interval)=max(0.0,s.lower-x,x-s.upper)
scheduling_set_residual(x,::MOI.Integer)=abs(x-round(x))
scheduling_set_residual(x,::MOI.ZeroOne)=max(0.0,-x,x-1,abs(x-round(x)))
scheduling_set_residual(x,s)=error("Unsupported scheduling audit set: $(typeof(s))")

function audit_scheduling_point(model,point)
    all_variables(model)==point.variables || error("Incomplete scheduling point mapping")
    all(isfinite,point.values) || error("Nonfinite scheduling point")
    num_nonlinear_constraints(model)==0 || error("Unexpected nonlinear scheduling rows")
    getter=v->scheduling_point_value(point,v)
    maximum_residual,checked=0.0,0
    for (F,S) in list_of_constraint_types(model)
        (F==VariableRef || F==AffExpr) || error("Unsupported scheduling expression: $F")
        for row in all_constraints(model,F,S)
            c=constraint_object(row)
            x=value(getter,c.func)
            isfinite(x) || error("Nonfinite scheduling row activity")
            maximum_residual=max(maximum_residual,scheduling_set_residual(x,c.set))
            checked+=1
        end
    end
    objective=value(getter,objective_function(model))
    isfinite(objective) || error("Nonfinite scheduling objective")
    Dict("complete"=>true,"variables"=>length(point.variables),
        "constraints_including_bounds_and_integrality"=>checked,
        "maximum_residual"=>maximum_residual,"objective"=>objective,
        "pass"=>maximum_residual<=SCHEDULING_POINT_TOLERANCE)
end

function empty_native_scheduling_model!(model)
    backend(model) isa MOI.Utilities.CachingOptimizer || error("Scheduling edits require a cached model")
    MOI.Utilities.reset_optimizer(model)
    MOI.Utilities.state(backend(model))==MOI.Utilities.EMPTY_OPTIMIZER ||
        error("Native optimizer remained attached during scheduling domain edits")
end

function with_fixed_scheduling_integers(f,model,point;on_event=(name,details)->nothing)
    domains=NamedTuple[]
    on_event("fixed_pattern_native_detach_begin",Dict())
    empty_native_scheduling_model!(model)
    on_event("fixed_pattern_cache_edits_begin",Dict())
    try
        for v in all_variables(model)
            binary,integer=is_binary(v),is_integer(v)
            (binary || integer) || continue
            x=scheduling_point_value(point,v)
            abs(x-round(x))<=SCHEDULING_POINT_TOLERANCE || error("Fractional seed commitment")
            fixed=is_fixed(v)
            push!(domains,(;variable=v,binary,integer,fixed,
                lower=has_lower_bound(v) ? lower_bound(v) : nothing,
                upper=has_upper_bound(v) ? upper_bound(v) : nothing))
            binary && unset_binary(v)
            integer && unset_integer(v)
            fixed || fix(v,round(x);force=true)
        end
        on_event("fixed_pattern_cache_edits_complete",Dict("integer_variables"=>length(domains)))
        f()
    finally
        on_event("restore_native_detach_begin",Dict())
        empty_native_scheduling_model!(model)
        on_event("restore_cache_edits_begin",Dict())
        for d in domains
            v=d.variable
            if !d.fixed
                is_fixed(v) && unfix(v)
                d.lower===nothing || set_lower_bound(v,d.lower)
                d.upper===nothing || set_upper_bound(v,d.upper)
            end
            d.binary && set_binary(v)
            d.integer && set_integer(v)
        end
        on_event("restore_cache_edits_complete",Dict("integer_variables"=>length(domains)))
    end
end

function supply_scheduling_primal!(model,point)
    audit=audit_scheduling_point(model,point)
    audit["pass"] || error("Refusing infeasible scheduling MIP start")
    accepted=0
    for (v,x) in zip(point.variables,point.values)
        set_start_value(v,x)
        start_value(v)==x || error("Scheduling primal start readback mismatch")
        accepted+=1
    end
    Dict("source"=>"same_cold_attempt_only","complete"=>true,
        "accepted_interface_count"=>accepted,"variable_count"=>length(point.variables),
        "audit"=>audit,"native_acceptance"=>"pending_native_solve_log")
end

function construct_scheduling_seed!(model,input;construction_seconds,cost_seconds,
        cost_lp_solver="simplex",deadline=Inf,on_phase=record->nothing,
        on_seed=(point,audit,label)->nothing,on_event=(name,details)->nothing)
    cost_lp_solver in ("simplex","ipx") || error("Unregistered constructed-cost LP solver")
    original=objective_function(model)
    sense=objective_sense(model)
    sense==MOI.MAX_SENSE || error("Cold scheduling construction expects maximization")
    bounded(cap)=max(0.0,min(Float64(cap),deadline-time()-1.0))
    best=nothing
    records=Any[]
    construction_stats=nothing
    try
        @objective(model,Max,sum(input.dt[t]*model[:p_on_status][uid,t]
            for uid in input.sdd_ids_producer for t in input.periods))
        set_time_limit_sec(model,bounded(construction_seconds))
        phase_started=time()
        on_event("construction_solve_begin",Dict())
        optimize!(model)
        on_event("construction_solve_returned",Dict("wall_seconds"=>time()-phase_started))
        construction_stats=merge(model_stats(model),Dict(
            "phase"=>"online_commitment_construction","wall_seconds"=>time()-phase_started,
            "objective_scope"=>"producer_online_hours_not_source_economics"))
        primal_status(model)==FEASIBLE_POINT && (best=capture_scheduling_point(model))
    finally
        set_objective_sense(model,sense)
        set_objective_function(model,original)
    end
    if best!==nothing
        on_event("construction_audit_begin",Dict())
        a=audit_scheduling_point(model,best)
        construction_stats["original_model_audit"]=a
        a["pass"] || (best=nothing)
        on_event("construction_audit_complete",a)
        best===nothing || on_seed(best,a,"online_commitment_construction")
    end
    push!(records,construction_stats);on_phase(construction_stats)
    if best!==nothing && bounded(cost_seconds)>0
        cost_point=nothing
        cost_stats=nothing
        original_options=Dict(k=>get_optimizer_attribute(model,k) for k in
            ("solver","run_crossover","ipm_optimality_tolerance"))
        try
            with_fixed_scheduling_integers(model,best;on_event=on_event) do
                set_optimizer_attribute(model,"solver",cost_lp_solver)
                if cost_lp_solver=="ipx"
                    set_optimizer_attribute(model,"run_crossover","off")
                    set_optimizer_attribute(model,"ipm_optimality_tolerance",1e-10)
                end
                set_time_limit_sec(model,bounded(cost_seconds))
                phase_started=time()
                on_event("cost_lp_solve_begin",Dict("solver"=>cost_lp_solver))
                optimize!(model)
                on_event("cost_lp_solve_returned",Dict("wall_seconds"=>time()-phase_started))
                # This restricted LP's dual bound is irrelevant to the full MIP.
                # Avoid reconstructing LP dual objectives/gaps solely for logging.
                cost_stats=merge(model_stats(model;include_bound_and_gap=false),Dict(
                    "phase"=>"constructed_commitment_cost_lp","wall_seconds"=>time()-phase_started,
                    "solver"=>get_optimizer_attribute(model,"solver"),
                    "run_crossover"=>get_optimizer_attribute(model,"run_crossover"),
                    "bound_scope"=>"not_queried_restricted_LP_not_full_MIP"))
                on_event("cost_lp_statistics_complete",cost_stats)
                primal_status(model)==FEASIBLE_POINT && (cost_point=capture_scheduling_point(model))
                on_event("cost_lp_point_captured",Dict("complete_point"=>cost_point!==nothing))
            end
        finally
            for (key,setting) in original_options
                set_optimizer_attribute(model,key,setting)
            end
        end
        # Original integer types, explicit bounds, existing fixes, and cost are restored.
        if cost_point!==nothing
            on_event("cost_original_model_audit_begin",Dict())
            a=audit_scheduling_point(model,cost_point)
            cost_stats["original_model_audit"]=a
            on_event("cost_original_model_audit_complete",a)
            if a["pass"] && a["objective"]>=construction_stats["original_model_audit"]["objective"]
                best=cost_point
                on_seed(best,a,"constructed_commitment_cost_lp")
            end
        end
        push!(records,cost_stats);on_phase(cost_stats)
    end
    best,records
end

function schedule_at_scheduling_point(input,model,point;include_reserves=true)
    fields=[:on_status,:real_power,:reactive_power]
    symbols=[:p_on_status,:p,:q]
    if include_reserves
        reserve=[:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,:p_rru_off,
            :p_rrd_on,:p_rrd_off,:q_qru,:q_qrd]
        append!(fields,reserve);append!(symbols,reserve)
    end
    data=[Dict(uid=>[scheduling_point_value(point,model[symbol][uid,t])
        for t in input.periods] for uid in input.sdd_ids) for symbol in symbols]
    GO3._process_schedule_data(input,NamedTuple{Tuple(fields)}(Tuple(data)))
end

function select_scheduling_point(seed,seed_audit,native,native_audit)
    if native!==nothing && native_audit["pass"] &&
            (seed===nothing || native_audit["objective"]>=seed_audit["objective"])
        return native,native_audit,"original_economic_mip"
    end
    seed===nothing && return nothing,nothing,"none"
    seed_audit["pass"] || error("Unverified retained scheduling seed")
    seed,seed_audit,"within_run_constructed_commitment"
end
