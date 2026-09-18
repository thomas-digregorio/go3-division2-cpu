# Sequential linearization of the ORIGINAL hourly AC model. Candidate generation
# only: every accepted point is screened on nonlinear rows, then independently
# checked on the raw full-horizon GO3 input. No external point or solver is used.
using SparseArrays
const AC_CORRECTION_POLICY="network_slp_fixed_shunts_v1"

correction_bounds(s::MOI.EqualTo)=(Float64(s.value),Float64(s.value))
correction_bounds(s::MOI.LessThan)=(-Inf,Float64(s.upper))
correction_bounds(s::MOI.GreaterThan)=(Float64(s.lower),Inf)
correction_bounds(s::MOI.Interval)=(Float64(s.lower),Float64(s.upper))
correction_bounds(s)=error("Unsupported AC correction set: $(typeof(s))")

function correction_oracle(model)
    started=time()
    vars=all_variables(model); n=length(vars)
    positions=Dict(v=>k for (k,v) in enumerate(vars))
    lb=fill(-Inf,n);ub=fill(Inf,n)
    for (k,v) in enumerate(vars)
        if is_binary(v) || is_integer(v)
            is_fixed(v) && isinteger(fix_value(v)) || error("Unfixed discrete AC correction variable")
        end
        lb[k]=is_fixed(v) ? fix_value(v) : (has_lower_bound(v) ? lower_bound(v) : -Inf)
        ub[k]=is_fixed(v) ? fix_value(v) : (has_upper_bound(v) ? upper_bound(v) : Inf)
    end
    raw_objective=objective_function(model)
    objective=raw_objective isa VariableRef ? 1.0*raw_objective : raw_objective
    objective isa AffExpr || error("Correction requires the original affine PWL/penalty objective")
    c=zeros(n)
    for (v,a) in objective.terms
        c[positions[v]]=a
    end
    objective_sense(model)==MOI.MAX_SENSE || error("Correction expects source welfare maximization")
    ai=Int[];aj=Int[];av=Float64[];al=Float64[];au=Float64[]
    nl=MOI.Nonlinear.Model();nl_lower=Float64[];nl_upper=Float64[]
    nl_refs=ConstraintRef[]
    isempty(all_nonlinear_constraints(model)) || error("Legacy nonlinear rows require an explicit adapter")
    for (F,S) in list_of_constraint_types(model)
        F==VariableRef && continue # Exact bounds/types handled above.
        for cref in all_constraints(model,F,S)
            row=constraint_object(cref);lo,hi=correction_bounds(row.set)
            if F==AffExpr
                push!(al,lo-row.func.constant);push!(au,hi-row.func.constant)
                r=length(al)
                for (v,a) in row.func.terms
                    push!(ai,r);push!(aj,positions[v]);push!(av,a)
                end
            elseif F==NonlinearExpr || F==QuadExpr
                f=JuMP.moi_function(row.func)
                MOI.Nonlinear.add_constraint(nl,f,row.set)
                push!(nl_lower,lo);push!(nl_upper,hi);push!(nl_refs,cref)
            else
                error("Unsupported AC correction expression: $F")
            end
        end
    end
    evaluator=MOI.Nonlinear.Evaluator(nl,GO3.MathOptSymbolicAD.DefaultBackend(),index.(vars))
    MOI.initialize(evaluator,[:Jac])
    pattern=MOI.jacobian_structure(evaluator)
    rows=Int[first(p) for p in pattern];cols=Int[last(p) for p in pattern]
    A=sparse(ai,aj,av,length(al),n)
    (;model,variables=vars,positions,lb,ub,c,offset=objective.constant,A,al,au,
      evaluator,nl_lower,nl_upper,nl_refs,jac_rows=rows,jac_cols=cols,
      build_seconds=time()-started)
end

function correction_values(o,x)
    length(x)==length(o.variables) && all(isfinite,x) || error("Incomplete/nonfinite correction vector")
    g=zeros(length(o.nl_lower));MOI.eval_constraint(o.evaluator,g,x)
    all(isfinite,g) || error("Nonfinite original AC equations")
    g
end

