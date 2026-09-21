# Project-owned reserve/AC co-optimization adapter. It calls the pinned
# GOC3Benchmark.jl variable, source-data, model and extraction helpers.
# Its reserve rows follow the source formulation and upstream reserves.jl;
# the two-solve shunt-rounding workflow follows upstream opf.jl.
# GOC3Benchmark attribution and BSD-3 terms: licenses/GOC3Benchmark.BSD-3.txt.

function add_source_reserve_allocation!(model,input,i,p_actual,q_actual,on,curves)
    ids=input.sdd_ids
    r=GO3.add_reserve_variables!(model,input,i)
    sl=GO3.add_reserve_shortfall_variables!(model,input,i)
    rgu_sl,rgd_sl,scr_sl,nsc_sl,rru_sl,rrd_sl,qru_sl,qrd_sl=sl
    caps=GO3._get_max_reserves(input)
    costs=GO3._get_reserve_costs(input)
    penalties=GO3._get_reserve_shortfall_penalties(input)
    zones=GO3._get_sdd_in_zones(input)
    for uid in ids
        d,ts=input.sdd_lookup[uid],input.sdd_ts_lookup[uid]
        u=on[uid]
        u in (0,1) || error("Reserve co-optimization requires exact fixed commitment")
        psu,psd=curves.p_su[uid][i],curves.p_sd[uid][i]
        active=u+curves.supc_status[uid][i]+curves.sdpc_status[uid][i]
        active in (0,1) || error("Overlapping on/startup/shutdown reactive capability")
        pon=p_actual[uid]-psu-psd
        q=q_actual[uid]
        @constraint(model,r.p_rgu[uid] <= caps.p_rgu_max[uid]*u)
        @constraint(model,r.p_rgd[uid] <= caps.p_rgd_max[uid]*u)
        @constraint(model,r.p_rgu[uid]+r.p_scr[uid] <= caps.p_scr_max[uid]*u)
        @constraint(model,r.p_nsc[uid] <= caps.p_nsc_max[uid]*(1-u))
        @constraint(model,r.p_rgu[uid]+r.p_scr[uid]+r.p_rru_on[uid] <= caps.p_rru_on_max[uid]*u)
        @constraint(model,r.p_nsc[uid]+r.p_rru_off[uid] <= caps.p_rru_off_max[uid]*(1-u))
        @constraint(model,r.p_rgd[uid]+r.p_rrd_on[uid] <= caps.p_rrd_on_max[uid]*u)
        @constraint(model,r.p_rrd_off[uid] <= caps.p_rrd_off_max[uid]*(1-u))
        up=r.p_rgu[uid]+r.p_scr[uid]+r.p_rru_on[uid]
        down=r.p_rgd[uid]+r.p_rrd_on[uid]
        prod=d["device_type"]=="producer"
        hi,lo=prod ? (up,down) : (down,up)
        @constraint(model,pon+hi <= ts["p_ub"][i]*u)
        @constraint(model,pon-lo >= ts["p_lb"][i]*u)
        offline=prod ? r.p_nsc[uid]+r.p_rru_off[uid] : r.p_rrd_off[uid]
        @constraint(model,psu+psd+offline <= ts["p_ub"][i]*(1-u))
        if prod
            fix(r.p_rrd_off[uid],0.0;force=true)
        else
            fix(r.p_nsc[uid],0.0;force=true)
            fix(r.p_rru_off[uid],0.0;force=true)
        end
        qhi,qlo=prod ? (r.q_qru[uid],r.q_qrd[uid]) : (r.q_qrd[uid],r.q_qru[uid])
        @constraint(model,q+qhi <= ts["q_ub"][i]*active)
        @constraint(model,q-qlo >= ts["q_lb"][i]*active)
        if d["q_bound_cap"]==1
            @constraint(model,q+qhi <= d["q_0_ub"]*active+d["beta_ub"]*p_actual[uid])
            @constraint(model,q-qlo >= d["q_0_lb"]*active+d["beta_lb"]*p_actual[uid])
        elseif d["q_linear_cap"]==1
            fix(r.q_qru[uid],0.0;force=true)
            fix(r.q_qrd[uid],0.0;force=true)
        end
    end
    # The maximum producer dispatch is endogenous, including any fixed startup
    # or shutdown power. This epigraph is exact for nonnegative source penalties.
    peak=@variable(model,reserve_peak[z in input.azr_ids] >= 0)
    for z in input.azr_ids
        members=zones.sdd_in_azone[z]
        consumers=zones.c_sdd_in_azone[z]
        producers=zones.p_sdd_in_azone[z]
        isempty(producers) && fix(peak[z],0.0;force=true)
        for uid in producers
            @constraint(model,peak[z] >= p_actual[uid])
        end
        zone=input.azr_lookup[z]
        all(zone[k]>=0 for k in ("REG_UP","REG_DOWN","SYN","NSYN")) ||
            error("Negative endogenous reserve-requirement coefficient is unsupported")
        load=sum((p_actual[uid] for uid in consumers);init=0.0)
        req_up,req_down=zone["REG_UP"]*load,zone["REG_DOWN"]*load
        @constraint(model,sum((r.p_rgu[u] for u in members);init=0.0)+rgu_sl[z] >= req_up)
        @constraint(model,sum((r.p_rgd[u] for u in members);init=0.0)+rgd_sl[z] >= req_down)
        @constraint(model,sum((r.p_rgu[u]+r.p_scr[u] for u in members);init=0.0)+scr_sl[z] >=
            req_up+zone["SYN"]*peak[z])
        @constraint(model,sum((r.p_rgu[u]+r.p_scr[u]+r.p_nsc[u] for u in members);init=0.0)+nsc_sl[z] >=
            req_up+(zone["SYN"]+zone["NSYN"])*peak[z])
        @constraint(model,sum((r.p_rru_on[u]+r.p_rru_off[u] for u in members);init=0.0)+rru_sl[z] >=
            input.azr_ts_lookup[z]["RAMPING_RESERVE_UP"][i])
        @constraint(model,sum((r.p_rrd_on[u]+r.p_rrd_off[u] for u in members);init=0.0)+rrd_sl[z] >=
            input.azr_ts_lookup[z]["RAMPING_RESERVE_DOWN"][i])
    end
    for z in input.rzr_ids
        members=zones.sdd_in_rzone[z]
        @constraint(model,sum((r.q_qru[u] for u in members);init=0.0)+qru_sl[z] >=
            input.rzr_ts_lookup[z]["REACT_UP"][i])
        @constraint(model,sum((r.q_qrd[u] for u in members);init=0.0)+qrd_sl[z] >=
            input.rzr_ts_lookup[z]["REACT_DOWN"][i])
    end
    reserve_cost=AffExpr(0.0)
    for (rv,cv) in ((:p_rgu,:c_rgu),(:p_rgd,:c_rgd),(:p_scr,:c_scr),(:p_nsc,:c_nsc),
            (:p_rru_on,:c_rru_on),(:p_rrd_on,:c_rrd_on),(:p_rru_off,:c_rru_off),
            (:p_rrd_off,:c_rrd_off),(:q_qru,:c_qru),(:q_qrd,:c_qrd))
        for uid in ids
            add_to_expression!(reserve_cost,input.dt[i]*getproperty(costs,cv)[uid][i],
                getproperty(r,rv)[uid])
        end
    end
    for (variables,pk,zids) in ((rgu_sl,:z_rgu,input.azr_ids),(rgd_sl,:z_rgd,input.azr_ids),
            (scr_sl,:z_scr,input.azr_ids),(nsc_sl,:z_nsc,input.azr_ids),
            (rru_sl,:z_rru,input.azr_ids),(rrd_sl,:z_rrd,input.azr_ids),
            (qru_sl,:z_qru,input.rzr_ids),(qrd_sl,:z_qrd,input.rzr_ids))
        for z in zids
            penalty=getproperty(penalties,pk)[z]
            penalty >= 0 || error("Negative reserve-shortfall penalty is unsupported")
            add_to_expression!(reserve_cost,input.dt[i]*penalty,variables[z])
        end
    end
    (variables=r,shortfalls=sl,cost=reserve_cost,peak=peak)
