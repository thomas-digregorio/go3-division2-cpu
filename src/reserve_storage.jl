# Storage-only orchestration of the pinned, unchanged per-interval reserve LP.
# The upstream horizon wrapper retains every (model, awards) pair even when
# return_models=false. This path keeps numeric awards, then releases each model.
const RESERVE_STORAGE_POLICIES=("legacy_horizon_v1","bounded_lifetime_v1")
const RESERVE_STORAGE_FIELDS=(:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,
    :p_rru_off,:p_rrd_on,:p_rrd_off,:q_qru,:q_qrd)
const RESERVE_ALLOCATION_PRIMAL_TOLERANCE=1e-8

struct ReserveAllocationFailure <: Exception
    statistics::Dict{String,Any}
end
function Base.showerror(io::IO,e::ReserveAllocationFailure)
    s=e.statistics
    print(io,"Reserve allocation failed at interval ",s["interval"],": ",
        s["failure_reason"],"; termination=",s["termination"],
        "; primal_status=",s["primal_status"],"; result_count=",s["result_count"],
        "; no unchecked awards exported")
end

function reserve_result_diagnostics(model,i)
    # In particular, do not ask for objective_value or any VariablePrimal when
    # ResultCount is zero. A time limit is not evidence of infeasibility.
    count=safe_stat(()->result_count(model))
    status=safe_stat(()->string(primal_status(model)))
    Dict{String,Any}("interval"=>i,
        "termination"=>safe_stat(()->string(termination_status(model))),
        "primal_status"=>status,"result_count"=>count,
        "raw_status"=>safe_stat(()->raw_status(model)),
        "has_feasible_primal"=>count isa Integer && count>0 && status=="FEASIBLE_POINT",
        "objective"=>nothing,"solver_seconds"=>safe_stat(()->solve_time(model)),
        "variables"=>num_variables(model),
        "constraints"=>num_constraints(model;count_variable_in_set_constraints=true),
        "maximum_model_residual"=>nothing,
        "audit_scope"=>"original interval LP before pinned projection; full-case verification still required",
        "primal_residual_tolerance"=>RESERVE_ALLOCATION_PRIMAL_TOLERANCE,
        "extraction_attempted"=>false,"projection_completed"=>false,
        "accepted"=>false,"failure_reason"=>nothing)
end

function reserve_primal_guard!(model,stats)
    if !stats["has_feasible_primal"]
        stats["failure_reason"]="solver returned no feasible primal point"
        return false
    end
    point=capture_complete_ac_primal(model)
    residual=ac_primal_residual(model,point)
    stats["maximum_model_residual"]=residual
    if residual>RESERVE_ALLOCATION_PRIMAL_TOLERANCE
        stats["failure_reason"]="returned primal failed the unchanged original-row residual tolerance"
        return false
    end
    objective=objective_value(model)
    isfinite(objective) || error("Nonfinite reserve objective")
    stats["objective"]=objective
    true
end

function current_schedule_reserve_handoff(input,schedule)
    # These awards are only an initial candidate: construct_solution_dict may
    # project dispatch, so scheduling feasibility is NOT full-case feasibility.
    ids=Set(input.sdd_ids); nt=length(input.periods)
    for field in RESERVE_STORAGE_FIELDS
        values_=getproperty(schedule,field)
        Set(keys(values_))==ids || error("Joint schedule reserve identities differ from source")
        all(length(values_[u])==nt && all(isfinite,values_[u]) for u in ids) ||
            error("Incomplete or nonfinite joint schedule reserve awards")
    end
    schedule,Dict("policy"=>"use_joint_schedule_unverified",
        "source"=>"current_attempt_joint_schedule","external_solution_read"=>false,
        "initial_solution_verified"=>false,"optimization_calls"=>0,
        "devices"=>length(ids),"periods"=>nt,"reserve_fields"=>length(RESERVE_STORAGE_FIELDS),
        "final_reserve_optimization_required"=>true,"full_case_checks_required"=>true,
        "source_values_changed"=>false)
end

