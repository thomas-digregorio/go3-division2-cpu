# Within-interval starts only. No file, other interval, basis or competitor
# solution is used. Source bounds are never changed to accommodate a start.
const AC_POINT_RESIDUAL_TOLERANCE = 1e-8

function ac_refinement_deadline(work_deadline,reserve_finish_seconds)
    work_deadline isa Real && !(work_deadline isa Bool) && !isnan(work_deadline) &&
        work_deadline != -Inf || error("Invalid work deadline")
    reserve_finish_seconds isa Real && !(reserve_finish_seconds isa Bool) &&
        isfinite(reserve_finish_seconds) && reserve_finish_seconds>0 ||
        error("Invalid reserve-finalization allowance")
    work_deadline-Float64(reserve_finish_seconds)
end

function capture_complete_ac_primal(model)
    has_values(model) || error("Cannot capture an AC start without a primal point")
    variables=all_variables(model)
    values_=Float64[value(v) for v in variables]
    all(isfinite,values_) || error("AC primal start contains nonfinite values")
    (variables=variables,values=values_)
end

function restore_complete_ac_primal!(model,point)
    variables=all_variables(model)
    variables==point.variables && length(variables)==length(point.values) ||
        error("AC start variable map is not complete and identical")
    all(isfinite,point.values) || error("AC primal start contains nonfinite values")
    adjusted=0
    for (v,x) in zip(variables,point.values)
        # Only the START is projected, never a source limit. In particular,
        # rounded/fixed shunts must start at the newly fixed value.
        lo=has_lower_bound(v) ? lower_bound(v) : -Inf
        hi=has_upper_bound(v) ? upper_bound(v) : Inf
        y=is_fixed(v) ? fix_value(v) : clamp(x,lo,hi)
        isfinite(y) || error("Nonfinite adjusted AC start")
        adjusted += y != x
        set_start_value(v,y)
        start_value(v)==y || error("AC primal start was not retained by the MOI interface")
    end
    Dict("policy"=>"within_interval_complete_v1",
        "source"=>"continuous_shunt_solve_in_same_interval_and_attempt",
        "variable_count"=>length(variables),"accepted_interface_count"=>length(variables),
        "bounds_adjusted_start_count"=>adjusted,"complete"=>true,
        "acceptance_scope"=>"MOI primal attributes set and read back; installed Ipopt wrapper copies them into native x",
        "dual_or_basis_start"=>false,"external_solution_read"=>false,
        "source_bounds_changed"=>false)
end

function ac_primal_residual(model,point)
    variables=all_variables(model)
    variables==point.variables && length(variables)==length(point.values) ||
        error("Cannot audit an incomplete AC point")
    all(isfinite,point.values) || error("Cannot audit a nonfinite AC point")
    report=primal_feasibility_report(model,Dict(zip(variables,point.values));atol=0.0)
    all(isfinite,values(report)) || error("AC residual evaluation is nonfinite")
    maximum(values(report);init=0.0)
end

function ac_requires_stop(metadata,enabled)
    enabled || return false
    phases=get(metadata,"phases",Any[])
    isempty(phases) && error("Fail-fast AC policy requires explicit phase residuals")
    final=last(phases)
    residual=get(final,"max_primal_residual",nothing)
    # A time/iteration-limited point may be usable; a nominal solver status is
    # not a substitute for actual residual checks. This is a local screen only:
    # independent full-horizon physical/exhaustive verification is still required.
    !(get(final,"complete_finite_point",false) && residual isa Real &&
        isfinite(residual) && 0 <= residual <= AC_POINT_RESIDUAL_TOLERANCE)
end

function capture_complete_ac_dual(model)
    has_duals(model) || error("AC dual transfer requires an existing dual point")
    legacy=all_nonlinear_constraints(model)
    rows=all_constraints(model;include_variable_in_set_constraints=true)
    multipliers=Dict(c=>Float64(dual(c)) for c in rows)
    all(isfinite,values(multipliers)) || error("AC dual start contains nonfinite values")
    (rows=multipliers,legacy=legacy)
end

function restore_complete_ac_dual!(model,point;new_fixed=Set(),removed_bounds=Set())
    rows=all_constraints(model;include_variable_in_set_constraints=true)
    current=Set(rows)
    missing=setdiff(current,Set(keys(point.rows)))
    removed=setdiff(Set(keys(point.rows)),current)
    issubset(missing,new_fixed) || error("Unexpected new constraint in AC dual transfer")
    issubset(removed,removed_bounds) || error("Unexpected deleted constraint in AC dual transfer")
    all_nonlinear_constraints(model)==point.legacy || error("AC nonlinear dual order changed")
    all(isfinite,values(point.rows)) || error("AC dual start contains nonfinite values")
    legacy=Set(point.legacy)
    for c in rows
        c in legacy && continue
        y=get(point.rows,c,0.0) # Newly fixed rounded shunts have no old multiplier.
        set_dual_start_value(c,y)
        dual_start_value(c)==y || error("AC constraint dual start was not retained")
    end
    if !isempty(point.legacy)
        start=[point.rows[c] for c in point.legacy]
        set_nonlinear_dual_start_value(model,start)
        nonlinear_dual_start_value(model)==start || error("Legacy nonlinear dual start was not retained")
    end
    # A genuine primal-dual warm start; do not assert identical structure after
    # fixing shunts. Small interior pushes apply to starts, not source bounds.
    options=Dict{String,Any}("warm_start_init_point"=>"yes",
        "warm_start_same_structure"=>"no","warm_start_bound_push"=>1e-8,
        "warm_start_bound_frac"=>1e-8,"warm_start_slack_bound_push"=>1e-8,
        "warm_start_slack_bound_frac"=>1e-8,"warm_start_mult_bound_push"=>1e-8,
        # Prevent scaled termination with large transferred multipliers from
        # masking residual reserve-cost complementarity in physical units.
        "mu_init"=>1e-6,"compl_inf_tol"=>1e-8)
    for (key,val) in options
        set_optimizer_attribute(model,key,val)
        get_optimizer_attribute(model,key)==val || error("Ipopt warm-start option not retained")
    end
    Dict("constraint_count"=>length(rows),"accepted_interface_count"=>length(rows),
        "reused_dual_count"=>length(rows)-length(missing),
        "new_fixed_shunt_zero_duals"=>length(missing),
        "removed_shunt_bound_duals"=>length(removed),
        "legacy_nonlinear_count"=>length(point.legacy),"complete_current_mapping"=>true,
        "largest_transferred_absolute_dual"=>maximum(abs,values(point.rows);init=0.0),
        "options"=>options,"source"=>"same_interval_continuous_shunt_solve")
end

function rounded_ac_time_limit(cap,deadline;now=time())
    cap isa Real && isfinite(cap) && cap>0 || error("Invalid rounded AC time allowance")
    remaining=deadline-now-1.0
    remaining>0 || error("No work budget remains for rounded AC solve")
    min(Float64(cap),remaining)
end