function correction_residual(o,x)
    g=correction_values(o,x);ax=o.A*x
    bound=max(maximum(o.lb.-x;init=0.0),maximum(x.-o.ub;init=0.0))
    affine=max(maximum(o.al.-ax;init=0.0),maximum(ax.-o.au;init=0.0))
    nonlinear=max(maximum(o.nl_lower.-g;init=0.0),maximum(g.-o.nl_upper;init=0.0))
    max(0.0,bound,affine,nonlinear)
end

function correction_linearization(o,x)
    g=correction_values(o,x)
    vals=zeros(length(o.jac_rows));MOI.eval_constraint_jacobian(o.evaluator,vals,x)
    all(isfinite,vals) || error("Nonfinite AC Jacobian")
    J=sparse(o.jac_rows,o.jac_cols,vals,length(g),length(x))
    shift=J*x-g
    (A=[o.A;J],lower=[o.al;o.nl_lower.+shift],upper=[o.au;o.nl_upper.+shift],J=J,g=g)
end

function correction_native_lp(A,c,lb,ub,rl,ru,x;seconds,threads=4)
    seconds>0 && isfinite(seconds) || error("Invalid correction LP budget")
    size(A)==(length(rl),length(c)) && length(ru)==length(rl) &&
        length(lb)==length(ub)==length(x)==length(c) || error("Correction LP dimensions differ")
    all(isfinite,c) && all(isfinite,A.nzval) && all(lb.<=ub) && all(rl.<=ru) ||
        error("Invalid correction LP data")
    length(A.nzval)<=typemax(HiGHS.HighsInt) || error("Correction matrix exceeds native index range")
    h=HiGHS.Highs_create();h!=C_NULL || error("HiGHS allocation failed")
    check(s)=s==HiGHS.kHighsStatusOk || error("HiGHS correction API failed: $s")
    function intinfo(key)
        v=Ref{HiGHS.HighsInt}(0)
        HiGHS.Highs_getIntInfoValue(h,key,v)==HiGHS.kHighsStatusOk ? Int(v[]) : nothing
    end
    wall=time();point=nothing
    try
        check(HiGHS.Highs_setBoolOptionValue(h,"output_flag",0))
        check(HiGHS.Highs_setIntOptionValue(h,"threads",threads))
        check(HiGHS.Highs_setIntOptionValue(h,"random_seed",0))
        check(HiGHS.Highs_setDoubleOptionValue(h,"time_limit",seconds))
        check(HiGHS.Highs_setDoubleOptionValue(h,"primal_feasibility_tolerance",1e-9))
        check(HiGHS.Highs_setDoubleOptionValue(h,"dual_feasibility_tolerance",1e-9))
        check(HiGHS.Highs_setStringOptionValue(h,"solver","simplex"))
        # One bulk CSC transfer, no per-variable native edits or commercial backend.
        starts=HiGHS.HighsInt.(A.colptr.-1);indices=HiGHS.HighsInt.(A.rowval.-1)
        check(HiGHS.Highs_passLp(h,length(c),length(rl),nnz(A),HiGHS.kHighsMatrixFormatColwise,
            HiGHS.kHighsObjSenseMaximize,0.0,c,lb,ub,rl,ru,starts,indices,A.nzval))
        transfer=time()-wall
        start_status=HiGHS.Highs_setSolution(h,x,A*x,C_NULL,C_NULL)
        stored=zeros(length(x));stored_rows=zeros(length(rl))
        stored_ok=HiGHS.Highs_getSolution(h,stored,C_NULL,stored_rows,C_NULL)==HiGHS.kHighsStatusOk && stored==x
        native_started=time();run_status=HiGHS.Highs_run(h);api_seconds=time()-native_started
        status=Int(HiGHS.Highs_getModelStatus(h));ps=intinfo("primal_solution_status")
        if ps==HiGHS.kHighsSolutionStatusFeasible
            point=zeros(length(x))
            check(HiGHS.Highs_getSolution(h,point,C_NULL,stored_rows,C_NULL))
            all(isfinite,point) || error("Native correction returned nonfinite point")
        end
        record=Dict("native_model_status"=>status,"native_primal_status"=>ps,
            "native_run_status"=>Int(run_status),"native_seconds"=>HiGHS.Highs_getRunTime(h),
            "api_seconds"=>api_seconds,"bulk_transfer_seconds"=>transfer,
            "simplex_iterations"=>intinfo("simplex_iteration_count"),
            "requested_seconds"=>seconds,"columns"=>length(x),"rows"=>length(rl),
            "complete_start_api_status"=>Int(start_status),"native_stored_start"=>stored_ok,
            "native_start_use"=>"stored vector observed; algorithmic use after presolve not asserted",
            "basis_reused"=>false,"external_solution_read"=>false,
            "certificate_scope"=>"linearized candidate subproblem only; no full GO3 bound")
        point,record
    finally
        HiGHS.Highs_destroy(h)
    end
