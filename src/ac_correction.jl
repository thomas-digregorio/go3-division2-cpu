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

# Read the original, unpresolved native LP back before accepting any import
# warning. Candidate linearizations may lose tiny coefficients inside HiGHS;
# allow that only with a conservative bound on EVERY row's possible error.
# The original JuMP/source model and nonlinear acceptance tolerances never change.
function correction_import_audit(h,A,c,lb,ub,rl,ru;matrix_threshold=1e-12)
    started=time();m,n=size(A)
    native_n=Int(HiGHS.Highs_getNumCol(h));native_m=Int(HiGHS.Highs_getNumRow(h))
    native_z=Int(HiGHS.Highs_getNumNz(h))
    native_n==n && native_m==m && native_z>=0 || error("Imported correction dimensions changed")
    nc=Ref{HiGHS.HighsInt}(0);nr=Ref{HiGHS.HighsInt}(0);nz=Ref{HiGHS.HighsInt}(0)
    sense=Ref{HiGHS.HighsInt}(0);offset=Ref(0.0)
    cost=zeros(n);cl=zeros(n);cu=zeros(n);lower=zeros(m);upper=zeros(m)
    starts=zeros(HiGHS.HighsInt,n+1);starts[end]=native_z
    indices=zeros(HiGHS.HighsInt,native_z);values_=zeros(native_z)
    status=HiGHS.Highs_getLp(h,HiGHS.kHighsMatrixFormatColwise,nc,nr,nz,sense,offset,
        cost,cl,cu,lower,upper,starts,indices,values_,C_NULL)
    status==HiGHS.kHighsStatusOk || error("Cannot audit imported correction LP: $status")
    nc[]==n && nr[]==m && nz[]==native_z && starts[1]==0 && starts[end]==native_z &&
        issorted(starts) && all(0 .<=indices.<m) || error("Invalid native correction matrix mapping")
    imported=SparseMatrixCSC(m,n,Int.(starts).+1,Int.(indices).+1,values_)
    delta=A-imported;dropzeros!(delta)
    rows,cols,changes=findnz(delta)
    removed_only=all(imported[r,j]==0.0 && A[r,j]==v for (r,j,v) in zip(rows,cols,changes))
    maximum_change=maximum(abs,changes;init=0.0)
    row_error=zeros(m);unbounded=Set{Int}()
    for (r,j,v) in zip(rows,cols,changes)
        bound=max(abs(lb[j]),abs(ub[j]))
        if isfinite(bound)
            row_error[r]+=abs(v)*bound
        else
            push!(unbounded,j)
        end
    end
    exact_domains=cl==lb && cu==ub && lower==rl && upper==ru
    exact_objective=cost==c && sense[]==HiGHS.kHighsObjSenseMaximize && offset[]==0.0
    max_row_error=isempty(unbounded) ? maximum(row_error;init=0.0) : nothing
    accepted=exact_domains && exact_objective && removed_only &&
        maximum_change<=matrix_threshold && isempty(unbounded) && max_row_error<=1e-10
    Dict("pass"=>accepted,"domains_exact"=>exact_domains,"objective_exact"=>exact_objective,
        "removed_small_coefficients_only"=>removed_only,"changed_nonzeros"=>length(changes),
        "maximum_coefficient_change"=>maximum_change,"maximum_bounded_row_error"=>max_row_error,
        "unbounded_changed_columns"=>length(unbounded),"row_error_limit"=>1e-10,
        "matrix_import_threshold"=>matrix_threshold,"native_nonzeros"=>native_z,
        "input_nonzeros"=>nnz(A),"wall_seconds"=>time()-started,
        "scope"=>"Candidate LP import only; original nonlinear/source checks remain mandatory")
end

