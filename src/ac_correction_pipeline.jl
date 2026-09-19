# One sequential hourly search: source/within-attempt discrete shunts, bounded
# AC linear corrections, short Ipopt fallback, optional bounded shunt revisit.

function correction_interval_budget(config,remaining_intervals,deadline;now=time())
    remaining_intervals isa Integer && remaining_intervals>0 || error("Invalid remaining AC intervals")
    policy=get(config,"ac_correction_budget_policy","fixed_hour_v1")
    policy in ("fixed_hour_v1","remaining_horizon_v1") || error("Unknown AC correction budget policy")
    cap=Float64(get(config,"ac_correction_hour_seconds",45.0))
    isfinite(cap) && cap>0 && isfinite(deadline) && isfinite(now) || error("Invalid AC correction budget")
    available=max(0.0,deadline-now)
    fair=available/remaining_intervals
    future_reserve=0.0
    allowance=if policy=="fixed_hour_v1"
        min(cap,available)
    else
        minimum=Float64(get(config,"ac_correction_min_hour_seconds",60.0))
        factor=Float64(get(config,"ac_correction_share_multiplier",1.5))
        future=Float64(get(config,"ac_correction_future_hour_floor_seconds",20.0))
        all(isfinite,(minimum,factor,future)) && 0<minimum<=cap && factor>=1 && future>0 ||
            error("Invalid adaptive AC correction allocation")
        # Prefer a short correction but let a difficult hour use a larger share.
        # Recompute after each hour; never reset the global/finalization deadline.
        future_reserve=min(future,fair)*(remaining_intervals-1)
        min(cap,max(minimum,factor*fair),available-future_reserve,available)
    end
    slp=min(Float64(get(config,"ac_correction_seconds",15.0)),
        policy=="remaining_horizon_v1" ? 0.3*allowance : allowance)
    isfinite(slp) && slp>=0 || error("Invalid correction phase budget")
    Dict("policy"=>policy,"remaining_intervals"=>remaining_intervals,
        "remaining_refinement_seconds"=>available,"fair_share_seconds"=>fair,
        "future_hours_reserved_seconds"=>future_reserve,"hour_allowance_seconds"=>allowance,
        "hour_deadline"=>now+allowance,"slp_seconds"=>slp,
        "global_deadline_reset"=>false)
end

function correction_fallback_budget(cap,deadline;now=time(),adaptive=false)
    cap isa Real && isfinite(cap) && cap>0 || error("Invalid fallback cap")
    remaining=max(0.0,deadline-now-2.0)
    min(Float64(cap),adaptive ? 0.75*remaining : remaining)
end

function correction_phase_event(phase,event;details=Dict())
    println("GO3_CORRECTION_PHASE ",JSON.json(merge(Dict("phase"=>phase,"event"=>event),details)))
    flush(stdout)
end
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

