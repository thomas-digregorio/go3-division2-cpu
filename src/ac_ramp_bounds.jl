# The official physical-balance limit is not a tolerance for dropping ramp
# bounds. Keep the historical policy replayable, but apply every intersection
# in the corrected route. Empty intersections fail rather than averaging bounds.
const AC_RAMP_BOUND_POLICIES=("legacy_tolerance_v1","exact_source_intersections_v1")
const AC_EXPORT_PROJECTION_GUARD=1e-9

function ac_ramp_bound_tolerance(policy)
    policy in AC_RAMP_BOUND_POLICIES || error("Unknown AC ramp-bound policy")
    policy=="exact_source_intersections_v1" ? 0.0 : 1e-8
end

function tighten_ac_horizon_bounds(input,schedule;policy="legacy_tolerance_v1")
    try
        GO3.tighten_bounds_using_ramp_limits(input,schedule.on_status,schedule.real_power;
            tolerance=ac_ramp_bound_tolerance(policy))
    catch err
        # The pinned upstream throws the abstract type, not an exception instance,
        # for an empty intersection. Give our controller an actionable error.
        err===Exception || rethrow()
        error("Empty source/ramp-bound intersection during horizon preparation; no bound was relaxed")
    end
end

function tighten_ac_interval_bounds!(working,i,previous_on,previous_p,current_on;
        policy="legacy_tolerance_v1")
    try
        GO3.tighten_bounds_at_interval_using_ramp_limits!(working,i,previous_on,previous_p,current_on;
            tolerance=ac_ramp_bound_tolerance(policy))
    catch err
        err===Exception || rethrow()
        error("Empty source/ramp-bound intersection at interval $i; no bound was relaxed")
    end
end

function ac_export_projection_audit(input,projections,refined_intervals;
        policy="legacy_tolerance_v1")
    tolerance=ac_ramp_bound_tolerance(policy)
    refined_intervals isa Integer && !(refined_intervals isa Bool) &&
        0<=refined_intervals<=length(input.periods) || error("Invalid refined horizon")
    bus_changes=Dict{Tuple{String,Int},Float64}()
    refined_device_max=0.0
    refined_events=0
    for (uid,i,delta) in projections
        i isa Integer && !(i isa Bool) && i in input.periods || error("Invalid projected interval")
        isfinite(delta) || error("Nonfinite exported dispatch projection")
        device=input.sdd_lookup[uid]
        kind=device["device_type"]
        kind in ("producer","consumer") || error("Unknown projected device type")
        signed=(kind=="producer" ? 1.0 : -1.0)*delta
        key=(String(device["bus"]),Int(i))
        bus_changes[key]=get(bus_changes,key,0.0)+signed
        if i<=refined_intervals
            refined_events+=1
            refined_device_max=max(refined_device_max,abs(delta))
        end
    end
    refined_max=0.0
    future_max=0.0
    worst=nothing
    for key in sort!(collect(keys(bus_changes)))
        delta=bus_changes[key]
        if key[2]<=refined_intervals
            if abs(delta)>refined_max
                refined_max=abs(delta)
                worst=Dict("bus"=>key[1],"interval"=>key[2],"signed_change_pu"=>delta)
            end
        else
            future_max=max(future_max,abs(delta))
        end
    end
    Dict("policy"=>policy,"bookkeeping_tolerance"=>tolerance,
        "refined_intervals"=>refined_intervals,"projection_events"=>length(projections),
        "refined_projection_events"=>refined_events,
        "maximum_refined_device_change_pu"=>refined_device_max,
        "maximum_refined_bus_injection_change_pu"=>refined_max,
        "maximum_unfinished_bus_injection_change_pu"=>future_max,
        "worst_refined_bus"=>worst,"projection_guard_pu"=>AC_EXPORT_PROJECTION_GUARD,
        "within_guard"=>refined_max<=AC_EXPORT_PROJECTION_GUARD,
        "enforced"=>policy=="exact_source_intersections_v1",
        "source_bounds_changed"=>false,"official_tolerance_changed"=>false,
        "certificate_scope"=>"Export projection drift only; full independent and official verification still required")
end

function construct_audited_ac_solution(input,schedule,results,refined_intervals;
        policy="legacy_tolerance_v1")
    solution=GO3.construct_solution_dict(input,schedule;opf_data=results,
        include_reserves=false,postprocess=false,print_projected_devices=false)
    solution,projections=GO3.postprocess_solution_data(solution,input,schedule)
    audit=ac_export_projection_audit(input,projections,refined_intervals;policy=policy)
    println("GO3_AC_EXPORT_PROJECTION ",JSON.json(audit));flush(stdout)
    solution,audit
end

function require_ac_export_projection(audit)
    audit["enforced"] && !audit["within_guard"] &&
        error("Exported refined dispatch changed bus injection beyond its projection guard; candidate saved but not accepted")
    nothing
end
