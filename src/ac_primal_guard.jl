# Audited early termination for fixed-shunt repair or an explicitly candidate-only
# continuous-shunt search. This is NOT a KKT/global-optimality certificate.
# No source/model changes, external starts, or reliance on native inf_pr alone.

const AC_PRIMAL_GUARD_POLICY="verified_stable_rounded_primal_v1"
const AC_CANDIDATE_GUARD_POLICY="verified_continuous_shunt_candidate_v1"

function ac_objective_stable(history,tolerance)
    length(history)>=2 && all(isfinite,history) || return false
    (maximum(history)-minimum(history))/max(1.0,maximum(abs,history))<=tolerance
end

function install_ac_primal_guard!(model;policy="off",phase,
        min_iterations=20,window=8,objective_relative_range=1e-7,
        primal_tolerance=AC_POINT_RESIDUAL_TOLERANCE,expected_start=nothing,
        residual_screen="callback_internal",original_probe_interval=5,
        audit_only=false,audit_initial_residual=false)
    policy in ("off",AC_PRIMAL_GUARD_POLICY,AC_CANDIDATE_GUARD_POLICY) || error("Unknown AC primal guard policy")
    audit_only isa Bool && audit_initial_residual isa Bool || error("Invalid native audit flags")
    !(audit_only || audit_initial_residual) ||
        (policy!="off" && expected_start!==nothing) || error("Native initialization audit requires a complete start")
    residual_screen in ("callback_internal","native_original_unscaled") || error("Unknown primal residual screen")
    original_probe_interval isa Integer && !(original_probe_interval isa Bool) && original_probe_interval>0 ||
        error("Invalid original-residual probe interval")
    primal_tolerance isa Real && isfinite(primal_tolerance) &&
        0<primal_tolerance<=AC_POINT_RESIDUAL_TOLERANCE || error("Invalid internal primal target")
    record=Dict{String,Any}("policy"=>policy,"phase"=>phase,"enabled"=>policy!="off",
        "stop_requested"=>false,"callback_count"=>0,"audit_count"=>0,
        "audit_seconds"=>0.0,"source_bounds_changed"=>false,"residual_screen"=>residual_screen,
        "original_probe_interval"=>original_probe_interval,
        "model_structure_changed"=>false,"external_solution_read"=>false,
        "certificate_scope"=>"local model feasibility only; objective stagnation is heuristic; no KKT or global optimality claim")
    accepted=Ref{Any}(nothing)
    state=(record=record,point=accepted)
    if policy=="off"
        expected_start===nothing || error("Native start audit requires an active guard callback")
        return state
    end
    candidate_only=policy==AC_CANDIDATE_GUARD_POLICY
    if candidate_only
        phase=="continuous_shunt_candidate" || error("Candidate guard requires explicitly relaxed-shunt phase")
        record["certificate_scope"]="continuous-shunt candidate only; not an admissible discrete solution, KKT certificate or global bound"
    else
        phase in ("rounded_shunts","numerical_recovery") ||
            error("Primal guard is restricted to fixed rounded-shunt solves")
    end
    record["candidate_only"]=candidate_only
    record["audit_only"]=audit_only
    record["discrete_solution_claimed"]=false # Full final verification is always separate.
    min_iterations isa Integer && !(min_iterations isa Bool) && min_iterations>=0 ||
        error("Invalid primal guard minimum iterations")
    window isa Integer && !(window isa Bool) && window>=2 || error("Invalid primal guard window")
    objective_relative_range isa Real && !(objective_relative_range isa Bool) &&
        isfinite(objective_relative_range) && objective_relative_range>=0 ||
        error("Invalid primal guard objective window tolerance")
    if !candidate_only && haskey(object_dictionary(model),:shunt_step)
        all(is_fixed,model[:shunt_step]) || error("Primal guard requires fixed shunt steps")
    end
    variables=all_variables(model)
    if expected_start!==nothing
        expected_start.variables==variables && length(expected_start.values)==length(variables) &&
            all(isfinite,expected_start.values) || error("Incomplete/nonfinite native start audit mapping")
        record["native_initialization_audit_requested"]=true
    end
    record["minimum_iterations"]=min_iterations
    record["objective_window_iterations"]=window
    record["objective_relative_range_limit"]=objective_relative_range
    record["primal_residual_limit"]=primal_tolerance
    record["variable_count"]=length(variables)
    history=Float64[]
    native_columns=Int[]
    native_values=Float64[]
    function current_native_backend()
        native=unsafe_backend(model)
        native isa Ipopt.Optimizer || error("Unexpected AC guard optimizer")
        inner=native.inner
        if isempty(native_columns)
            append!(native_columns,[Ipopt.column(optimizer_index(v)) for v in variables])
            length(variables)==inner.n && sort(native_columns)==collect(1:inner.n) ||
                error("Incomplete or ambiguous native primal mapping")
            resize!(native_values,inner.n)
            record["native_mapping_complete"]=true
            record["native_variable_count"]=inner.n
        end
        all_variables(model)==variables && length(native_values)==inner.n ||
            error("AC primal guard variable identities changed")
        inner
    end
    function current_native_point()
        inner=current_native_backend()
        Ipopt.GetIpoptCurrentIterate(inner,false,inner.n,native_values,C_NULL,C_NULL,
            inner.m,C_NULL,C_NULL)
        point=(variables=variables,values=native_values[native_columns])
        all(isfinite,point.values) || error("Nonfinite current native iterate")
        point
    end
    original_lower=Float64[];original_upper=Float64[];original_rows=Float64[]
    original_initialized=Ref(false)
    record["native_original_probe_count"]=0
    record["native_original_probe_seconds"]=0.0
    function current_original_residual()
        began=time();inner=current_native_backend()
        if !original_initialized[]
            resize!(original_lower,inner.n);resize!(original_upper,inner.n)
            resize!(original_rows,inner.m);original_initialized[]=true
        end
        length(original_lower)==inner.n && length(original_upper)==inner.n &&
            length(original_rows)==inner.m || error("Native original-residual dimensions changed")
        # The callback's inf_pr is the scaled INTERNAL slack formulation, not
        # the original-NLP residual printed by default. It cannot veto an audit
        # of a primal-feasible original point. Query original unrelaxed bounds
        # and unscaled row violations; the complete JuMP audit below is still
        # mandatory and alone authorizes an early stop. No dual/KKT claim.
        for buffer in (original_lower,original_upper,original_rows)
            fill!(buffer,NaN)
        end
        Ipopt.GetIpoptCurrentViolations(inner,false,inner.n,original_lower,original_upper,
            C_NULL,C_NULL,C_NULL,inner.m,original_rows,C_NULL)
        all(buffer->all(v->isfinite(v) && v>=0.0,buffer),
            (original_lower,original_upper,original_rows)) || error("Invalid native original violations")
        residual=max(maximum(original_lower;init=0.0),maximum(original_upper;init=0.0),
            maximum(original_rows;init=0.0))
        record["native_original_probe_count"]+=1
        record["native_original_probe_seconds"]+=time()-began
        record["last_native_original_residual"]=residual
        record["native_original_row_count"]=inner.m
        residual
    end
    last_audit=-5;last_probe=-original_probe_interval
    function callback(alg_mode,iteration,obj,inf_pr,args...)
        record["callback_count"]+=1
        try
            if alg_mode!=0 || !isfinite(obj)
                empty!(history)
                return true
            end
            if expected_start!==nothing && iteration==0 && !haskey(record,"native_initialization")
                began=time();initial=current_native_point()
                record["native_initialization"]=Dict("iteration"=>0,"complete_mapping"=>true,
                    "variable_count"=>length(variables),
                    "maximum_absolute_change_from_requested_start"=>
                        maximum(abs.(initial.values.-expected_start.values);init=0.0),
                    "maximum_relative_change_from_requested_start"=>
                        maximum(abs.(initial.values.-expected_start.values)./max.(1.0,abs.(expected_start.values));init=0.0),
                    "audit_seconds"=>time()-began,"source_bounds_changed"=>false,
                    "scope"=>"Native first iterate readback, including Ipopt interior pushes; not a feasibility or dual certificate")
                if audit_initial_residual
                    record["native_initialization"]["original_unscaled_residual"]=current_original_residual()
                    println("GO3_AC_NATIVE_INITIALIZATION ",JSON.json(merge(
                        Dict("phase"=>phase),record["native_initialization"])));flush(stdout)
                end
            end
            audit_only && return true
            push!(history,Float64(obj))
            length(history)>window && popfirst!(history)
            (iteration>=min_iterations && length(history)==window &&
                isfinite(inf_pr) && 0<=inf_pr &&
                ac_objective_stable(history,objective_relative_range)) || return true
            if residual_screen=="native_original_unscaled"
                iteration-last_probe>=original_probe_interval || return true
                last_probe=iteration
                original=current_original_residual()
                record["last_probed_iteration"]=Int(iteration)
                record["callback_internal_residual_at_probe"]=inf_pr
                original<=primal_tolerance || return true
                record["callback_internal_gate_would_reject"]=inf_pr>primal_tolerance
            else
                inf_pr<=primal_tolerance || return true
            end
            # Full failed audits may be throttled; cheap native probes need not
            # skip a newly feasible iterate just because the last probe failed.
            iteration-last_audit>=5 || return true
            last_audit=iteration
            began=time()
            # Read the accepted CURRENT native iterate, not the wrapper's last
            # objective/constraint-evaluation cache (which may be a trial point).
            point=current_native_point()
            residual=ac_primal_residual(model,point)
            record["audit_count"]+=1
            record["audit_seconds"]+=time()-began
            record["last_audited_residual"]=residual
            residual<=primal_tolerance || return true
            # The objective is independently evaluated on that same mapped point.
            values_by_variable=Dict(zip(point.variables,point.values))
            actual_objective=value(v->values_by_variable[v],objective_function(model))
            isfinite(actual_objective) || error("Nonfinite audited AC objective")
            accepted[]=point
            record["stop_requested"]=true
            record["stop_iteration"]=Int(iteration)
            record["model_residual_at_stop"]=residual
            record["model_objective_at_stop"]=actual_objective
            record["native_objective_at_stop"]=obj
            record["native_primal_residual_at_stop"]=inf_pr
            record["native_primal_residual_at_stop_scope"]="scaled internal Ipopt formulation; not the audited original residual"
            record["objective_window_relative_range"]=
                (maximum(history)-minimum(history))/max(1.0,maximum(abs,history))
            record["stop_reason"]="complete_model_feasible_and_objective_stable"
            return false
        catch err
            # Never let a callback/interface failure become a feasible-stop claim.
            record["callback_error"]=sprint(showerror,err)
            return false
        end
    end
    MOI.set(model,Ipopt.CallbackFunction(),callback)
    state
end

function finish_ac_primal_guard!(model,state)
    record=state.record
    haskey(record,"callback_error") && error("AC primal guard failed: "*record["callback_error"])
    if get(record,"native_initialization_audit_requested",false) && !haskey(record,"native_initialization")
        error("Native first-iterate audit was requested but not observed")
    end
    if record["stop_requested"]
        returned=capture_complete_ac_primal(model)
        saved=state.point[]
        returned.variables==saved.variables || error("Returned guarded point mapping changed")
        record["returned_termination"]=string(termination_status(model))
        record["returned_point_max_change"]=maximum(abs.(returned.values.-saved.values);init=0.0)
        residual=ac_primal_residual(model,returned)
        record["returned_model_residual"]=residual
        record["returned_point_passed_local_screen"]=residual<=AC_POINT_RESIDUAL_TOLERANCE
        record["returned_point_passed_internal_target"]=residual<=record["primal_residual_limit"]
        # Any changed/nonpassing returned point still follows the existing
        # recovery/fail-fast rule; a callback stop never overrides that screen.
    end
    record
end