function correction_ipopt_fallback!(model,optimizer,point;deadline,seconds=12.0,
        phase="fixed_shunt_fallback",max_iter=120,allow_unfixed_shunts=false,barrier_strategy="adaptive",
        primal_target=AC_POINT_RESIDUAL_TOLERANCE,continuous_candidate_guard=false,dual_seed=nothing,
        preserve_primal_continuation=false,audit_native_initialization=false)
    started=time()
    barrier_strategy in ("adaptive","monotone") || error("Unknown correction barrier strategy")
    isfinite(primal_target) && 0<primal_target<=AC_POINT_RESIDUAL_TOLERANCE || error("Invalid correction fallback target")
    fixed_shunts=!haskey(object_dictionary(model),:shunt_step) || all(is_fixed,model[:shunt_step])
    fixed_shunts || allow_unfixed_shunts || error("Unfixed shunts require candidate-only fallback")
    dual_seed===nothing || fixed_shunts || error("Rounded dual seed cannot initialize unfixed shunts")
    correction_phase_event(phase,"begin";details=Dict("requested_seconds"=>seconds,
        "remaining_hour_seconds"=>deadline-started,"max_iterations"=>max_iter,
        "fixed_shunts"=>fixed_shunts,"barrier_strategy"=>barrier_strategy))
    record=prepare_ac_recovery!(model,optimizer,point;seconds,deadline,max_iter)
    record["trigger"]="linear_correction_failed_original_model_residual_screen"
    record["complete_primal_start"]["source"]="network_correction_in_same_interval_and_attempt"
    set_optimizer_attribute(model,"mu_strategy",barrier_strategy)
    record["options"]["mu_strategy"]=barrier_strategy
    record["candidate_only_unfixed_shunts"]=!fixed_shunts
    record["internal_primal_target"]=primal_target
    if primal_target<AC_POINT_RESIDUAL_TOLERANCE
        # Headroom for independent reconstruction: several branch-row residuals
        # may accumulate in one bus balance. Do not relax the final acceptance.
        for (key,val) in Dict("tol"=>primal_target,"constr_viol_tol"=>primal_target/10,
                "acceptable_tol"=>primal_target,"acceptable_constr_viol_tol"=>primal_target/10)
            set_optimizer_attribute(model,key,val);record["options"][key]=val
        end
    end
    record["primal_continuation_preserved"]=preserve_primal_continuation && dual_seed===nothing
    if record["primal_continuation_preserved"]
        # prepare_ac_recovery! deliberately resets a failed rounded solve. A
        # correction fallback originating from the previous screened hour is
        # different: keep that within-attempt primal-only initialization close
        # to its current bounds instead of silently resetting 1e-8 to 0.01.
        # No source bounds or multipliers from another hour are transferred.
        options=ac_primal_continuation_options()
        for (key,val) in options
            set_optimizer_attribute(model,key,val)
            get_optimizer_attribute(model,key)==val || error("Correction continuation option not retained")
        end
        merge!(record["options"],options)
        record["policy"]="same_attempt_primal_continuation_fallback_v1"
        record["dual_certificate_claimed"]=false
    end
    record["dual_transfer_used"]=dual_seed!==nothing
    if dual_seed!==nothing
        # Finite approximate multipliers initialize the current same-hour model.
        # Their mapping is audited; they are NOT used as a lower-bound proof.
        fixed=Set(FixRef(v) for v in model[:shunt_step])
        dual_record=restore_complete_ac_dual!(model,dual_seed.point;
            new_fixed=fixed,removed_bounds=dual_seed.removed_bounds)
        record["dual_start"]=dual_record
        merge!(record["options"],dual_record["options"])
        record["policy"]="same_interval_primal_dual_rounded_repair_v1"
        record["complete_primal_start"]["dual_or_basis_start"]=true
        record["complete_primal_start"]["basis_start"]=false
        record["dual_certificate_claimed"]=false
        record["dual_source_residual"]=dual_seed.primal_residual
    end
    set_optimizer_attribute(model,"max_wall_time",rounded_ac_time_limit(seconds,deadline))
    guard_policy=fixed_shunts ? AC_PRIMAL_GUARD_POLICY :
        (continuous_candidate_guard ? AC_CANDIDATE_GUARD_POLICY : "off")
    guard_phase=fixed_shunts ? "rounded_shunts" : "continuous_shunt_candidate"
    expected_start=audit_native_initialization ?
        (variables=all_variables(model),values=Float64[start_value(v) for v in all_variables(model)]) : nothing
    guard=install_ac_primal_guard!(model;policy=guard_policy,phase=guard_phase,
        min_iterations=0,window=2,objective_relative_range=fixed_shunts ? 1.0 : 1e-7,
        primal_tolerance=primal_target,expected_start)
    optimize!(model,_differentiation_backend=GO3.MathOptSymbolicAD.DefaultBackend())
    guard_record=finish_ac_primal_guard!(model,guard)
    has_values(model) || return point,Dict("phase"=>phase,"complete_finite_point"=>true,
        "max_primal_residual"=>ac_primal_residual(model,point),"termination"=>string(termination_status(model)),
        "wall_seconds"=>time()-started,"fallback"=>true,"start"=>record,"returned_point"=>false,
        "native_primal_guard"=>guard_record)
    proposed=capture_complete_ac_primal(model)
    before=ac_primal_residual(model,point);after=ac_primal_residual(model,proposed)
    accept=after<=before
    chosen=accept ? proposed : point
    correction_phase_event(phase,"end";details=Dict("wall_seconds"=>time()-started,
        "before_residual"=>before,"selected_residual"=>min(before,after),
        "termination"=>string(termination_status(model))))
    chosen,merge(model_stats(model;include_bound_and_gap=false),Dict("phase"=>phase,"complete_finite_point"=>true,
        "max_primal_residual"=>min(before,after),"before_residual"=>before,
        "wall_seconds"=>time()-started,"fallback"=>true,"start"=>record,
        "native_primal_guard"=>guard_record,"returned_point"=>true,"accepted"=>accept,
        "rollback"=>!accept,"certificate_scope"=>"primal feasibility only, not optimality"))