end

function fixed_schedule_power_curves(input,schedule)
    su,psu,sd,psd=GO3.get_supc_sdpc_lookups(input,schedule.on_status)
    (supc_status=su,p_su=psu,sdpc_status=sd,p_sd=psd)
end

function build_reserve_aware_ac(working,source,i;on_status,real_power,curves)
    args=Dict{String,Any}("on_status"=>on_status,"real_power"=>real_power,
        "penalize_power_deviation"=>true,"relax_power_balance"=>true,
        "relax_p_balance"=>true,"relax_q_balance"=>true,"fix_real_power"=>false,
        # A candidate-search restriction required for the campaign's physical
        # feasibility gate. Source reserve penalties can outweigh soft balance
        # penalties; buying an imbalance is not an acceptable final candidate.
        # This tightens, never relaxes, the original source feasibility domain.
        "max_balance_violation"=>0.0,
        "allow_switching"=>false,"fix_shunt_steps"=>false,"relax_thermal_limits"=>true)
    model=GO3.get_ac_opf_model(working,i;args=args)
    active_ids=Set(axes(model[:p_sdd],1))
    for uid in source.sdd_ids
        if !(uid in active_ids) && (on_status[uid] != 0 ||
                curves.p_su[uid][i] != 0 || curves.p_sd[uid][i] != 0)
            error("AC filtering removed nonzero source device $uid at interval $i")
        end
    end
    p=Dict(uid => uid in active_ids ? model[:p_sdd][uid] : 0.0 for uid in source.sdd_ids)
    q=Dict(uid => uid in active_ids ? model[:q_sdd][uid] : 0.0 for uid in source.sdd_ids)
    # Reserve headroom always uses ORIGINAL bounds, never ramp-tightened ones.
    reserve=add_source_reserve_allocation!(model,source,i,p,q,on_status,curves)
    set_objective_function(model,objective_function(model)-reserve.cost)
    model.ext[:reserve_ac]=Dict("policy"=>"source_joint_reserves_in_ac_v1",
        "original_bounds"=>true,"products"=>10,"endogenous_requirements"=>true,
        "physical_balance_policy"=>"zero_slack_candidate_restriction",
        "source_interval_duration"=>source.dt[i])
    model,reserve
