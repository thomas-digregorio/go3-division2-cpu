# One sequential hourly search: source/within-attempt discrete shunts, bounded
# AC linear corrections, short Ipopt fallback, optional bounded shunt revisit.
function initialize_ac_network_flows!(model,input)
    # Evaluate physical branch flows from this attempt's voltage starts. This
    # is a cheap starting point construction, not a power-flow feasibility claim.
    count=0
    for (lookup,slack_symbol) in ((input.ac_line_lookup,:ac_thermal_slack),(input.twt_lookup,:twt_thermal_slack))
        for (uid,b) in lookup
            b["initial_status"]["on_status"]==1 || continue
            b["additional_shunt"]==0 || error("Unsupported branch shunt in correction initializer")
            fr,to=b["fr_bus"],b["to_bus"]
            vf=start_value(model[:vm][fr])*cis(start_value(model[:va][fr]))
            vt=start_value(model[:vm][to])*cis(start_value(model[:va][to]))
            tap=slack_symbol==:twt_thermal_slack ? b["initial_status"]["tm"]*cis(b["initial_status"]["ta"]) : 1.0+0im
            y=inv(complex(b["r"],b["x"]));sh=0.5im*b["b"]
            sf=vf*conj((y+sh)/abs2(tap)*vf-y/conj(tap)*vt)
            st=vt*conj((y+sh)*vt-y/tap*vf)
            for (key,s) in (((uid,fr,to),sf),((uid,to,fr),st))
                for (v,x) in ((model[:p_branch][key],real(s)),(model[:q_branch][key],imag(s)))
                    set_start_value(v,clamp(x,lower_bound(v),upper_bound(v)))
                end
            end
            set_start_value(model[slack_symbol][uid],max(0.0,abs(sf)-b["mva_ub_nom"],abs(st)-b["mva_ub_nom"]))
            count+=1
        end
    end
    count
end

function initialize_ac_correction!(model,input,i,real_power,reactive_power,interval_seed)
    for v in all_variables(model)
        lo=has_lower_bound(v) ? lower_bound(v) : -Inf
        hi=has_upper_bound(v) ? upper_bound(v) : Inf
        x=is_fixed(v) ? fix_value(v) : clamp(something(start_value(v),0.0),lo,hi)
        set_start_value(v,x)
    end
    if interval_seed!==nothing
        record=apply_ac_interval_start!(model,input,i,interval_seed,real_power)
        record["branch_flow_starts_recomputed"]=initialize_ac_network_flows!(model,input)
        return record
    end
    angle_uids=Dict(model[:va][u]=>u for u in input.bus_ids)
    shift=nothing
    for cref in all_constraints(model,AffExpr,MOI.EqualTo{Float64})
        row=constraint_object(cref)
        length(row.func.terms)==1 || continue
        v,a=only(row.func.terms)
        haskey(angle_uids,v) || continue
        shift=input.bus_lookup[angle_uids[v]]["initial_status"]["va"]-
            (row.set.value-row.func.constant)/a
        break
    end
    shift===nothing && error("Cannot identify the original AC reference angle")
    for uid in input.bus_ids
        init=input.bus_lookup[uid]["initial_status"]
        set_start_value(model[:vm][uid],clamp(init["vm"],lower_bound(model[:vm][uid]),upper_bound(model[:vm][uid])))
        set_start_value(model[:va][uid],is_fixed(model[:va][uid]) ? fix_value(model[:va][uid]) : init["va"]-shift)
    end
    for uid in axes(model[:p_sdd],1)
        for (v,x) in ((model[:p_sdd][uid],real_power[uid]),(model[:q_sdd][uid],reactive_power[uid]))
            set_start_value(v,is_fixed(v) ? fix_value(v) : clamp(x,lower_bound(v),upper_bound(v)))
        end
    end
    objective=objective_function(model)
    for (uid,blocks) in ac_cost_block_map(model,input,i)
        remaining=start_value(model[:p_sdd][uid])
        for j in sortperm(blocks;by=v->-coefficient(objective,v))
            v=blocks[j];x=min(remaining,upper_bound(v))
            set_start_value(v,x);remaining-=x
        end
        abs(remaining)<=1e-8 || error("Incomplete source-derived PWL start")
    end
    Dict("policy"=>"source_voltages_and_current_cold_schedule",
        "branch_flow_starts_recomputed"=>initialize_ac_network_flows!(model,input),
        "source_angle_reference_shift"=>shift,
        "complete_current_primal_vector"=>true,"external_solution_read"=>false,
        "source_bounds_changed"=>false,"dual_start"=>false)
