# Exact solver representation reduction. Never drop an approximately redundant
# row or infer a zero using a tolerance. Only reserve auxiliaries can be fixed;
# dispatch, PMIN, voltages, flows and source data are not modified.
const AC_ZERO_RESERVES_POLICY="exact_zero_reserve_domains_v1"

function ac_zero_domain(v)
    (fixed=is_fixed(v) ? fix_value(v) : nothing,
     lower=has_lower_bound(v) ? lower_bound(v) : nothing,
     upper=has_upper_bound(v) ? upper_bound(v) : nothing)
end

ac_domain_is_exact_zero(d)=d.fixed===nothing ?
    (d.lower!==nothing && d.upper!==nothing && d.lower==0.0 && d.upper==0.0) : d.fixed==0.0

function ac_zero_sum_witness(c,domains,known_zero)
    c.func isa AffExpr && c.func.constant==0.0 || return nothing
    rhs=c.set isa MOI.LessThan ? c.set.upper :
        c.set isa MOI.GreaterThan ? c.set.lower :
        c.set isa MOI.EqualTo ? c.set.value : nothing
    rhs isa Real && rhs==0.0 || return nothing
    signs=c.set isa MOI.EqualTo ? (1.0,-1.0) :
        c.set isa MOI.LessThan ? (1.0,) : (-1.0,)
    for sign in signs
        free=VariableRef[];valid=true
        for (a,v) in linear_terms(c.func)
            isfinite(a) || error("Nonfinite coefficient in exact zero-domain audit")
            a==0.0 && continue
            v in known_zero && continue
            d=get(domains,v,nothing)
            if d===nothing || d.fixed!==nothing || d.lower===nothing || d.lower!=0.0 ||
                    (d.upper!==nothing && d.upper<0.0) || !(sign*a>0.0)
                valid=false;break
            end
            push!(free,v)
        end
        valid && !isempty(free) && return free
    end
    nothing
end

function ac_scalar_row_residual(x,set)
    isfinite(x) || error("Nonfinite original-row residual")
    if set isa MOI.LessThan
        return max(0.0,x-set.upper)
    elseif set isa MOI.GreaterThan
        return max(0.0,set.lower-x)
    elseif set isa MOI.EqualTo
        return abs(x-set.value)
    end
    error("Unsupported exact-zero row set")
end

function ac_zero_constant_satisfied(c,known_zero)
    c.func isa AffExpr && isfinite(c.func.constant) || return false
    all(isfinite(a) && (a==0.0 || v in known_zero) for (a,v) in linear_terms(c.func)) || return false
    ac_scalar_row_residual(c.func.constant,c.set)==0.0
end

ac_row_touches_reserves(c,domains)=any(a!=0.0 && haskey(domains,v) for (a,v) in linear_terms(c.func))

function verify_ac_zero_reserve_proof!(model,data)
    # Replay with ORIGINAL domains and earlier proved zeros, not the final
    # fixings. This prevents circular arguments such as x<=y and y<=x => x=y=0.
    Set(keys(data.initial_zero_domains))==data.initial_zero &&
        all(ac_domain_is_exact_zero,values(data.initial_zero_domains)) ||
        error("Invalid original fixed-zero domains")
    known=copy(data.initial_zero)
    for step in data.steps
        expected=ac_zero_sum_witness(step.original,data.domains,known)
        expected!==nothing && Set(expected)==Set(step.variables) &&
            length(expected)==length(step.variables) || error("Invalid exact reserve zero proof")
        union!(known,expected)
    end
    Set(keys(data.fixed))==setdiff(known,data.initial_zero) || error("Incomplete derived zero map")
    for (v,domain) in data.domains
        if haskey(data.fixed,v)
            is_fixed(v) && fix_value(v)==0.0 || error("Derived reserve zero was not retained")
            data.fixed[v]==domain || error("Original reserve domain identity changed")
        else
            ac_zero_domain(v)==domain || error("Unproved reserve domain change")
        end
    end
    for removed in data.removed
        !is_valid(model,removed.reference) && ac_row_touches_reserves(removed.original,data.domains) &&
            ac_zero_constant_satisfied(removed.original,known) ||
            error("Unproved constant-row removal")
    end
    true
end