end

function compute_reserve_aware_ac(working,source,i;on_status,real_power,curves,
        optimizer,set_silent=false,shunt_primal_start="off",audit_phases=false,
        rounded_seconds=nothing,work_deadline=Inf,rounded_max_iter=500,interval_seed=nothing,
        numerical_recovery="off",recovery_seconds=360.0,recovery_max_iter=1000,
        primal_guard="off",numerics_policy="legacy_v1")
    shunt_primal_start in ("off","within_interval_complete_v1","within_interval_primal_dual_v1") ||
        error("Unknown AC primal start policy")
    shunt_primal_start=="within_interval_primal_dual_v1" && !audit_phases &&
        error("Primal-dual transfer requires an audited first point")
    numerical_recovery in ("off","adaptive_barrier_on_failed_residual_v1") ||
        error("Unknown AC numerical recovery policy")
    numerical_recovery=="off" || audit_phases || error("AC recovery requires phase residual audits")
    primal_guard in ("off",AC_PRIMAL_GUARD_POLICY) || error("Unknown AC primal guard policy")
    primal_guard=="off" || audit_phases || error("AC primal guard requires phase residual audits")
    if numerical_recovery!="off"
        recovery_seconds isa Real && !(recovery_seconds isa Bool) &&
            isfinite(recovery_seconds) && recovery_seconds>0 || error("Invalid AC recovery budget")
        recovery_max_iter isa Integer && !(recovery_max_iter isa Bool) &&
            recovery_max_iter>0 || error("Invalid AC recovery iteration limit")
    end
    build_started=time()
    model,reserve=build_reserve_aware_ac(working,source,i;on_status,real_power,curves)
    model.ext[:reserve_ac]["model_build_seconds"]=time()-build_started
    numerical_calls=Any[]
    model.ext[:reserve_ac]["numerical_calls"]=numerical_calls
    set_optimizer(model,optimizer)
    configure_ac_numerics!(model,numerics_policy)
    set_silent && JuMP.set_silent(model)
    if interval_seed!==nothing
        record=apply_ac_interval_start!(model,source,i,interval_seed,real_power)
        model.ext[:reserve_ac]["interval_primal_start"]=record
        println("GO3_AC_INTERVAL_START ",JSON.json(record));flush(stdout)
    else
        model.ext[:reserve_ac]["interval_primal_start"]=Dict("policy"=>"cold_defaults",
            "target_interval"=>i,"external_solution_read"=>false)
    end
    # Use the configured Ipopt accuracy/iteration/wall limits. Do not use the
    # upstream early callback, which may stop at a 1e-3 primal residual.
    phase_started=time()
    push!(numerical_calls,optimize_audited_ac!(model;policy=numerics_policy,
        interval=i,phase="continuous_shunts",deadline=work_deadline))
    has_values(model) || error("Reserve-aware AC solve returned no primal point")
    point=(audit_phases || shunt_primal_start!="off") ? capture_complete_ac_primal(model) : nothing
    phases=Any[]
    function record_phase(name,phase_started,point)
        audit_phases || return
        phase=merge(model_stats(model),Dict("phase"=>name,
            "wall_seconds"=>time()-phase_started,"complete_finite_point"=>true,
            "wall_limit_seconds"=>get_optimizer_attribute(model,"max_wall_time")))
        audit_started=time()
        phase["max_primal_residual"]=ac_primal_residual(model,point)
        phase["residual_audit_seconds"]=time()-audit_started
        phase["wall_through_audit_seconds"]=time()-phase_started
        push!(phases,phase)
        println("GO3_AC_PHASE ",JSON.json(merge(Dict("interval"=>i),phase)));flush(stdout)
    end
    record_phase("continuous_shunts",phase_started,point)
    dual_point=nothing
    if shunt_primal_start=="within_interval_primal_dual_v1" && has_duals(model) &&
            last(phases)["max_primal_residual"]<=AC_POINT_RESIDUAL_TOLERANCE &&
            termination_status(model) in (MOI.LOCALLY_SOLVED,MOI.ALMOST_LOCALLY_SOLVED)
        dual_point=capture_complete_ac_dual(model)
    end
    removed_bounds=Set{ConstraintRef}()
    if dual_point!==nothing
        for uid in source.shunt_ids
            v=model[:shunt_step][uid]
            has_lower_bound(v) && push!(removed_bounds,LowerBoundRef(v))
            has_upper_bound(v) && push!(removed_bounds,UpperBoundRef(v))
        end
    end
    # Read all values before modifying bounds, which invalidates JuMP's result.
    rounded=Dict(uid=>round(value(model[:shunt_step][uid])) for uid in source.shunt_ids)
    for uid in source.shunt_ids
        fix(model[:shunt_step][uid],rounded[uid];force=true)
    end
    if shunt_primal_start!="off"
        start_record=restore_complete_ac_primal!(model,point)
        start_record["requested_policy"]=shunt_primal_start
        start_record["dual_transfer_used"]=dual_point!==nothing
        if dual_point!==nothing
            fixed=Set(FixRef(model[:shunt_step][uid]) for uid in source.shunt_ids)
            start_record["dual_start"]=restore_complete_ac_dual!(model,dual_point;
                new_fixed=fixed,removed_bounds=removed_bounds)
            start_record["dual_or_basis_start"]=true
            start_record["basis_start"]=false
        elseif shunt_primal_start=="within_interval_primal_dual_v1"
            start_record["dual_skip_reason"]="First point was not a converged residual-verified point with duals; retained complete primal only"
        end
        model.ext[:reserve_ac]["shunt_primal_start"]=start_record
        println("GO3_AC_PRIMAL_START ",JSON.json(merge(Dict("interval"=>i),start_record)));flush(stdout)
    end
    if rounded_seconds!==nothing
        set_optimizer_attribute(model,"max_wall_time",rounded_ac_time_limit(rounded_seconds,work_deadline))
        set_optimizer_attribute(model,"max_iter",rounded_max_iter)
    end
    guarded_phases=Any[]
    guard=install_ac_primal_guard!(model;policy=primal_guard,phase="rounded_shunts")
    phase_started=time()
    push!(numerical_calls,optimize_audited_ac!(model;policy=numerics_policy,
        interval=i,phase="rounded_shunts",deadline=work_deadline))
    has_values(model) || error("Rounded-shunt reserve-aware AC solve returned no primal point")
    guard_record=finish_ac_primal_guard!(model,guard)
    push!(guarded_phases,guard_record)
    primal_guard!="off" && (println("GO3_AC_PRIMAL_GUARD ",JSON.json(merge(Dict("interval"=>i),guard_record)));flush(stdout))
    audit_phases && record_phase("rounded_shunts",phase_started,capture_complete_ac_primal(model))
    recovery_record=Dict{String,Any}("policy"=>numerical_recovery,"attempted"=>false,
        "reason"=>numerical_recovery=="off" ? "disabled" : "rounded_point_passed_local_residual_screen")
    if ac_recovery_required(phases,numerical_recovery)
        if work_deadline-time()<=3.0
            recovery_record["reason"]="insufficient_remaining_work_budget"
        else
            point=capture_complete_ac_primal(model)
            recovery_record=prepare_ac_recovery!(model,optimizer,point;
                seconds=recovery_seconds,deadline=work_deadline,max_iter=recovery_max_iter)
            configure_ac_numerics!(model,numerics_policy)
            set_silent && JuMP.set_silent(model)
            # Recompute immediately before optimize: mapping/audit time counts.
            allowance=rounded_ac_time_limit(recovery_seconds,work_deadline)
            set_optimizer_attribute(model,"max_wall_time",allowance)
            recovery_record["options"]["max_wall_time"]=allowance
            println("GO3_AC_NUMERICAL_RECOVERY ",JSON.json(merge(Dict("interval"=>i),recovery_record)));flush(stdout)
            guard=install_ac_primal_guard!(model;policy=primal_guard,phase="numerical_recovery")
            phase_started=time()
            push!(numerical_calls,optimize_audited_ac!(model;policy=numerics_policy,
                interval=i,phase="numerical_recovery",deadline=work_deadline))
            has_values(model) || error("AC numerical recovery returned no primal point")
            guard_record=finish_ac_primal_guard!(model,guard)
            push!(guarded_phases,guard_record)
            primal_guard!="off" && (println("GO3_AC_PRIMAL_GUARD ",JSON.json(merge(Dict("interval"=>i),guard_record)));flush(stdout))
            record_phase("numerical_recovery",phase_started,capture_complete_ac_primal(model))
        end
    end
    model.ext[:reserve_ac]["numerical_recovery"]=recovery_record
    model.ext[:reserve_ac]["primal_guard"]=Dict("policy"=>primal_guard,"phases"=>guarded_phases)
    audit_phases && (model.ext[:reserve_ac]["phases"]=phases)
    model.ext[:reserve_ac]["reserve_cost_at_solution"]=value(reserve.cost)
    result=GO3.extract_data_from_model(model,working,on_status,real_power;
        tolerance=1e-6,allow_switching=false)
    model,result
end