end

function correction_dual_seed(model,point;primal_target=1e-10)
    has_values(model) && has_duals(model) || return nothing
    residual=ac_primal_residual(model,point)
    residual<=primal_target || return nothing
    native_point=capture_complete_ac_primal(model)
    native_point.variables==point.variables && native_point.values==point.values || return nothing
    multipliers=capture_complete_ac_dual(model)
    removed=Set{ConstraintRef}()
    for v in model[:shunt_step]
        has_lower_bound(v) && push!(removed,LowerBoundRef(v))
        has_upper_bound(v) && push!(removed,UpperBoundRef(v))
    end
    (point=multipliers,removed_bounds=removed,primal_residual=residual)
end

function round_correction_shunts!(model,point,shunt_domains)
    point.variables==all_variables(model) || error("Incomplete shunt-rounding point")
    lookup=Dict(zip(point.variables,point.values));settings=Dict{String,Float64}()
    for (u,(lo,hi)) in shunt_domains
        v=model[:shunt_step][u]
        step=clamp(round(lookup[v]),lo,hi)
        isinteger(step) && lo<=step<=hi || error("Invalid source-domain discrete shunt setting")
        fix(v,step;force=true);set_start_value(v,step)
        lookup[v]=step;settings[u]=step
    end
    (variables=point.variables,values=[lookup[v] for v in point.variables]),settings
end