end

function extract_ac_correction_result(model,input,on,real_power,point)
    point.variables==all_variables(model) || error("Incomplete output variable mapping")
    x=Dict(zip(point.variables,point.values));getv(v)=x[v]
    isempty(input.dc_line_ids) || error("DC output is outside the registered correction feature gate")
    active=Set(axes(model[:p_sdd],1))
    Dict("bus"=>Dict(uid=>Dict("vm"=>getv(model[:vm][uid]),"va"=>getv(model[:va][uid])) for uid in input.bus_ids),
        "shunt"=>Dict(uid=>Dict("step"=>getv(model[:shunt_step][uid])) for uid in input.shunt_ids),
        "simple_dispatchable_device"=>Dict(uid=>Dict("on_status"=>on[uid],
            "p_on"=>on[uid]==1 && uid in active ? getv(model[:p_sdd][uid]) : 0.0,
            "q"=>uid in active ? getv(model[:q_sdd][uid]) : 0.0) for uid in input.sdd_ids),
        "ac_line"=>Dict(uid=>Dict("on_status"=>input.ac_line_lookup[uid]["initial_status"]["on_status"]) for uid in input.ac_line_ids),
        "two_winding_transformer"=>Dict(uid=>Dict(k=>input.twt_lookup[uid]["initial_status"][k]
            for k in ("on_status","tm","ta")) for uid in input.twt_ids),
        "dc_line"=>Dict{String,Any}())
end

function correction_ipopt_fallback!(model,optimizer,point;deadline,seconds=12.0,phase="fixed_shunt_fallback")
    started=time()
    record=prepare_ac_recovery!(model,optimizer,point;seconds,deadline,max_iter=120)
    record["trigger"]="linear_correction_failed_original_model_residual_screen"
    record["complete_primal_start"]["source"]="network_correction_in_same_interval_and_attempt"
    set_optimizer_attribute(model,"max_wall_time",rounded_ac_time_limit(seconds,deadline))
    guard=install_ac_primal_guard!(model;policy=AC_PRIMAL_GUARD_POLICY,phase="rounded_shunts",
        min_iterations=0,window=2,objective_relative_range=1.0)
    optimize!(model,_differentiation_backend=GO3.MathOptSymbolicAD.DefaultBackend())
    has_values(model) || return point,Dict("phase"=>phase,"complete_finite_point"=>true,
        "max_primal_residual"=>ac_primal_residual(model,point),"termination"=>string(termination_status(model)),
        "wall_seconds"=>time()-started,"fallback"=>true,"start"=>record,"returned_point"=>false)
    guard_record=finish_ac_primal_guard!(model,guard)
    proposed=capture_complete_ac_primal(model)
    before=ac_primal_residual(model,point);after=ac_primal_residual(model,proposed)
    accept=after<=before
    chosen=accept ? proposed : point
    chosen,merge(model_stats(model),Dict("phase"=>phase,"complete_finite_point"=>true,
        "max_primal_residual"=>min(before,after),"before_residual"=>before,
        "wall_seconds"=>time()-started,"fallback"=>true,"start"=>record,
        "native_primal_guard"=>guard_record,"returned_point"=>true,"accepted"=>accept,
        "rollback"=>!accept,"certificate_scope"=>"primal feasibility only, not optimality"))
end