function _store_reserve_interval!(awards,input,i,records,curves,optimizer)
    ids=input.sdd_ids
    on=Dict(u=>records[u]["on_status"][i] for u in ids)
    su=Dict(u=>curves.supc_status[u][i] for u in ids)
    sd=Dict(u=>curves.sdpc_status[u][i] for u in ids)
    psu=Dict(u=>curves.p_su[u][i] for u in ids)
    psd=Dict(u=>curves.p_sd[u][i] for u in ids)
    opf=Dict("simple_dispatchable_device"=>Dict(u=>Dict(
        "p_on"=>records[u]["p_on"][i],"q"=>records[u]["q"][i]) for u in ids))
    # The pinned upstream wrapper extracts unconditionally, even with zero
    # results. Use its identical constructor and projection, interposing a
    # status/residual guard. Do not edit the pinned upstream or its source rows.
    model=GO3.make_reserve_model(input,i,opf,on,su,sd,psu,psd)
    set_optimizer(model,optimizer)
    set_silent(model)
    solve_error=nothing
    try
        optimize!(model)
    catch e
        solve_error=sprint(showerror,e)
    end
    stats=reserve_result_diagnostics(model,i)
    stats["native_exception"]=solve_error
    try
        if solve_error!==nothing
            stats["failure_reason"]="native optimize! exception: "*solve_error
        elseif reserve_primal_guard!(model,stats)
            stats["extraction_attempted"]=true
            data=GO3.extract_data_from_reserve_model(input,model)
            data=GO3.project_reserves_onto_bounds(input,i,data,opf,on,su,sd,psu,psd)
            stats["projection_completed"]=true
            for field in RESERVE_STORAGE_FIELDS, uid in ids
                v=Float64(getproperty(data,field)[uid])
                isfinite(v) || error("Nonfinite extracted reserve award at interval $i: $uid/$field")
                getproperty(awards,field)[uid][i]=v
            end
            stats["accepted"]=true
        end
    catch e
        stats["failure_reason"]="reserve primal audit/extraction failed: "*sprint(showerror,e)
    end
    # No strong solver/model reference may cross this function boundary.
    WeakRef(model),stats
end

function source_reserve_allocation(input,solution;policy="legacy_horizon_v1",
        optimizer_for_interval=i->HiGHS.Optimizer,interval_callback=nothing)
    policy in RESERVE_STORAGE_POLICIES || error("Unknown reserve storage policy")
    if policy=="legacy_horizon_v1"
        awards=GO3.calculate_reserves_from_generation(input,solution;
            optimizer=optimizer_for_interval(0))
        return awards,Dict("policy"=>policy,"upstream_horizon_wrapper"=>true,
            "source_values_changed"=>false,"rows_or_columns_eliminated"=>0)
    end
    # This campaign already uses one Julia thread. Do not silently change a
    # hypothetical parallel registered protocol to sequential execution.
    Threads.nthreads()==1 || error("Bounded reserves require the registered single Julia thread")
    records=Dict(x["uid"]=>x for x in solution["time_series_output"]["simple_dispatchable_device"])
    Set(keys(records))==Set(input.sdd_ids) || error("Reserve candidate device identities differ from source")
    length(records)==length(solution["time_series_output"]["simple_dispatchable_device"]) ||
        error("Duplicate reserve candidate device identity")
    on=Dict(u=>records[u]["on_status"] for u in input.sdd_ids)
    su,psu,sd,psd=GO3.get_supc_sdpc_lookups(input,on)
    curves=(supc_status=su,p_su=psu,sdpc_status=sd,p_sd=psd)
    nt=length(input.periods)
    awards=NamedTuple{RESERVE_STORAGE_FIELDS}(Tuple(
        Dict(u=>Vector{Float64}(undef,nt) for u in input.sdd_ids) for _ in RESERVE_STORAGE_FIELDS))
    intervals=Any[]
    for i in input.periods
        # The worker factory rechecks its existing global deadline for each LP.
        optimizer=optimizer_for_interval(i)
        weak_model,stats=_store_reserve_interval!(awards,input,i,records,curves,optimizer)
        started=time()
        GC.gc(true)
        stats["collection_seconds"]=time()-started
        stats["model_released"]=weak_model.value===nothing
        push!(intervals,stats)
        interval_callback===nothing || interval_callback(stats)
        stats["model_released"] || error("Reserve model at interval $i remained strongly reachable")
        stats["accepted"] || throw(ReserveAllocationFailure(stats))
    end
    audit=Dict("policy"=>policy,"upstream_horizon_wrapper"=>false,
        "upstream_interval_model_unchanged"=>true,"upstream_projection_unchanged"=>true,
        "source_values_changed"=>false,"rows_or_columns_eliminated"=>0,
        "intervals_completed"=>length(intervals),"intervals_required"=>nt,
        "maximum_live_interval_models"=>1,"all_models_released"=>true,
        "retained_data"=>"plain numeric awards and scalar statistics only", "intervals"=>intervals)
    awards,audit
end