function continuous_then_rounded_correction(model,optimizer,point,shunt_domains;
        deadline,slp_seconds,lp_seconds,max_rounds,fallback_seconds,threads,diagnostic_dir,lp_solver,
        hot_repair=false,preserve_primal_continuation=false,audit_native_initialization=false)
    phases=Any[]
    primal_target=1e-10 # stricter internal search target, not a changed final tolerance
    function linear_stage(point,name,seconds)
        correction_phase_event(name,"begin";details=Dict("budget_seconds"=>seconds,
            "remaining_hour_seconds"=>deadline-time(),"lp_solver"=>lp_solver))
        result,phase=ac_linear_correction(model,point;deadline=min(deadline,time()+seconds),
            max_rounds,lp_seconds,threads,log_dir=diagnostic_dir,lp_solver,primal_target)
        phase["phase"]=name
        push!(phases,phase)
        correction_phase_event(name,"end";details=Dict("wall_seconds"=>phase["wall_seconds"],
            "residual"=>phase["max_primal_residual"],"accepted_steps"=>phase["accepted_steps"],
            "termination"=>phase["termination"]))
        result
    end
    # This is a candidate relaxation only. Never publish it as a discrete point.
    # Reserve at least 40% of the remaining hour for rounding and original-model repair.
    point=linear_stage(point,"continuous_shunt_correction",slp_seconds)
    if ac_primal_residual(model,point)>primal_target && deadline-time()>8
        seconds=min(fallback_seconds,0.6*max(0.0,deadline-time()-2.0))
        point,phase=correction_ipopt_fallback!(model,optimizer,point;deadline,seconds,max_iter=600,
            phase="continuous_shunt_fallback",allow_unfixed_shunts=true,barrier_strategy="monotone",primal_target,
            continuous_candidate_guard=hot_repair,preserve_primal_continuation,audit_native_initialization)
        push!(phases,phase)
    end
    continuous_residual=ac_primal_residual(model,point)
    dual_seed=hot_repair ? correction_dual_seed(model,point;primal_target) : nothing
    point,settings=round_correction_shunts!(model,point,shunt_domains)
    correction_phase_event("round_shunts","complete";details=Dict("count"=>length(settings),
        "continuous_candidate_residual"=>continuous_residual,
        "rounded_candidate_residual"=>ac_primal_residual(model,point),
        "continuous_candidate_is_final"=>false,"same_interval_dual_seed_available"=>dual_seed!==nothing))
    if dual_seed===nothing
        point=linear_stage(point,"rounded_shunt_correction",min(slp_seconds,max(0.0,0.4*(deadline-time()))))
    else
        # The two preceding full attempts obtained no accepted rounded LP step.
        # Use the already-audited same-hour NLP initialization directly instead.
        push!(phases,Dict("phase"=>"rounded_shunt_correction","wall_seconds"=>0.0,
            "termination"=>"skipped_for_same_interval_primal_dual_repair",
            "max_primal_residual"=>ac_primal_residual(model,point),"accepted_steps"=>0,"rounds"=>Any[],
            "dual_certificate_claimed"=>false))
    end
    if ac_primal_residual(model,point)>primal_target && deadline-time()>5
        seconds=correction_fallback_budget(fallback_seconds,deadline)
        point,phase=correction_ipopt_fallback!(model,optimizer,point;deadline,seconds,max_iter=600,
            phase="rounded_shunt_fallback",barrier_strategy="monotone",primal_target,dual_seed,
            preserve_primal_continuation,audit_native_initialization)
        push!(phases,phase)
    end
    point,phases,settings
end