function compute_corrected_ac(working,source,i;on_status,real_power,reactive_power,curves,
        optimizer,deadline,interval_seed=nothing,slp_seconds=15.0,lp_seconds=4.0,
        max_rounds=8,fallback_seconds=12.0,threads=4)
    began=time()
    model,reserve=build_reserve_aware_ac(working,source,i;on_status,real_power,curves)
    set_optimizer(model,optimizer)
    start_record=initialize_ac_correction!(model,source,i,real_power,reactive_power,interval_seed)
    shunt_domains=Dict(u=>(lower_bound(model[:shunt_step][u]),upper_bound(model[:shunt_step][u])) for u in source.shunt_ids)
    settings=Dict{String,Float64}()
    for u in source.shunt_ids
        v=model[:shunt_step][u]
        step=clamp(round(start_value(v)),shunt_domains[u]...)
        isinteger(step) || error("Source shunt domain has no selected integral point")
        settings[u]=step;fix(v,step;force=true);set_start_value(v,step)
    end
    point=(variables=all_variables(model),values=Float64[start_value(v) for v in all_variables(model)])
    built=time()-began
    point,slp=ac_linear_correction(model,point;deadline=min(deadline,time()+slp_seconds),
        max_rounds,lp_seconds,threads)
    phases=Any[slp]
    if slp["max_primal_residual"]>AC_POINT_RESIDUAL_TOLERANCE && deadline-time()>3
        point,phase=correction_ipopt_fallback!(model,optimizer,point;deadline,seconds=fallback_seconds)
        push!(phases,phase)
    end
    revisited=false
    if last(phases)["max_primal_residual"]>AC_POINT_RESIDUAL_TOLERANCE &&
            !isempty(source.shunt_ids) && deadline-time()>5
        # A small continuous candidate search, followed by explicit rounding and
        # another fixed-setting repair. Relaxation is never accepted as discrete.
        revisited=true
        saved_point=point;saved_settings=copy(settings)
        saved_residual=last(phases)["max_primal_residual"]
        for u in source.shunt_ids
            v=model[:shunt_step][u];unfix(v)
            set_lower_bound(v,shunt_domains[u][1]);set_upper_bound(v,shunt_domains[u][2])
        end
        relaxed,phase=ac_linear_correction(model,point;deadline=min(deadline-3,time()+4),
            max_rounds=3,lp_seconds,threads)
        phase["phase"]="shunt_revisit_relaxation";push!(phases,phase)
        lookup=Dict(zip(relaxed.variables,relaxed.values))
        for u in source.shunt_ids
            v=model[:shunt_step][u];step=clamp(round(lookup[v]),shunt_domains[u]...)
            fix(v,step;force=true);lookup[v]=step;settings[u]=step
        end
        point=(variables=relaxed.variables,values=[lookup[v] for v in relaxed.variables])
        point,phase=ac_linear_correction(model,point;deadline,max_rounds,lp_seconds,threads)
        phase["phase"]="rounded_shunt_repair";push!(phases,phase)
        if phase["max_primal_residual"]>saved_residual
            point=saved_point;settings=saved_settings
            for u in source.shunt_ids
                fix(model[:shunt_step][u],settings[u];force=true)
            end
            phase["revisit_rolled_back"]=true
        end
    end
    residual=ac_primal_residual(model,point)
    push!(phases,Dict("phase"=>"selected_correction_point","complete_finite_point"=>true,
        "max_primal_residual"=>residual,"wall_seconds"=>0.0,
        "certificate_scope"=>"local primal only; full final verification still mandatory"))
    all(isinteger,values(settings)) || error("Correction returned nonintegral shunts")
    model.ext[:correction_point]=point
    model.ext[:reserve_ac]["phases"]=phases
    model.ext[:reserve_ac]["interval_primal_start"]=start_record
    model.ext[:reserve_ac]["correction"]=Dict("policy"=>AC_CORRECTION_POLICY,
        "model_build_and_initialization_seconds"=>built,"total_seconds"=>time()-began,
        "shunts_revisited"=>revisited,"final_discrete_settings"=>settings,
        "source_bounds_changed"=>false,"sequential_temporal_bounds"=>true,
        "final_model_residual"=>residual,"threads"=>threads,"external_solution_read"=>false)
    lookup=Dict(zip(point.variables,point.values))
    model.ext[:reserve_ac]["reserve_cost_at_solution"]=value(v->lookup[v],reserve.cost)
    result=extract_ac_correction_result(model,working,on_status,real_power,point)
    model,result
end
