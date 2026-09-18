# One bounded numerical recovery on the identical rounded-shunt hourly model.
# No file, prior attempt, source limit, objective or constraint is changed.

function ac_recovery_required(phases,policy)
    policy in ("off","adaptive_barrier_on_failed_residual_v1") ||
        error("Unknown AC numerical recovery policy")
    policy=="off" && return false
    ac_requires_stop(Dict("phases"=>phases),true)
end

function ac_variable_bounds(model)
    [(is_fixed(v) ? fix_value(v) : nothing,
        has_lower_bound(v) ? lower_bound(v) : nothing,
        has_upper_bound(v) ? upper_bound(v) : nothing) for v in all_variables(model)]
end

function prepare_ac_recovery!(model,optimizer,point;seconds,deadline,max_iter=1000)
    max_iter isa Integer && !(max_iter isa Bool) && max_iter>0 ||
        error("Invalid AC recovery iteration limit")
    allowance=rounded_ac_time_limit(seconds,deadline)
    # Audit before dropping numerical solver state. Starts may be infeasible,
    # but missing identities or nonfinite values must never be propagated.
    previous_residual=ac_primal_residual(model,point)
    rows=all_constraints(model;include_variable_in_set_constraints=true)
    legacy=Set(all_nonlinear_constraints(model))
    bounds=ac_variable_bounds(model)
    objective=objective_function(model)
    sense=objective_sense(model)
    set_optimizer(model,optimizer)
    for c in rows
        c in legacy && continue
        set_dual_start_value(c,nothing)
        dual_start_value(c)===nothing || error("Stale AC recovery dual start")
    end
    if !isempty(legacy)
        set_nonlinear_dual_start_value(model,nothing)
        nonlinear_dual_start_value(model)===nothing || error("Stale nonlinear dual start")
    end
    start=restore_complete_ac_primal!(model,point)
    start["source"]="failed_rounded_shunt_solve_in_same_interval_and_attempt"
    # Ordinary primal initialization, not a primal-dual warm start. Let the
    # adaptive barrier choose its scale instead of inheriting a tiny fixed mu.
    # Default-size interior pushes affect STARTS only; original bounds stay exact.
    options=Dict{String,Any}("warm_start_init_point"=>"no",
        "warm_start_same_structure"=>"no","mu_strategy"=>"adaptive",
        "mu_oracle"=>"quality-function","adaptive_mu_globalization"=>"obj-constr-filter",
        "bound_push"=>0.01,"bound_frac"=>0.01,
        "slack_bound_push"=>0.01,"slack_bound_frac"=>0.01,
        "mu_init"=>0.1,"compl_inf_tol"=>1e-8,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes",
        "tol"=>1e-9,"constr_viol_tol"=>1e-9,
        "acceptable_tol"=>1e-8,"acceptable_constr_viol_tol"=>1e-9,
        "max_iter"=>max_iter,"max_wall_time"=>allowance)
    for (key,val) in options
        set_optimizer_attribute(model,key,val)
        get_optimizer_attribute(model,key)==val || error("AC recovery option not retained")
    end
    all_variables(model)==point.variables &&
        all_constraints(model;include_variable_in_set_constraints=true)==rows &&
        ac_variable_bounds(model)==bounds && objective_sense(model)==sense &&
        JuMP.isequal_canonical(objective_function(model),objective) ||
        error("AC numerical recovery changed the mathematical model")
    Dict("policy"=>"adaptive_barrier_on_failed_residual_v1","attempted"=>true,
        "trigger"=>"rounded_phase_failed_explicit_primal_residual_screen",
        "previous_model_residual"=>previous_residual,"fresh_optimizer_instantiated"=>true,
        "constraint_count"=>length(rows),"dual_starts_cleared"=>length(rows),
        "legacy_nonlinear_count"=>length(legacy),"complete_primal_start"=>start,
        "options"=>options,"source_bounds_changed"=>false,"model_structure_changed"=>false,
        "objective_changed"=>false,"external_solution_read"=>false,
        "acceptance"=>"unchanged local residual screen followed by independent exhaustive verification")
end