function compact_ac_zero_reserves!(model,reserve_variables;policy="off",max_passes=8)
    policy in ("off",AC_ZERO_RESERVES_POLICY) || error("Unknown AC zero-domain policy")
    policy=="off" && return Dict{String,Any}("policy"=>policy,"enabled"=>false)
    haskey(model.ext,:ac_zero_reserve_proof) && error("AC zero-domain reduction already applied")
    max_passes isa Integer && !(max_passes isa Bool) && max_passes>0 || error("Invalid zero-domain passes")
    started=time();variables=all_variables(model)
    objective=objective_function(model);sense=objective_sense(model)
    eligible=Set{VariableRef}(reserve_variables)
    all(v->owner_model(v)===model && !is_integer(v) && !is_binary(v),eligible) ||
        error("Exact AC zero propagation requires continuous reserves from this model")
    domains=Dict(v=>ac_zero_domain(v) for v in eligible)
    # Equal zero lower/upper bounds are exact fixings too, even if JuMP stores
    # them as two inequalities rather than a FixRef. No source bound is edited.
    initial_zero_domains=Dict(v=>ac_zero_domain(v) for v in variables if ac_domain_is_exact_zero(ac_zero_domain(v)))
    initial_zero=Set(keys(initial_zero_domains))
    known=copy(initial_zero)
    rows=vcat(all_constraints(model,AffExpr,MOI.LessThan{Float64}),
        all_constraints(model,AffExpr,MOI.GreaterThan{Float64}),
        all_constraints(model,AffExpr,MOI.EqualTo{Float64}))
    original_row_count=sum(num_constraints(model,F,S) for (F,S) in list_of_constraint_types(model))
    fixed=Dict{VariableRef,Any}();steps=Any[];removed=Any[];passes=0
    for pass in 1:max_passes
        passes=pass;before=length(known)
        for cref in rows
            original=constraint_object(cref)
            new_zero=ac_zero_sum_witness(original,domains,known)
            new_zero===nothing && continue
            push!(steps,(reference=cref,original=original,variables=new_zero))
            for v in new_zero
                haskey(fixed,v) && error("Duplicate derived reserve zero")
                fixed[v]=domains[v]
                fix(v,0.0;force=true)
                set_start_value(v,0.0)
            end
            union!(known,new_zero)
        end
        length(known)==before && break
    end
    for cref in rows
        original=constraint_object(cref)
        # Only reserve-related rows: named network balance/reporting rows may
        # still be queried by the pinned extractor, even when they are constant.
        if ac_row_touches_reserves(original,domains) && ac_zero_constant_satisfied(original,known)
            push!(removed,(reference=cref,original=original))
            delete(model,cref)
        end
    end
    data=(initial_zero=initial_zero,initial_zero_domains=initial_zero_domains,
        domains=domains,fixed=fixed,steps=steps,removed=removed)
    verify_ac_zero_reserve_proof!(model,data)
    all_variables(model)==variables && objective_sense(model)==sense &&
        JuMP.isequal_canonical(objective_function(model),objective) ||
        error("Exact reserve reduction changed variables or objective")
    record=Dict{String,Any}("policy"=>policy,"enabled"=>true,
        "solver_representation_changed"=>!isempty(fixed) || !isempty(removed),
        "source_feasible_set_changed"=>false,"source_parameters_changed"=>false,
        "dispatch_or_PMIN_modified"=>false,"objective_changed"=>false,
        "floating_point_bits"=>64,"proof_replayed"=>true,"proof_tolerance"=>0.0,
        "original_row_count"=>original_row_count,
        "solver_row_count"=>sum(num_constraints(model,F,S) for (F,S) in list_of_constraint_types(model)),
        "variable_count"=>length(variables),"variables_deleted"=>0,
        "eligible_reserve_variables"=>length(eligible),"implied_zero_variables"=>length(fixed),
        "original_exact_zero_domains"=>length(initial_zero_domains),
        "proof_rows"=>length(steps),"constant_satisfied_rows_removed"=>length(removed),
        "passes"=>passes,"seconds"=>time()-started,
        "original_row_audits"=>0,"last_original_row_maximum_residual"=>nothing,
        "scope"=>"Exact implied reserve fixings and reserve-related constant-row removal; original rows and domains remain mandatory in every residual audit")
    model.ext[:ac_zero_reserve_proof]=(data=data,record=record)
    record
end

function ac_removed_zero_rows_residual(model,point_values)
    proof=get(model.ext,:ac_zero_reserve_proof,nothing)
    proof===nothing && return 0.0
    residual=0.0
    for removed in proof.data.removed
        c=removed.original
        residual=max(residual,ac_scalar_row_residual(value(v->point_values[v],c.func),c.set))
    end
    for (v,d) in proof.data.fixed
        x=point_values[v]
        isfinite(x) || error("Nonfinite original reserve-domain point")
        d.fixed===nothing || (residual=max(residual,abs(x-d.fixed)))
        d.lower===nothing || (residual=max(residual,d.lower-x))
        d.upper===nothing || (residual=max(residual,x-d.upper))
    end
    proof.record["original_row_audits"]+=1
    proof.record["last_original_row_maximum_residual"]=residual
    residual
end
