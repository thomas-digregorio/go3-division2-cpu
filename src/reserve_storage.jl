# Storage-only orchestration of the pinned, unchanged per-interval reserve LP.
# The upstream horizon wrapper retains every (model, awards) pair even when
# return_models=false. This path keeps numeric awards, then releases each model.
const RESERVE_STORAGE_POLICIES=("legacy_horizon_v1","bounded_lifetime_v1")
const RESERVE_STORAGE_FIELDS=(:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,
    :p_rru_off,:p_rrd_on,:p_rrd_off,:q_qru,:q_qrd)

function _store_reserve_interval!(awards,input,i,records,curves,optimizer)
    ids=input.sdd_ids
    on=Dict(u=>records[u]["on_status"][i] for u in ids)
    su=Dict(u=>curves.supc_status[u][i] for u in ids)
    sd=Dict(u=>curves.sdpc_status[u][i] for u in ids)
    psu=Dict(u=>curves.p_su[u][i] for u in ids)
    psd=Dict(u=>curves.p_sd[u][i] for u in ids)
    opf=Dict("simple_dispatchable_device"=>Dict(u=>Dict(
        "p_on"=>records[u]["p_on"][i],"q"=>records[u]["q"][i]) for u in ids))
    # Delegate construction, solution, extraction, and projection to precisely
    # the same upstream function called by the old horizon wrapper.
    model,data=GO3.calculate_reserves_from_generation(input,i,opf,on,su,sd,psu,psd;
        optimizer=optimizer,set_silent=true,return_model=true)
    for field in RESERVE_STORAGE_FIELDS, uid in ids
        v=Float64(getproperty(data,field)[uid])
        isfinite(v) || error("Nonfinite extracted reserve award at interval $i: $uid/$field")
        getproperty(awards,field)[uid][i]=v
    end
    stats=Dict{String,Any}("interval"=>i,"termination"=>string(termination_status(model)),
        "objective"=>objective_value(model),"solver_seconds"=>solve_time(model),
        "variables"=>num_variables(model),
        "constraints"=>num_constraints(model;count_variable_in_set_constraints=true))
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
    end
    audit=Dict("policy"=>policy,"upstream_horizon_wrapper"=>false,
        "upstream_interval_model_unchanged"=>true,"upstream_projection_unchanged"=>true,
        "source_values_changed"=>false,"rows_or_columns_eliminated"=>0,
        "intervals_completed"=>length(intervals),"intervals_required"=>nt,
        "maximum_live_interval_models"=>1,"all_models_released"=>true,
        "retained_data"=>"plain numeric awards and scalar statistics only", "intervals"=>intervals)
    awards,audit
end