end

function ac_linear_correction(model,point;deadline,max_rounds=8,lp_seconds=4.0,threads=4)
    started=time();o=correction_oracle(model)
    point.variables==o.variables || error("Correction source variable mapping differs")
    x=copy(point.values);x=clamp.(x,o.lb,o.ub)
    residual=correction_residual(o,x);initial_residual=residual
    records=Any[];radius=0.25;accepted=0;reason="round_limit"
    # Trust regions restrict nonlinear *search steps*, never source bounds.
    nonlinear_columns=if haskey(object_dictionary(model),:vm) && haskey(object_dictionary(model),:va)
        [o.positions[v] for vs in (model[:vm],model[:va]) for v in vs]
    else
        unique(o.jac_cols)
    end
    for round_id in 1:max_rounds
        if residual<=AC_POINT_RESIDUAL_TOLERANCE
            reason="original_model_residual_pass";break
        elseif deadline-time()<=0.2
            reason="correction_deadline";break
        end
        began=time();lin=correction_linearization(o,x)
        lo=copy(o.lb);hi=copy(o.ub)
        for j in nonlinear_columns
            step=radius*max(1.0,abs(x[j]))
            lo[j]=max(lo[j],x[j]-step);hi[j]=min(hi[j],x[j]+step)
        end
        allowance=min(lp_seconds,deadline-time()-0.05)
        allowance>0 || (reason="correction_deadline";break)
        proposed,record=correction_native_lp(lin.A,o.c,lo,hi,lin.lower,lin.upper,x;
            seconds=allowance,threads=threads)
        merge!(record,Dict("round"=>round_id,"before_residual"=>residual,"trust_radius"=>radius))
        if proposed===nothing
            record["accepted"]=false;record["reason"]="no_feasible_linearized_point"
            push!(records,record);reason="linearized_solve_failed";break
        end
        took=false
        for alpha in (1.0,0.5,0.25,0.125,0.0625,0.03125)
            trial=x.+alpha.*(proposed.-x)
            r=correction_residual(o,trial)
            if r<=AC_POINT_RESIDUAL_TOLERANCE || r<(1.0-1e-4*alpha)*residual
                x=trial;residual=r;took=true;accepted+=1
                record["step_fraction"]=alpha
                alpha<1 && (radius=max(0.01,radius/2))
                break
            end
        end
        record["accepted"]=took;record["after_residual"]=residual
        record["wall_seconds"]=time()-began
        push!(records,record)
        if !took
            reason="nonlinear_step_rejected_rollback";break
        end
    end
    returned=(variables=o.variables,values=x)
    # Cross-check cached numeric evaluation against JuMP's original expression audit.
    independent_local=ac_primal_residual(model,returned)
    abs(independent_local-residual)<=max(1e-10,1e-8*max(independent_local,residual)) ||
        error("Correction oracle and original JuMP residual disagree")
    residual<=AC_POINT_RESIDUAL_TOLERANCE && (reason="original_model_residual_pass")
    record=Dict("policy"=>AC_CORRECTION_POLICY,"phase"=>"linearized_correction",
        "termination"=>reason,"complete_finite_point"=>true,"max_primal_residual"=>independent_local,
        "initial_residual"=>initial_residual,"rounds"=>records,"accepted_steps"=>accepted,
        "wall_seconds"=>time()-started,"oracle_build_seconds"=>o.build_seconds,
        "objective"=>dot(o.c,x)+o.offset,"nonlinear_rows"=>length(o.nl_lower),
        "linear_rows"=>length(o.al),"variables"=>length(x),
        "jacobian_structure_reused"=>true,"factorization_reused"=>false,
        "source_bounds_changed"=>false,"penalties_changed"=>false,"external_solution_read"=>false,
        "certificate_scope"=>"local original-model primal feasibility only; not optimality")
    returned,record
end
