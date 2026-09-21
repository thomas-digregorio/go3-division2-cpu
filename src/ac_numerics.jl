# Solver-side derivatives/barrier policy. No source expression or domain edits.
const AC_NUMERICS_POLICY = "symbolic_adaptive_v1"

function configure_ac_numerics!(model,policy)
    policy in ("legacy_v1",AC_NUMERICS_POLICY) || error("Unknown AC numerics policy")
    policy=="legacy_v1" && return
    isempty(all_nonlinear_constraints(model)) ||
        error("Explicit symbolic AC policy requires the modern nonlinear interface")
    # optimize!(_differentiation_backend=...) only selects a LEGACY @NL
    # evaluator. The pinned source uses modern NonlinearExpr constraints.
    # Set this once per fresh optimizer: setting it again invalidates Ipopt's
    # existing evaluator even when the backend type is unchanged.
    set_attribute(model,MOI.AutomaticDifferentiationBackend(),MOI.Nonlinear.SymbolicMode())
    for (key,val) in (("mu_strategy","adaptive"),("mu_oracle","quality-function"),
            ("adaptive_mu_globalization","obj-constr-filter"),("print_timing_statistics","yes"))
        set_optimizer_attribute(model,key,val)
        get_optimizer_attribute(model,key)==val || error("AC numerical option was not retained")
    end
end

function optimize_audited_ac!(model;policy="legacy_v1",interval,phase,deadline=Inf)
    policy in ("legacy_v1",AC_NUMERICS_POLICY) || error("Unknown AC numerics policy")
    if policy==AC_NUMERICS_POLICY
        get_attribute(model,MOI.AutomaticDifferentiationBackend()) isa MOI.Nonlinear.SymbolicMode ||
            error("Configured AC derivative backend was lost before solve")
        cap=get_optimizer_attribute(model,"max_wall_time")
        set_optimizer_attribute(model,"max_wall_time",rounded_ac_time_limit(cap,deadline))
    end
    started=time()
    println("GO3_AC_SOLVE_BEGIN ",JSON.json(Dict("interval"=>interval,"phase"=>phase,
        "policy"=>policy,"epoch_seconds"=>started)));flush(stdout)
    if policy=="legacy_v1"
        optimize!(model,_differentiation_backend=GO3.MathOptSymbolicAD.DefaultBackend())
    else
        optimize!(model)
    end
    elapsed=time()-started
    actual=MOI.get(unsafe_backend(model),MOI.AutomaticDifferentiationBackend())
    evaluator=MOI.get(unsafe_backend(model),MOI.NLPBlock()).evaluator
    engine=evaluator isa MOI.Nonlinear.Evaluator ? evaluator.backend : evaluator
    policy==AC_NUMERICS_POLICY && !(actual isa MOI.Nonlinear.SymbolicMode) &&
        error("Native AC solver did not consume the requested derivative backend")
    policy==AC_NUMERICS_POLICY && !(engine isa MOI.Nonlinear.SymbolicAD.Evaluator) &&
        error("Native AC derivative evaluator does not match the requested backend")
    record=Dict("interval"=>interval,"phase"=>phase,"policy"=>policy,
        "effective_native_backend"=>string(typeof(actual)),
        "effective_native_evaluator"=>string(typeof(engine)),
        "native_backend_confirmed"=>true,"optimize_api_wall_seconds"=>elapsed,
        "optimizer_reported_seconds"=>solve_time(model),
        "floating_point_bits"=>64,"model_structure_changed"=>false,
        "source_bounds_changed"=>false,
        "timing_scope"=>"API time includes optimizer setup; native Ipopt timings are logged separately")
    if haskey(model.ext,:ac_zero_reserve_proof)
        record["pre_solve_exact_zero_reduction"]=true
        record["source_feasible_set_changed"]=false
        record["model_structure_change_scope"]="No further change during this numerical call; exact reserve reduction occurred before optimizer attachment"
    end
    if policy==AC_NUMERICS_POLICY
        record["mu_strategy"]=get_optimizer_attribute(model,"mu_strategy")
        record["mu_strategy"]=="adaptive" || error("Native barrier policy changed unexpectedly")
    end
    println("GO3_AC_SOLVE_RETURNED ",JSON.json(record));flush(stdout)
    record
end