function compute_corrected_ac(working,source,i;on_status,real_power,reactive_power,curves,
        optimizer,deadline,interval_seed=nothing,slp_seconds=15.0,lp_seconds=4.0,
        max_rounds=8,fallback_seconds=12.0,threads=4,diagnostic_dir=nothing,adaptive_budget=false,
        policy=AC_CORRECTION_POLICY,lp_solver="simplex")
    policy in AC_CORRECTION_POLICIES || error("Unknown correction pipeline policy")
    began=time()
    model,reserve=build_reserve_aware_ac(working,source,i;on_status,real_power,curves)
    set_optimizer(model,optimizer)
    start_record=initialize_ac_correction!(model,source,i,real_power,reactive_power,interval_seed)
    shunt_domains=Dict(u=>(lower_bound(model[:shunt_step][u]),upper_bound(model[:shunt_step][u])) for u in source.shunt_ids)
    settings=Dict{String,Float64}()
    if policy==AC_CORRECTION_POLICY
        for u in source.shunt_ids
            v=model[:shunt_step][u]
            step=clamp(round(start_value(v)),shunt_domains[u]...)
            isinteger(step) || error("Source shunt domain has no selected integral point")
            settings[u]=step;fix(v,step;force=true);set_start_value(v,step)
        end
    end
    point=(variables=all_variables(model),values=Float64[start_value(v) for v in all_variables(model)])
    built=time()-began
    revisited=false
    if policy in (AC_CORRECTION_CONTINUOUS_POLICY,AC_CORRECTION_HOT_REPAIR_POLICY,AC_CORRECTION_CONTINUATION_POLICY)
        point,phases,settings=continuous_then_rounded_correction(model,optimizer,point,shunt_domains;
            deadline,slp_seconds,lp_seconds,max_rounds,fallback_seconds,threads,diagnostic_dir,lp_solver,
            hot_repair=policy in (AC_CORRECTION_HOT_REPAIR_POLICY,AC_CORRECTION_CONTINUATION_POLICY),
            preserve_primal_continuation=policy==AC_CORRECTION_CONTINUATION_POLICY && interval_seed!==nothing,
            audit_native_initialization=policy==AC_CORRECTION_CONTINUATION_POLICY)
    else
    correction_phase_event("linearized_correction","begin";details=Dict(
        "budget_seconds"=>slp_seconds,"remaining_hour_seconds"=>deadline-time()))
    point,slp=ac_linear_correction(model,point;deadline=min(deadline,time()+slp_seconds),
        max_rounds,lp_seconds,threads,log_dir=diagnostic_dir,lp_solver)
    correction_phase_event("linearized_correction","end";details=Dict(
        "wall_seconds"=>slp["wall_seconds"],"residual"=>slp["max_primal_residual"],
        "accepted_steps"=>slp["accepted_steps"],"termination"=>slp["termination"]))
    phases=Any[slp]
    if slp["max_primal_residual"]>AC_POINT_RESIDUAL_TOLERANCE && deadline-time()>3
        seconds=correction_fallback_budget(fallback_seconds,deadline;adaptive=adaptive_budget)
        point,phase=correction_ipopt_fallback!(model,optimizer,point;deadline,seconds,
            max_iter=adaptive_budget ? 600 : 120)
        push!(phases,phase)
    end
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
            max_rounds=3,lp_seconds,threads,log_dir=diagnostic_dir,lp_solver)
        phase["phase"]="shunt_revisit_relaxation";push!(phases,phase)
        lookup=Dict(zip(relaxed.variables,relaxed.values))
        for u in source.shunt_ids
            v=model[:shunt_step][u];step=clamp(round(lookup[v]),shunt_domains[u]...)
            fix(v,step;force=true);lookup[v]=step;settings[u]=step
        end
        point=(variables=relaxed.variables,values=[lookup[v] for v in relaxed.variables])
        point,phase=ac_linear_correction(model,point;deadline,max_rounds,lp_seconds,threads,log_dir=diagnostic_dir,lp_solver)
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
    if adaptive_budget && revisited && residual>AC_POINT_RESIDUAL_TOLERANCE && deadline-time()>5
        # Rounding creates a new fixed-shunt subproblem. Its repair may use the
        # remaining hourly allocation, always from the current attempt's point.
        seconds=correction_fallback_budget(fallback_seconds,deadline)
        point,phase=correction_ipopt_fallback!(model,optimizer,point;deadline,seconds,
            phase="post_revisit_fixed_shunt_fallback",max_iter=600)
        push!(phases,phase)
        residual=ac_primal_residual(model,point)
    end
    end # original fixed-first policy
    residual=ac_primal_residual(model,point)
    push!(phases,Dict("phase"=>"selected_correction_point","complete_finite_point"=>true,
        "max_primal_residual"=>residual,"wall_seconds"=>0.0,
        "certificate_scope"=>"local primal only; full final verification still mandatory"))
    all(isinteger,values(settings)) || error("Correction returned nonintegral shunts")
    model.ext[:correction_point]=point
    model.ext[:reserve_ac]["phases"]=phases
    model.ext[:reserve_ac]["interval_primal_start"]=start_record
    model.ext[:reserve_ac]["correction"]=Dict("policy"=>policy,"lp_solver"=>lp_solver,
        "internal_primal_target"=>(policy==AC_CORRECTION_POLICY ? AC_POINT_RESIDUAL_TOLERANCE : 1e-10),
        "final_acceptance_tolerance"=>AC_POINT_RESIDUAL_TOLERANCE,
        "model_build_and_initialization_seconds"=>built,"total_seconds"=>time()-began,
        "shunts_revisited"=>revisited,"final_discrete_settings"=>settings,
        "source_bounds_changed"=>false,"sequential_temporal_bounds"=>true,
        "final_model_residual"=>residual,"threads"=>threads,"external_solution_read"=>false)
    model.ext[:reserve_ac]["correction"]["adaptive_hour_budget"]=adaptive_budget
    lookup=Dict(zip(point.variables,point.values))
    model.ext[:reserve_ac]["reserve_cost_at_solution"]=value(v->lookup[v],reserve.cost)
    result=extract_ac_correction_result(model,working,on_status,real_power,point)
    model,result
end