function correction_native_lp(A,c,lb,ub,rl,ru,x;seconds,threads=4,log_dir=nothing)
    seconds>0 && isfinite(seconds) || error("Invalid correction LP budget")
    size(A)==(length(rl),length(c)) && length(ru)==length(rl) &&
        length(lb)==length(ub)==length(x)==length(c) || error("Correction LP dimensions differ")
    all(isfinite,c) && all(isfinite,A.nzval) && all(lb.<=ub) && all(rl.<=ru) ||
        error("Invalid correction LP data")
    length(A.nzval)<=typemax(HiGHS.HighsInt) || error("Correction matrix exceeds native index range")
    logs=abspath(something(log_dir,joinpath(@__DIR__,"..","tmp","ac_correction_native")))
    occursin("onedrive",lowercase(logs)) && error("OneDrive diagnostic path forbidden")
    mkpath(logs)
    log_path,log_io=mktemp(logs;cleanup=false);close(log_io)
    h=HiGHS.Highs_create();h!=C_NULL || error("HiGHS allocation failed")
    check(s,operation)=s==HiGHS.kHighsStatusOk || error("HiGHS correction $operation failed: $s")
    function intinfo(key)
        v=Ref{HiGHS.HighsInt}(0)
        HiGHS.Highs_getIntInfoValue(h,key,v)==HiGHS.kHighsStatusOk ? Int(v[]) : nothing
    end
    wall=time();point=nothing
    record=Dict{String,Any}("native_log_file"=>log_path,"native_optimizations"=>0,
        "requested_seconds"=>seconds,"columns"=>length(x),"rows"=>length(rl),
        "basis_reused"=>false,"external_solution_read"=>false,
        "certificate_scope"=>"linearized candidate subproblem only; no full GO3 bound")
    try
        check(HiGHS.Highs_setStringOptionValue(h,"log_file",log_path),"log_file")
        check(HiGHS.Highs_setBoolOptionValue(h,"output_flag",1),"output_flag")
        check(HiGHS.Highs_setBoolOptionValue(h,"log_to_console",0),"log_to_console")
        check(HiGHS.Highs_setIntOptionValue(h,"threads",threads),"threads")
        check(HiGHS.Highs_setIntOptionValue(h,"random_seed",0),"random_seed")
        check(HiGHS.Highs_setDoubleOptionValue(h,"primal_feasibility_tolerance",1e-9),"primal_tolerance")
        check(HiGHS.Highs_setDoubleOptionValue(h,"dual_feasibility_tolerance",1e-9),"dual_tolerance")
        check(HiGHS.Highs_setDoubleOptionValue(h,"small_matrix_value",1e-12),"matrix_threshold")
        check(HiGHS.Highs_setStringOptionValue(h,"solver","simplex"),"solver")
        # One bulk CSC transfer, no per-variable native edits or commercial backend.
        starts=HiGHS.HighsInt.(A.colptr.-1);indices=HiGHS.HighsInt.(A.rowval.-1)
        import_status=HiGHS.Highs_passLp(h,length(c),length(rl),nnz(A),HiGHS.kHighsMatrixFormatColwise,
            HiGHS.kHighsObjSenseMaximize,0.0,c,lb,ub,rl,ru,starts,indices,A.nzval)
        record["import_status"]=Int(import_status)
        import_status in (HiGHS.kHighsStatusOk,HiGHS.kHighsStatusWarning) ||
            error("HiGHS correction LP import error: $import_status; see $log_path")
        audit=correction_import_audit(h,A,c,lb,ub,rl,ru)
        record["import_audit"]=audit;record["bulk_transfer_and_audit_seconds"]=time()-wall
        if !audit["pass"]
            record["reason"]="native_import_changed_linearization_beyond_audited_limit"
            return nothing,record # Return to unchanged point / bounded Ipopt fallback.
        end
        start_status=HiGHS.Highs_setSolution(h,x,A*x,C_NULL,C_NULL)
        stored=zeros(length(x));stored_rows=zeros(length(rl))
        stored_ok=HiGHS.Highs_getSolution(h,stored,C_NULL,stored_rows,C_NULL)==HiGHS.kHighsStatusOk && stored==x
        record["complete_start_api_status"]=Int(start_status);record["native_stored_start"]=stored_ok
        record["native_start_use"]="stored vector observed; algorithmic use after presolve not asserted"
        allowance=seconds-(time()-wall)
        if allowance<=0
            record["reason"]="lp_budget_consumed_by_import_and_audit"
            return nothing,record
        end
        check(HiGHS.Highs_setDoubleOptionValue(h,"time_limit",allowance),"time_limit")
        record["native_allowance_seconds"]=allowance;record["native_optimizations"]=1
        native_started=time();run_status=HiGHS.Highs_run(h);api_seconds=time()-native_started
        record["native_run_status"]=Int(run_status)
        run_status in (HiGHS.kHighsStatusOk,HiGHS.kHighsStatusWarning) ||
            error("HiGHS correction solve API error: $run_status; see $log_path")
        status=Int(HiGHS.Highs_getModelStatus(h));ps=intinfo("primal_solution_status")
        if ps==HiGHS.kHighsSolutionStatusFeasible
            point=zeros(length(x))
            check(HiGHS.Highs_getSolution(h,point,C_NULL,stored_rows,C_NULL),"get_solution")
            all(isfinite,point) || error("Native correction returned nonfinite point")
        end
        merge!(record,Dict("native_model_status"=>status,"native_primal_status"=>ps,
            "native_seconds"=>HiGHS.Highs_getRunTime(h),"api_seconds"=>api_seconds,
            "simplex_iterations"=>intinfo("simplex_iteration_count")))
        point,record
    catch e
        record["error"]=sprint(showerror,e)
        rethrow()
    finally
        HiGHS.Highs_destroy(h)
        record["wall_seconds"]=time()-wall
        messages=filter(line->occursin(r"(?i)^\s*(warning|error)\s*:",line),readlines(log_path))
        record["native_warning_error_count"]=length(messages)
        record["native_warning_error_excerpt"]=first(messages,min(20,length(messages)))
        atomic_json(log_path*".json",record)
        println("GO3_CORRECTION_NATIVE ",JSON.json(record));flush(stdout)
    end
end

function ac_linear_correction(model,point;deadline,max_rounds=8,lp_seconds=4.0,threads=4,log_dir=nothing)
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
            seconds=allowance,threads=threads,log_dir=log_dir)
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
