# Feasibility-first termination on a fixed rounded-shunt model. This is an
# explicitly labelled heuristic stopping rule, NOT a KKT/optimality certificate.
# No source/model changes, external starts, or reliance on native inf_pr alone.

const AC_PRIMAL_GUARD_POLICY="verified_stable_rounded_primal_v1"

function ac_objective_stable(history,tolerance)
    length(history)>=2 && all(isfinite,history) || return false
    (maximum(history)-minimum(history))/max(1.0,maximum(abs,history))<=tolerance
end

function install_ac_primal_guard!(model;policy="off",phase,
        min_iterations=20,window=8,objective_relative_range=1e-7)
    policy in ("off",AC_PRIMAL_GUARD_POLICY) || error("Unknown AC primal guard policy")
    record=Dict{String,Any}("policy"=>policy,"phase"=>phase,"enabled"=>policy!="off",
        "stop_requested"=>false,"callback_count"=>0,"audit_count"=>0,
        "audit_seconds"=>0.0,"source_bounds_changed"=>false,
        "model_structure_changed"=>false,"external_solution_read"=>false,
        "certificate_scope"=>"local model feasibility only; objective stagnation is heuristic; no KKT or global optimality claim")
    accepted=Ref{Any}(nothing)
    state=(record=record,point=accepted)
    policy=="off" && return state
    phase in ("rounded_shunts","numerical_recovery") ||
        error("Primal guard is restricted to fixed rounded-shunt solves")
    min_iterations isa Integer && !(min_iterations isa Bool) && min_iterations>=0 ||
        error("Invalid primal guard minimum iterations")
    window isa Integer && !(window isa Bool) && window>=2 || error("Invalid primal guard window")
    objective_relative_range isa Real && !(objective_relative_range isa Bool) &&
        isfinite(objective_relative_range) && objective_relative_range>=0 ||
        error("Invalid primal guard objective window tolerance")
    if haskey(object_dictionary(model),:shunt_step)
        all(is_fixed,model[:shunt_step]) || error("Primal guard requires fixed shunt steps")
    end
    variables=all_variables(model)
    record["minimum_iterations"]=min_iterations
    record["objective_window_iterations"]=window
    record["objective_relative_range_limit"]=objective_relative_range
    record["primal_residual_limit"]=AC_POINT_RESIDUAL_TOLERANCE
    record["variable_count"]=length(variables)
    history=Float64[]
    native_columns=Int[]
    native_values=Float64[]
    last_audit=-5
    function callback(alg_mode,iteration,obj,inf_pr,args...)
        record["callback_count"]+=1
        try
            if alg_mode!=0 || !isfinite(obj)
                empty!(history)
                return true
            end
            push!(history,Float64(obj))
            length(history)>window && popfirst!(history)
            (iteration>=min_iterations && length(history)==window &&
                isfinite(inf_pr) && 0<=inf_pr<=AC_POINT_RESIDUAL_TOLERANCE &&
                iteration-last_audit>=5 &&
                ac_objective_stable(history,objective_relative_range)) || return true
            last_audit=iteration
            began=time()
            # Read the accepted CURRENT native iterate, not the wrapper's last
            # objective/constraint-evaluation cache (which may be a trial point).
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
            Ipopt.GetIpoptCurrentIterate(inner,false,inner.n,native_values,C_NULL,C_NULL,
                inner.m,C_NULL,C_NULL)
            point=(variables=variables,values=native_values[native_columns])
            residual=ac_primal_residual(model,point)
            record["audit_count"]+=1
            record["audit_seconds"]+=time()-began
            record["last_audited_residual"]=residual
            residual<=AC_POINT_RESIDUAL_TOLERANCE || return true
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
    if record["stop_requested"]
        returned=capture_complete_ac_primal(model)
        saved=state.point[]
        returned.variables==saved.variables || error("Returned guarded point mapping changed")
        record["returned_termination"]=string(termination_status(model))
        record["returned_point_max_change"]=maximum(abs.(returned.values.-saved.values);init=0.0)
        residual=ac_primal_residual(model,returned)
        record["returned_model_residual"]=residual
        record["returned_point_passed_local_screen"]=residual<=AC_POINT_RESIDUAL_TOLERANCE
        # Any changed/nonpassing returned point still follows the existing
        # recovery/fail-fast rule; a callback stop never overrides that screen.
    end
    record
end
