# Within-model primal transfer only. No file, other interval, dual, basis or
# competitor solution is used. Source bounds and constraints are never changed.
const AC_POINT_RESIDUAL_TOLERANCE = 1e-8

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
