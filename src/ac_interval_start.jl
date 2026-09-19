# Same-attempt continuation between adjacent hours. This object holds scalar
# values only, never a previous model, file path, dual vector or saved run.

function ac_primal_continuation_options()
    Dict{String,Any}("warm_start_init_point"=>"no","bound_push"=>1e-8,
        "bound_frac"=>1e-8,"slack_bound_push"=>1e-8,"slack_bound_frac"=>1e-8,
        "mu_init"=>1e-6)
end

function ac_cost_block_map(model,input,i)
    haskey(model.ext,:ac_cost_block_map) && return model.ext[:ac_cost_block_map]
    # Use source UID axes, not DenseAxisArray's Cartesian iteration order.
    p_ids=Dict(model[:p_sdd][uid]=>uid for uid in axes(model[:p_sdd],1))
    blocks=Dict{String,Vector{VariableRef}}()
    objective=objective_function(model)
    producers=Set(input.sdd_ids_producer)
    for c in all_constraints(model,AffExpr,MOI.EqualTo{Float64})
        row=constraint_object(c)
        row.set.value==0.0 && row.func.constant==0.0 || continue
        pv=[v for v in keys(row.func.terms) if haskey(p_ids,v)]
        length(pv)==1 || continue
        p=only(pv); scale=row.func.terms[p]
        abs(scale)==1.0 || continue
        rest=[v for v in keys(row.func.terms) if v!=p]
        isempty(rest) && continue
        # PWL block variables are anonymous in the pinned upstream builder.
        all(v->(isempty(name(v)) || startswith(name(v),"[")) &&
            row.func.terms[v]==-scale,rest) || continue
        uid=p_ids[p]
        haskey(blocks,uid) && error("Ambiguous PWL cost row for $uid")
        sort!(rest;by=v->index(v).value)
        source=input.sdd_ts_lookup[uid]["cost"][i]
        length(rest)==length(source) || error("PWL block count changed for $uid")
        for (v,block) in zip(rest,source)
            has_lower_bound(v) && has_upper_bound(v) && lower_bound(v)==0.0 &&
                upper_bound(v)==Float64(block[2]) || error("PWL block identity/bound mismatch for $uid")
            expected=(uid in producers ? -1.0 : 1.0)*input.dt[i]*block[1]
            coefficient(objective,v)==expected || error("PWL source coefficient mismatch for $uid")
        end
        blocks[uid]=rest
    end
    Set(keys(blocks))==Set(values(p_ids)) || error("Incomplete PWL cost-block identity map")
    model.ext[:ac_cost_block_map]=blocks
    blocks
end

function capture_ac_interval_start(model,input,i;point=nothing)
    ac_requires_stop(get(model.ext,:reserve_ac,Dict()),true) &&
        error("Cannot propagate an AC interval that failed its residual screen")
    getter=if point===nothing
        value
    else
        point.variables==all_variables(model) || error("Incomplete correction continuation mapping")
        mapped=Dict(zip(point.variables,point.values))
        v->mapped[v]
    end
    cost_vars=Set(v for vs in values(ac_cost_block_map(model,input,i)) for v in vs)
    named=Dict{String,Float64}()
    for v in all_variables(model)
        v in cost_vars && continue
        key=name(v)
        isempty(key) && error("Unidentified non-cost AC variable")
        haskey(named,key) && error("Ambiguous AC variable name $key")
        x=Float64(getter(v))
        isfinite(x) || error("Cannot propagate nonfinite AC state")
        named[key]=x
    end
    (interval=i,named=named,
        source_residual=last(model.ext[:reserve_ac]["phases"])["max_primal_residual"])
end

function apply_ac_interval_start!(model,input,i,seed,scheduled_power)
    i>1 && seed.interval==i-1 || error("AC continuation must come from the immediately preceding interval")
    isfinite(seed.source_residual) && 0 <= seed.source_residual <= AC_POINT_RESIDUAL_TOLERANCE ||
        error("AC continuation source did not pass the local residual screen")
    all(isfinite,values(seed.named)) || error("AC continuation contains nonfinite values")
    blocks=ac_cost_block_map(model,input,i)
    cost_vars=Set(v for vs in values(blocks) for v in vs)
    variables=all_variables(model)
    reused=0; defaults=0; adjusted=0
    for v in variables
        from_previous=!(v in cost_vars) && haskey(seed.named,name(v))
        x=from_previous ? seed.named[name(v)] : something(start_value(v),0.0)
        reused+=from_previous; defaults+=!from_previous
        lo=has_lower_bound(v) ? lower_bound(v) : -Inf
        hi=has_upper_bound(v) ? upper_bound(v) : Inf
        y=is_fixed(v) ? fix_value(v) : clamp(x,lo,hi)
        isfinite(y) || error("Nonfinite current-interval start")
        adjusted+=x!=y
        set_start_value(v,y)
    end
    # Cost blocks have no stable global name. Recreate a primal-feasible block
    # allocation from THIS hour's original prices/widths and current P start.
    objective=objective_function(model)
    for (uid,vars) in blocks
        p=model[:p_sdd][uid]
        capacity=sum(upper_bound(v) for v in vars)
        lo=is_fixed(p) ? fix_value(p) : (has_lower_bound(p) ? lower_bound(p) : -Inf)
        hi=is_fixed(p) ? fix_value(p) : (has_upper_bound(p) ? upper_bound(p) : Inf)
        max(0.0,lo)<=min(capacity,hi) || error("No feasible PWL start range for $uid")
        target=clamp(start_value(p),max(0.0,lo),min(capacity,hi))
        adjusted+=target!=start_value(p)
        set_start_value(p,target)
        remaining=target
        order=sortperm(vars;by=v->-coefficient(objective,v))
        for j in order
            v=vars[j]; x=min(remaining,upper_bound(v))
            set_start_value(v,x); remaining-=x
        end
        abs(remaining)<=1e-10 || error("Incomplete current-hour PWL start allocation")
        if haskey(object_dictionary(model),:p_slack_pos) && uid in axes(model[:p_slack_pos],1)
            delta=target-scheduled_power[uid]
            set_start_value(model[:p_slack_pos][uid],max(delta,0.0))
            set_start_value(model[:p_slack_neg][uid],max(-delta,0.0))
        end
    end
    values_=Float64[start_value(v) for v in variables]
    all(isfinite,values_) || error("Incomplete current-hour AC primal start")
    point=(variables=variables,values=values_)
    # This is a primal-only initialization for a different hourly model. Do
    # not assert that previous-hour duals or the old reduced structure apply.
    options=ac_primal_continuation_options()
    for (key,val) in options
        set_optimizer_attribute(model,key,val)
        get_optimizer_attribute(model,key)==val || error("AC continuation option was not retained")
    end
    Dict("policy"=>"previous_screened_interval_v1","source_interval"=>seed.interval,
        "target_interval"=>i,"source_local_residual"=>seed.source_residual,
        "current_variable_count"=>length(variables),"reused_named_values"=>reused,
        "default_or_new_values"=>defaults,"current_cost_blocks_initialized"=>length(cost_vars),
        "bounds_adjusted_starts"=>adjusted,"complete_current_primal_vector"=>true,
        "start_model_residual"=>ac_primal_residual(model,point),"options"=>options,
        "external_solution_read"=>false,"source_bounds_changed"=>false,"dual_start"=>false,
        "acceptance_scope"=>"MOI starts on complete current vector; final feasibility still requires re-solve and verification")
end
